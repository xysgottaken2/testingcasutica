// Cloud deck — two selectable styles over one shared field.
//
// Caustica cancels vanilla's LevelRenderer outright (see LevelRendererMixin), and vanilla's cloud pass
// lives inside it — so under the ray-traced renderer there were simply no clouds in the world at all.
// The sky shader modelled an atmosphere, a sun, a moon and a starfield, and the weather code even
// hid the celestial discs "behind the cloud deck" during rain, but nothing ever drew that deck. This
// module is that deck.
//
// TWO STYLES, TWO SHAPE SOURCES. Where clouds are is answered differently per style, and cloudCoverage
// is the one place both answers live — so the visible deck and the shadow it casts always agree.
//   * CLOUD_STYLE_CLASSIC — vanilla's blocky clouds, from vanilla's own SHAPE: the clouds.png cell map
//     (one 12-block cell per pixel, bit-packed into the BDA ring by RtComposite). With real thickness
//     the deck is intersected ANALYTICALLY — each occupied cell is an axis-aligned box and the ray walks
//     the cell grid to the first one (cloudClassicBoxes), which is exact and needs no march at all.
//     Colour is EnvironmentAttributes.CLOUD_COLOR — the game's own per-weather value — so a storm greys
//     the deck with no hand-tuned ramp. At zero thickness it collapses to the flat sheet. If the map is
//     unavailable the style degrades to the old noise-quantised deck rather than to nothing.
//   * CLOUD_STYLE_VOLUMETRIC — a physically-modelled water-cloud deck, built the way the sky builds one.
//     WHERE cloud is comes from a 2D coverage field (a cloud layer really is two-dimensional: one
//     condensing air mass); WHAT SHAPE it has comes from a 3D-eroded height profile whose form is chosen
//     by a weather-driven GENUS model — a closed stratocumulus sheet, fair-weather cumulus heaps, or
//     convective towers in a storm (see CloudWeather). Lighting is three optical-depth probes (toward the
//     sun, toward the zenith, and the ground bounce back up into the base) fed through a multi-scattering
//     octave expansion, a three-lobe Mie-approximating phase, a powder (dark-edge) term and aerial
//     perspective, integrated front-to-back with a dithered march start and an energy-conserving step.
//     docs/realistic-volumetric-clouds.md records the model and where every number comes from.
//
// Both styles honour the same thickness slider — it sets how DEEP the deck is, i.e. how much bulk the
// clouds have, never how far off the ground they sit (that is the height slider's job, and it is the
// deck's base) — and the weather fill (cloudColor.w) closes either sky completely in a storm. In the
// volumetric style the weather also picks the genus, so a storm's deck is deep grey tower cloud and a
// clear day's is scattered heaps, within the same slider budget.
//
// DEPTH-CORRECT AGAINST THE WORLD. Every entry point that produces visible cloud takes the distance to
// the nearest scene hit and stops there, so terrain in front of a cloud occludes it. Getting this wrong
// is exactly the bug where the world appeared to punch through the deck from above (see cloudLayer).
//
// Only world_common is imported: world.rmiss must NOT pull in world_core (that module declares the
// raygen bindings), so every entry point here takes the WorldPush explicitly, exactly like
// world_common's own worldFeature/worldFlag accessors. That is also why the march dither hashes the
// pixel index itself instead of using math.slang's PCG stream — math imports world_core. The dither
// does mean this module reads DispatchRaysIndex(), so it may only be imported by ray-tracing stages,
// which every current importer (world.rgen, world.rmiss, fog) is.

import world_common;

// ---- Pattern geometry. The field is EXACTLY periodic over CLOUD_CELL_BLOCKS * CLOUD_PERIOD_CELLS
// blocks (6144), because cloudHash wraps its cell index to that period. That is load-bearing, not
// decoration: RtComposite pushes a sample anchor already reduced modulo the same 6144 (both to fold in
// the wind scroll, which grows without bound with world time, and to keep the anchor a small float far
// from a Minecraft world border's 30M-block coordinates). Wrapping an aperiodic noise would teleport
// the whole sky the moment the anchor rolled over; wrapping a periodic one is seamless. The repeat is
// four times the deck's own view limit, so it is never visible in one frame.
public static const float CLOUD_CELL_BLOCKS = 12.0; // vanilla's cloud cell size
public static const int   CLOUD_PERIOD_CELLS = 512; // power of two, so the wrap below is a mask
public static const int   CLOUD_CELL_MASK = CLOUD_PERIOD_CELLS - 1;
// Width of the coverage ramp for the volumetric style. Classic quantises instead (see cloudCoverage).
public static const float CLOUD_EDGE_SOFTNESS = 0.22;
public static const float3 CLOUD_ALBEDO = float3(0.94, 0.95, 0.98);
public static const float CLOUD_INV_PI = 0.31830988618;

// Below this the deck is treated as a flat sheet: the thickness slider at 0 must reproduce the old
// plane exactly rather than degenerate into a zero-length march.
public static const float CLOUD_FLAT_EPSILON = 0.25;

// Style ids; the active one comes from featureFlags (see cloudStyle).
public static const uint CLOUD_STYLE_CLASSIC = 0u;
public static const uint CLOUD_STYLE_VOLUMETRIC = 1u;

// ---- Volumetric march budget.
//
// This is the whole cost of the volumetric style, and it multiplies by SPP and by path depth, so it is
// split into two tiers rather than being one flat number:
//   * FULL is used where the clouds are actually looked at — the camera ray and specular/mirror bounces
//     (reflections of the sky in water and glass). This is what the player sees, so it gets the light
//     probes, the multi-scattering expansion and the full step count.
//   * CHEAP is used for diffuse indirect bounces. Those contribute a broad, low-frequency sky-fill term
//     that gets averaged over the hemisphere and then denoised; resolving cloud detail there is
//     invisible in the result but would multiply the cost by the bounce count. It keeps the same
//     extinction and phase, so the ENERGY stays right — only the detail is coarser.
// Quality comes from the light probes and the phase function rather than raw step count.
public static const int   CLOUD_MARCH_STEPS = 24;
public static const int   CLOUD_LIGHT_STEPS = 6;
public static const int   CLOUD_MARCH_STEPS_CHEAP = 6;
public static const int   CLOUD_LIGHT_STEPS_CHEAP = 2;
// Upper bounds used when the step count is scaled to the path length (see cloudMarch). A fixed step
// COUNT means a deeper slab silently gets coarser steps, which bands: cloud lobes are tens of blocks
// wide, so a 60-block step walks straight past them. These cap the cost of that scaling.
public static const int   CLOUD_MARCH_STEPS_MAX = 48;
public static const int   CLOUD_MARCH_STEPS_CHEAP_MAX = 12;
// Target distance between samples. Comfortably finer than a lobe, so the march resolves shape.
public static const float CLOUD_TARGET_STEP_BLOCKS = 6.0;
// Detail levels cloudVolumeDensity accepts. SHAPE is the coverage-times-height-profile field with no
// erosion at all: it is what every light probe samples, because self-shadowing and ambient occlusion
// are decided by the deck's bulk and the crown's cauliflower only costs ALU there. COARSE adds the
// big lobes (the cheap tier's ceiling — it keeps the tier's average density near the full tier's, so
// the two cannot disagree about how much sky the deck closes off), FULL adds the fine erosion on top.
public static const int   CLOUD_DETAIL_SHAPE = 0;
public static const int   CLOUD_DETAIL_COARSE = 1;
public static const int   CLOUD_DETAIL_FULL = 2;
// Erosion detail is worth resolving only while a lobe is larger than a pixel. Past this distance the
// fine octave is faded out (and past the second, the coarse one too), which is both the standard
// volumetric LOD and a real effect: at 2 km a 6-block lobe is sub-pixel, and the atmosphere between
// the eye and the deck has already washed the contrast out of it.
public static const float CLOUD_DETAIL_LOD_NEAR = 320.0;
public static const float CLOUD_DETAIL_LOD_FAR = 1400.0;
public static const float CLOUD_EXTINCTION = 0.115; // per block, at density 1
// Measured water-cloud extinction is 0.005..0.1 per METRE and rises with liquid water content
// (Kokhanovsky's review of terrestrial cloud optics puts a typical a_ef = 6 um / 0.4 g m^-3 layer at
// about 0.1 m^-1). With one block to a metre this constant sits at the top of that range before the
// slab normalisation below and comfortably inside it after, which is the point: the number is not a
// look knob, it is the deck's optical depth per block of cloud.
//
// Single-scattering albedo of liquid cloud is ~0.9999 in the visible — droplets scatter essentially
// everything and absorb nothing — so scattering follows extinction and the small deficit below is the
// only absorption the deck has. Cloud interiors are grey because light SCATTERS OUT of them on the way
// to the eye, not because it is absorbed, which is exactly what the multi-scattering expansion models.
public static const float CLOUD_SINGLE_SCATTER_ALBEDO = 0.9995;
// Optical depth is normalised against this thickness, so making the deck taller adds VOLUME without
// making it more opaque. Without it, tau = density * sigma * pathLength grows with the slab depth and
// the deck's depth silently doubles as a second opacity slider — which matters more now that the
// volumetric deck's depth is weather-driven (a storm deck is ~3x deeper than an overcast sheet).
public static const float CLOUD_REFERENCE_THICKNESS = 40.0;
// Longest in-slab path a single ray may integrate, in slab depths. Bounds the grazing/horizon case
// (see cloudMarch); a few crossings already saturate a real cloud.
public static const float CLOUD_MAX_SLAB_CROSSINGS = 3.5;
// ---- Multi-scattering expansion (Wrenninge's octave approximation, as used by Frostbite and by
// Horizon Zero Dawn's Nubis).
//
// A cloud is optically thick: a photon crossing one scatters tens of times before it leaves, and
// single scattering alone renders that as flat grey cotton with black interiors. The approximation
// evaluates the single-scattering term N times, once per bounce ORDER, each time with the scattering
// and extinction coefficients scaled by k = FALLOFF^i and the phase relaxed toward isotropic by the
// same k — because every bounce randomises the direction a little more. The series converges
// (sum k = 1/(1-FALLOFF)), needs no extra march, and is what puts the bright soft interior, the
// lit crown and the dark-but-not-black base into the deck.
public static const int   CLOUD_MULTI_SCATTER_OCTAVES = 6;
public static const int   CLOUD_MULTI_SCATTER_OCTAVES_CHEAP = 3;
public static const float CLOUD_MULTI_SCATTER_FALLOFF = 0.5;
// Per-octave relaxation of the EXTINCTION seen by each successive bounce, and of the phase anisotropy.
// These are the ratios the approximation was published with (Wrenninge's multi-scattering octave model;
// the same schedule the Frostbite and Horizon Zero Dawn cloud implementations ship). Both express one
// physics from two sides: after several bounces a photon has travelled far inside the bank and its
// direction has been randomised, so the remaining cloud in front of it matters less and its scattering
// is less directional.
public static const float CLOUD_MULTI_SCATTER_EXTINCT_FALLOFF = 0.4;
public static const float CLOUD_MULTI_SCATTER_PHASE_FALLOFF = 0.8;
// How far each octave's powder term relaxes toward 1: halfway to its own square root per order, which is
// the relaxation the published octave model uses. Deep inside a bank, where several bounce orders have
// already contributed, the thin-edge darkening of the single-scattering model no longer applies.
public static const float CLOUD_POWDER_OCTAVE_RELAX = 0.5;
// Stop marching once this little light is left to carry. Past it the remaining steps can add at most a
// few percent of the deck's own brightness, and the samples are the expensive part (each one is a light
// probe). Every real-time cloud march ships some form of this exit; the threshold trades the last few
// percent of an already-saturated deck against the cost of its most expensive samples.
public static const float CLOUD_MIN_TRANSMITTANCE = 0.02;
// Overall in-scatter gain — and the one number here that was CALIBRATED rather than chosen, so it is
// worth being precise about what it is calibrated against.
//
// push.lightRadiance is an irradiance-like quantity: surface NEE is `brdf * lightRadiance * ndl`, i.e.
// albedo/PI * E. So the physically correct source term for a directional light in a participating medium
// is S = albedo * E * phase(cosT) with the 4PI-normalised phase this file uses, and for isotropic sky
// radiance L it is simply S = L (the phase integrates to 1). No fudge factor is required by the units.
//
// What is left to calibrate is the deck's own brightness, and the real sky answers it: an optically
// thick, essentially conservative water cloud reflects ~0.75 of the irradiance reaching it, spread over
// the hemisphere, so a sunlit cloud top has a radiance of about 0.75/PI = 0.24 * E — the same as a white
// surface facing the sun, which is why clouds and sunlit snow look equally bright. Summing this file's
// expansion for a full-depth sample (six orders, powder ~0.94, a mid-deck sun optical depth) gives
// ~0.29 * E before the gain, so 0.85 lands the deck on that 0.24 * E within the accuracy of the
// estimate. For comparison the single-scattering model this replaced produced ~0.03 * E — eight times
// too dim, which is the measurable reason its interiors read as flat grey cotton rather than as cloud.
//
// Brightness tuning should still not START here: this is the exposure of the whole deck, and the shape
// knobs are the genus profile, the erosion and the phase.
public static const float CLOUD_SCATTER_GAIN = 0.85;
// Extra extinction carried by precipitating cloud, at full rain+thunder. Water drops that have grown
// large enough to fall scatter and absorb more per unit volume than the droplets that made them, which
// is why a storm's underside reads grey-green rather than merely shadowed. Added to the extinction
// coefficient only (the albedo stays ~1): the deck gets DARKER and DEEPER-looking, not coloured.
public static const float CLOUD_STORM_ABSORPTION = 0.85;
// ---- Light probes. Three optical depths feed the expansion above, each answering "how much cloud is
// between this sample and the light arriving from THAT direction".
//
// The sun/moon probe marches with exponentially growing strides (each twice the last, over roughly one
// deck depth): self-shadowing is decided within a few tens of blocks of the sample, while the last
// strides reach the far side of the bank, and a uniform march of the same step count resolves neither
// end. The zenith probe is two steps — skylight arriving from straight up is the deck's own ambient
// occlusion, and it is a broad low-frequency quantity. The ground probe is analytic: light reflected
// off the sunlit surface back up into the cloud base, estimated from the sample's own height and
// density rather than marched, because marching DOWN through the deck for every sample is not
// affordable and the term is soft by nature.
public static const float CLOUD_LIGHT_STEP_GROWTH = 2.0;
// A low sun must march further to cross the same deck: the probe's span is the deck depth divided by
// this floor on |lightDir.y|, so sunrise/sunset self-shadowing stretches sideways instead of stopping
// after one deck depth and lighting the whole bank from within.
public static const float CLOUD_LIGHT_MIN_SUN_ELEVATION = 0.35;
public static const int   CLOUD_SKY_STEPS = 2;
// Ground (planetary) albedo for the bounced-light term. Earth's is ~0.3 over land and ~0.06 over open
// ocean; 0.22 is the standard neutral value shader packs use, and it is what lifts a cloud base from
// black to soft grey on the underside where no direct light reaches.
public static const float CLOUD_GROUND_ALBEDO = 0.22;
// Fraction of this sample's density assumed to fill the deck above it, used for the zenith probe on
// the cheap tier where the two-step march is skipped entirely.
public static const float CLOUD_SKY_ANALYTIC_FILL = 0.5;
// Horizontal scale of the volumetric field, relative to the classic 12-block cell grid. Below 1 the
// lobes get WIDER (the field is sampled more slowly), which is what lets cloud width grow together with
// the extra height so the result reads as heaped cumulus rather than a stretched sheet.
//
// MUST be a reciprocal power of two, and CLOUD_FIELD_PERIOD_BLOCKS (Java) must be a whole multiple of
// CLOUD_CELL_BLOCKS * CLOUD_PERIOD_CELLS / this. The volumetric field samples at samplePos * SCALE, so
// the anchor wrap is only seamless if the wrap distance is an exact multiple of the hash period IN THAT
// SCALED SPACE. At 0.45 it was not: every wrap landed 230.4 cells off and the whole cloudscape snapped
// to a different pattern — visible as clouds abruptly changing shape while walking, in the volumetric
// style only (classic samples unscaled, so it always wrapped cleanly). A power of two also makes the
// multiply exact in binary floating point, so the identity holds bit-for-bit rather than approximately.
public static const float CLOUD_VOLUMETRIC_SCALE = 0.5;
// Octave divisors for the base shape, the warp and the two billow layers. ALL must be powers of two,
// for the same reason CLOUD_VOLUMETRIC_SCALE must be: each is another space the periodic hash is
// sampled in, and the anchor wrap has to be a whole hash period in every one of them simultaneously.
// The largest divisor is the binding constraint on CLOUD_FIELD_PERIOD_BLOCKS (Java):
// period >= 512 * CELL * maxDiv / SCALE, so no divisor may EXCEED CLOUD_WARP_DIV without the Java
// period being raised with it (RtCloudPeriodMirrorTest fails the build if the two disagree).
// These were 2.0 / 0.9 / 0.35, and the two non-power-of-two ones desynced the detail layers at every
// wrap even after the base field was fixed — the same pop, just from the erosion instead of the shape.
//
// CLOUD_SHAPE_DIV is how the coverage field itself is read in the volumetric style, and it is what
// sets how WIDE an individual cloud is: one coverage cell spans CELL * DIV / SCALE = 48 blocks, so a
// cloud is a few hundred blocks across. That is the deliberate match to the deck's depth — real
// cumulus are about as wide as they are tall, and a storm deck is now ~190 blocks deep (RtCloudDeck),
// so the coarsest shape the wrap period allows is also the physically right one.
public static const float CLOUD_SHAPE_DIV = 2.0;
public static const float CLOUD_WARP_DIV = 2.0;
public static const float CLOUD_BILLOW_DIV_COARSE = 1.0;
public static const float CLOUD_BILLOW_DIV_FINE = 0.25;
// Vertical lattice period of the 3D detail hash, in cells. The horizontal axes wrap at
// CLOUD_PERIOD_CELLS because the anchor wraps; the vertical axis has no anchor to wrap (it is measured
// from the deck's own base), so this mask exists purely to keep the cell index small and the hash
// well-conditioned. It has to be large enough that the field cannot repeat inside one deck: at the
// finest octave a cell is 3 blocks, so 256 cells is 768 blocks — four times deeper than the deepest
// slab the model ever pushes.
public static const int   CLOUD_VERTICAL_CELLS = 256;
public static const int   CLOUD_VERTICAL_MASK = CLOUD_VERTICAL_CELLS - 1;
// ---- Genus model. The three shapes the real sky shows at this altitude, and the coverage/weather
// that selects between them (WMO genera; base heights and depths are mid-latitude values):
//   * SHEET — stratocumulus / stratus, and nimbostratus once it precipitates. Continuous, shallow
//     (300-600 m), flat-topped, grey: the sky closes over and the deck stops developing vertically.
//   * HEAP — fair-weather cumulus (humilis/mediocris). Individual clouds roughly as wide as they are
//     deep, a flat base at the lifting condensation level and a billowing crown.
//   * TOWER — cumulus congestus and cumulonimbus. Convective, several times deeper, crown filling the
//     whole slab: thunderstorm weather, and the only genus that reaches the top of the deck.
// Coverage selects sheet-vs-heap (a closed sky is a sheet, a scattered one is heaps) and the weather
// lanes select tower. There is deliberately NO slider for this: it is the same rain/thunder state the
// sky darkening, the light attenuation and the fog all read, so a storm's deep grey deck, its dimmed
// sun and its thickened air are one reading of one state.
public static const float CLOUD_SHEET_COVERAGE_LO = 0.55;
public static const float CLOUD_SHEET_COVERAGE_HI = 0.92;
// Height-profile endpoints per genus, as fractions of the slab. BASE_RAMP is how fast density comes in
// above the condensation level (a cumulus base is sharp, a stratus base frays into mist); CROWN_START
// is where the top begins to round off. Measured liquid-water profiles of shallow convective layers
// ramp up roughly linearly from cloud base and decay near the top as dry air is entrained, so the
// profile is asymmetric on purpose — a symmetric lens is what makes a procedural deck read as a slab.
public static const float CLOUD_BASE_RAMP_HEAP = 0.06;
public static const float CLOUD_BASE_RAMP_SHEET = 0.22;
public static const float CLOUD_CROWN_START_HEAP = 0.55;
public static const float CLOUD_CROWN_START_SHEET = 0.48;
public static const float CLOUD_CROWN_START_TOWER = 0.94;
public static const float CLOUD_CROWN_ROUNDING = 0.26;
// Dense cores tower. The crown's height is lifted by the LOCAL coverage through this smoothstep, so a
// bank develops cauliflower towers out of its thick parts while its wispy edges stay low and flat — and
// so one sky holds low fringes, mid-height heaps and tall towers at once, each where its own density
// says it belongs. A linear lift cannot do that: it makes every cloud in the sky the same height.
public static const float CLOUD_TOWER_COVERAGE_LO = 0.35;
public static const float CLOUD_TOWER_COVERAGE_HI = 0.90;
// Clear-sky peak of the convection parabola. The raw parabola 4c(1-c) peaks at 1.0 for 50% coverage,
// which would make every scattered fair-weather sky a slab-filling congestus; the published cumulus
// height gradient closes its dome at about half the layer instead, so the clear-sky peak is scaled down
// and thunderstorms (w.convection's other input) carry the full range on their own.
public static const float CLOUD_CONVECTION_PEAK = 0.45;
// How much wider a cloud gets around its belly than at its base/crown, for the heaped genus. Turns a
// straight-sided extrusion into a rounded, bulging mass; a sheet has no belly, so it is scaled out.
public static const float CLOUD_BULGE = 0.30;
public static const float CLOUD_BELLY_HEIGHT = 0.42;
// ---- Turbulent displacement. Real decks are sheared: wind speed and direction change with altitude,
// so updrafts lean downwind and the crown curls while the base stays flat. Displacing the sample
// position by a low-frequency noise before the detail octaves are read is the standard stand-in for
// that (HZD/Frostbite use a curl-noise texture; this uses the periodic value noise the module already
// has, because a deck that must survive an anchor wrap cannot sample an aperiodic texture).
// Amplitude in blocks, and how much harder the crown is displaced than the base.
public static const float CLOUD_WARP_AMPLITUDE_BLOCKS = 26.0;
public static const float CLOUD_WARP_SHEAR = 2.2;
// Fraction of the horizontal displacement also applied to the vertical coordinate, which is what leans
// a tower over instead of merely smearing its footprint.
public static const float CLOUD_WARP_VERTICAL = 0.55;
// ---- Detail erosion. Two octaves of 3D billow noise, weighted, erode the shape field's edge.
public static const float CLOUD_DETAIL_FINE_WEIGHT = 0.45;
// How hard the erosion bites at the coverage edge and at the slab extremes, relative to the core. A
// cloud's interior stays solid — real cumulus cores reach 1-2 g m^-3 of liquid water while the fraying
// edge is a fraction of that — and uniform erosion is what makes procedural cloud read as flat fluff.
public static const float CLOUD_EROSION_EDGE = 0.75;
public static const float CLOUD_EROSION_CROWN = 0.55;
public static const float CLOUD_EROSION_BASE = 0.35;
// Edge sharpening exponent, wispy at the base and hard at the crown — the standard shaping control of
// real-time cloud models:
// > 1 thins the field (a fraying, mist-like underside), < 1 fattens it (a hard, well-defined top).
public static const float CLOUD_EDGE_SHARPEN_BASE = 1.55;
public static const float CLOUD_EDGE_SHARPEN_CROWN = 0.90;
// ---- Phase and powder.
// Mie scattering by ~10 um droplets is strongly forward-peaked, with a very tight diffractive spike
// sitting inside a broad glow, plus a weak backward lobe from internal reflection. Three HG lobes in a
// normalised mixture (weights sum to 1, so the phase still integrates to 1 over the sphere and the
// expansion cannot invent energy) approximate that for a fraction of a real Mie table:
//   * BROAD  — the general sun-side brightening of a lit cloud;
//   * SILVER — the tight peak, which IS the silver lining on a backlit cloud edge;
//   * BACK   — what stops the shadow side collapsing into a silhouette.
// A weighted sum of HG lobes is the usual cheap stand-in for a Mie table; three lobes is the minimum
// that carries a forward peak, a broad glow and a back lobe at the same time.
public static const float CLOUD_HG_G = 0.60;
public static const float CLOUD_HG_SILVER = 0.88;
public static const float CLOUD_HG_BACK = -0.22;
public static const float CLOUD_PHASE_BROAD = 0.50;
public static const float CLOUD_PHASE_SILVER = 0.30;
public static const float CLOUD_PHASE_BACK = 0.20;
// Powder / dark-edge term: a thin edge transmits its light onward instead of scattering it back, which
// single scattering does not predict and whose absence is why cheap volumetric clouds look like flat
// grey cotton. It relaxes toward the light — at a backlit edge what reaches the eye is the forward peak,
// not absorption — or it eats the silver lining it exists to frame.
public static const float CLOUD_POWDER_STRENGTH = 0.7;
public static const float CLOUD_POWDER_SUN_RELAX = 0.8;
// ---- Aerial perspective. The air between the eye and the deck dims the deck's own scatter and puts
// sky radiance in its place, which is why distant clouds lose contrast and take on the horizon's
// colour rather than simply vanishing. Blended over the same range as the density fade below it, so
// the view-limit cutoff is hidden by cloud dissolving INTO the sky instead of by cloud being deleted.
public static const float CLOUD_AERIAL_STRENGTH = 0.6;
// Classic clouds are opaque boxes; this scales their extinction so a box saturates within its own
// thickness rather than looking like translucent haze.
public static const float CLOUD_CLASSIC_EXTINCTION_SCALE = 6.0;

// ---- Authored cell map (classic style).
//
// The classic deck reads its SHAPE from vanilla's own textures/environment/clouds.png, uploaded by
// RtComposite into this frame's BDA ring slot as a bit-packed occupancy bitmap (one bit per pixel,
// 256x256, one pixel = one 12-block cell; a cell counts as cloud when its alpha is >= 10 — vanilla's
// isCellEmpty threshold). Cloud shape is therefore AUTHORED data, exactly what vanilla extrudes,
// instead of an emergent property of the noise field below — which is what stops "fix one classic
// bug, surface another" from happening: there is no coverage threshold to tune against the shape.
//
// The map is exactly periodic over 256 cells * 12 blocks = 3072 blocks. The anchor RtComposite pushes
// is wrapped to 24576 blocks, an exact multiple of 3072, so the wrap is seamless by construction —
// the same property the noise field needs its power-of-two constants for, for free.
public static const int   CLOUD_CELL_MAP_CELLS = 256;
public static const int   CLOUD_CELL_MAP_MASK = CLOUD_CELL_MAP_CELLS - 1;
// Longest cell walk a single classic ray may perform. A near-horizontal ray inside the slab could in
// principle cross the whole view limit (3072/12 = 256 cells); the cap sits above that so the walk can
// always finish, while a pathological configuration can never turn the deck into an unbounded loop.
public static const int   CLOUD_CLASSIC_MAX_CROSSINGS = 320;

/**
 * Whether this frame draws clouds at all. Coverage or opacity at zero answers false, so the player
 * sliders bottoming out costs one comparison rather than a wasted intersection, and every consumer
 * short-circuits to the exact pre-cloud result (bit-identical output when the feature is off).
 */
public bool cloudsEnabled(WorldPush push) {
    // clouds.x is the PLAYER coverage only (the weather fill rides cloudColor.w) — so the deck stays
    // on when either one is non-zero. Gating on the slider alone would make a coverage-0 setting
    // remove the storm's overcast along with the clear-sky clouds.
    return push.dimension == DIMENSION_OVERWORLD
        && worldFeature(push, FEATURE_CLOUDS)
        && (push.clouds.x > 0.0 || push.cloudColor.w > 0.0)
        && push.clouds.y > 0.0;
}

/**
 * Selected style. Carried in featureFlags rather than smuggled into a float lane: that word exists
 * precisely for player-facing effect toggles, and an integer bit cannot be perturbed by denormal
 * flushing or a -0.0 comparison the way a packed sign bit can.
 */
public uint cloudStyle(WorldPush push) {
    return worldFeature(push, FEATURE_CLOUDS_VOLUMETRIC)
            ? CLOUD_STYLE_VOLUMETRIC : CLOUD_STYLE_CLASSIC;
}

/** Cloud shadow strength slider, 0..1. */
public float cloudShadowStrength(WorldPush push) {
    return clamp(push.clouds.z, 0.0, 1.0);
}

// Integer cell hash. Integer mixing rather than the sky's float hash13: the sample coordinate here is
// a world position that can be thousands of blocks from the anchor, where a float hash starts losing
// mantissa bits and the pattern degenerates into stripes. The mask is what makes the field periodic.
float cloudHash(int2 cell) {
    uint2 c = uint2(uint(cell.x & CLOUD_CELL_MASK), uint(cell.y & CLOUD_CELL_MASK));
    uint h = c.x * 374761393u + c.y * 668265263u;
    h = (h ^ (h >> 13u)) * 1274126177u;
    h = h ^ (h >> 16u);
    return float(h & 0x00ffffffu) * (1.0 / 16777216.0);
}

// Value noise on the cell lattice, smoothstep-interpolated. floor/frac agree for negative coordinates
// (floor(-0.3) = -1, frac(-0.3) = 0.7), so the field is continuous across the origin.
float cloudNoise(float2 p) {
    int2 i = int2(floor(p));
    float2 f = frac(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = cloudHash(i);
    float b = cloudHash(i + int2(1, 0));
    float c = cloudHash(i + int2(0, 1));
    float d = cloudHash(i + int2(1, 1));
    return lerp(lerp(a, b, u.x), lerp(c, d, u.x), u.y);
}

// ---- 3D noise (the volumetric style's detail and turbulence).
//
// WHY THREE DIMENSIONS. The old field was a 2D noise times a height profile, which makes a cloud a
// VERTICAL EXTRUSION of one flat pattern: seen from the side its lobes line up through the whole depth,
// seen from above it is a picture, and the crown never breaks into individual cauliflower heads. Real
// cloud is a 3D structure — a parcel rises, condenses, entrains dry air at its edges and rolls into
// lobes at every height independently — and that is the single biggest tell between "procedural deck"
// and "cloud". So erosion is sampled from a 3D lattice, while WHERE the cloud is stays a 2D field
// (which is what the real sky looks like too: coverage is a property of the layer, shape of the parcel).
//
// The hash keeps the 2D field's exact periodicity on the two horizontal axes — same mask, same lattice,
// so the anchor wrap that CLOUD_FIELD_PERIOD_BLOCKS (Java) guarantees stays seamless for the detail as
// well as for the shape. The vertical axis has no anchor to wrap and uses its own larger mask.
float cloudHash3(int3 cell) {
    uint3 c = uint3(uint(cell.x & CLOUD_CELL_MASK), uint(cell.y & CLOUD_VERTICAL_MASK),
                    uint(cell.z & CLOUD_CELL_MASK));
    uint h = c.x * 374761393u + c.y * 668265263u + c.z * 2246822519u;
    h = (h ^ (h >> 13u)) * 1274126177u;
    h = h ^ (h >> 16u);
    return float(h & 0x00ffffffu) * (1.0 / 16777216.0);
}

// Trilinear value noise on the 3D lattice: eight corner hashes, smoothstep-interpolated on each axis.
float cloudNoise3(float3 p) {
    int3 i = int3(floor(p));
    float3 f = frac(p);
    float3 u = f * f * (3.0 - 2.0 * f);
    float n00 = lerp(cloudHash3(i + int3(0, 0, 0)), cloudHash3(i + int3(1, 0, 0)), u.x);
    float n10 = lerp(cloudHash3(i + int3(0, 0, 1)), cloudHash3(i + int3(1, 0, 1)), u.x);
    float n01 = lerp(cloudHash3(i + int3(0, 1, 0)), cloudHash3(i + int3(1, 1, 0)), u.x);
    float n11 = lerp(cloudHash3(i + int3(0, 1, 1)), cloudHash3(i + int3(1, 1, 1)), u.x);
    return lerp(lerp(n00, n10, u.z), lerp(n01, n11, u.z), u.y);
}

// Billow shaping: 1 - |2n - 1| folds value noise into rounded cellular lobes (peaks on the lattice
// boundaries, valleys at the cell centres) instead of a cloudy blur. That rounded-cellular read is the
// cauliflower — the same reason the old 2D billows used it, now in three dimensions so the lobes have
// depth as well as width.
float cloudBillow3(float3 p) {
    return 1.0 - abs(cloudNoise3(p) * 2.0 - 1.0);
}

// One noise octave's sample coordinate: horizontal is the anchored deck space, vertical is BLOCKS ABOVE
// THE DECK BASE. Using the camera-relative Y instead would make a cloud's internal structure swim as
// the camera rises or falls (the field would be pinned to the eye, not to the world); the slab base is
// world-stable, so a height measured from it is too. Both axes use the same scale, so lobes are
// isotropic — a cloud is not stretched by the deck's depth.
float3 cloudDetailCoord(float2 sampleXZ, float heightAboveBase, float div) {
    float s = CLOUD_VOLUMETRIC_SCALE / (CLOUD_CELL_BLOCKS * div);
    return float3(sampleXZ.x * s, heightAboveBase * s, sampleXZ.y * s);
}

// ---- Weather-driven genus model (see the CLOUD_SHEET_* constants for the real-world basis).
//
// One struct resolved ONCE per march from lanes the frame already pushes, so every part of the deck —
// height profile, bulge, erosion, absorption, and the depth RtCloudDeck pushes from Java — describes
// the same cloud type instead of three parts disagreeing about what the sky is doing.
public struct CloudWeather {
    public float coverage;   // clear-sky slider merged with the weather fill, 0..1
    public float sheet;      // 0 = heaped cumulus, 1 = closed stratocumulus/stratus sheet
    public float convection; // 0 = no vertical development, 1 = congestus/cumulonimbus towers
    public float absorbing;  // extra extinction from precipitating cloud (rain darkening), 0..1
};

public CloudWeather cloudWeather(WorldPush push) {
    CloudWeather w;
    float retain = clamp(push.clouds.x, 0.0, 1.0);
    float fill = clamp(push.cloudColor.w, 0.0, 1.0);
    w.coverage = clamp(retain + (1.0 - retain) * fill, 0.0, 1.0);
    bool weatherOn = worldFeature(push, FEATURE_WEATHER_LIGHTING);
    float rain = weatherOn ? clamp(push.weather.x, 0.0, 1.0) : 0.0;
    float thunder = weatherOn ? clamp(push.weather.y, 0.0, 1.0) : 0.0;
    // A closed sky is a SHEET. Scattered coverage is heaps: individual clouds with clear air between
    // them. That is how the real sky behaves — stratocumulus and stratus form under an inversion that
    // caps vertical development and covers everything, while fair-weather cumulus convect into a
    // scattered field — so the coverage slider now changes cloud GENUS, not just density.
    w.sheet = smoothstep(CLOUD_SHEET_COVERAGE_LO, CLOUD_SHEET_COVERAGE_HI, w.coverage);
    // Convection peaks at intermediate coverage (a sunny day building cumulus) and in thunderstorms,
    // where the tower is the storm. An overcast sheet suppresses it: nothing is being heated from
    // below. 4*c*(1-c) is the parabola through that behaviour, peaking at 50% coverage.
    float scattered = 4.0 * w.coverage * (1.0 - w.coverage) * CLOUD_CONVECTION_PEAK;
    w.convection = clamp(max(scattered * (1.0 - w.sheet), thunder), 0.0, 1.0);
    // Precipitating cloud absorbs: droplets grow past the size that scatters cleanly, and the deck
    // darkens toward grey-green. This is the HZD rain-cloud term, and it is why a storm deck reads
    // heavier than an equally thick clear-sky one instead of merely wider.
    w.absorbing = clamp(rain * 0.55 + thunder * 0.45, 0.0, 1.0);
    return w;
}

/**
 * Raw coverage field in [0,1], before either style interprets it. Three octaves at INTEGER scales with
 * whole-cell offsets, so every octave shares the base period and the sum stays exactly periodic — see
 * the note on CLOUD_CELL_BLOCKS.
 *
 * This is the shared truth both styles and the shadow query are built on.
 */
public float cloudCoverageField(float2 samplePos) {
    float2 p = samplePos / CLOUD_CELL_BLOCKS;
    return cloudNoise(p) * 0.6
         + cloudNoise(p * 2.0 + float2(11.0, 11.0)) * 0.3
         + cloudNoise(p * 4.0 + float2(29.0, 29.0)) * 0.1;
}

/**
 * One authored cell from the clouds.png occupancy bitmap (see CLOUD_CELL_MAP_CELLS). `cell` is in
 * 12-block cell space; the map wraps at 256, matching the texture's own tiling.
 */
bool cloudCellOccupied(WorldPush push, int2 cell) {
    int2 c = int2(cell.x & CLOUD_CELL_MAP_MASK, cell.y & CLOUD_CELL_MAP_MASK);
    uint index = uint(c.y * CLOUD_CELL_MAP_CELLS + c.x);
    ConstPtr<uint> map = ConstPtr<uint>(push.cloudCellsAddr);
    return (map[index >> 5u] & (1u << (index & 31u))) != 0u;
}

/**
 * The volumetric style's coverage ramp: the raw field read at the SHAPE scale (one cell = 48 blocks, so
 * a cloud is a few hundred blocks across), thresholded by the weather-merged coverage and softened over
 * CLOUD_EDGE_SOFTNESS.
 *
 * ONE function, three callers — the visible density, the cloud-shadow query and the flat-sheet
 * fallback — because this module's founding invariant is that the deck and the shadow it casts must
 * never disagree about where cloud is. It used to be evaluated twice with DIFFERENT inputs: the shadow
 * merged the weather fill in, the density did not, so in rain the deck stayed at the slider's coverage
 * while its shadow closed the sky completely. That cannot happen now.
 *
 * CLOUD_SHAPE_DIV is read through cloudCoverageField's own three integer octaves, and the whole field
 * stays exactly periodic under the anchor wrap: the shape scale puts one coverage cell at 48 blocks,
 * so a period of 24576 blocks is 512 cells — the hash's exact repeat — and the 2x/4x octaves land on
 * 1024/2048. See the note on CLOUD_WARP_DIV before changing any divisor.
 */
float cloudVolumetricCoverage(float coverage, float2 samplePos) {
    if (coverage >= 1.0) {
        return 1.0; // a full storm is a full sky: no residue of pinholes under the threshold
    }
    float threshold = 1.0 - clamp(coverage, 0.0, 1.0);
    float shape = cloudCoverageField(samplePos * (CLOUD_VOLUMETRIC_SCALE / CLOUD_SHAPE_DIV));
    // Contrast, applied to the field BEFORE the threshold. A raw value-noise field is a Gaussian-ish wash
    // around 0.5, so thresholding it directly gives every cloud the same soft wide skirt and leaves no
    // clean air between neighbours — a sky of connected blobs rather than a sky of clouds. Pushing the
    // field toward its own extremes first is what separates individual clouds with real gaps between
    // them and gives each one a crisp edge: most of the difference between a cloudy wash and the
    // scattered cumulus of a fair-weather sky.
    shape = shape * shape * (3.0 - 2.0 * shape);
    return smoothstep(threshold, threshold + CLOUD_EDGE_SOFTNESS, shape);
}

/**
 * Coverage resolved into a 0..1 "how much cloud is here" for the current style.
 *
 * The two lanes it reads: push.clouds.x is the PLAYER coverage (the slider: the fraction of sky the
 * deck keeps in clear weather), push.cloudColor.w is the WEATHER fill (RtComposite ramps it toward 1
 * as rain/thunder close in). They stay separate all the way to the shader because the classic and
 * volumetric styles fold them together differently.
 *
 * CLASSIC reads the authored map. A cell is cloud when it is authored AND survives the slider's
 * thinning, OR when the weather has filled it in:
 *   * the per-cell hashes are evaluated on the cell index reduced to the map's own 256 period, so a
 *     given authored cell gets the SAME decision in every 3072-block tile — thinning or filling it
 *     differently across tiles would seam the sky at the wrap;
 *   * both tests are monotone in their input and stable over time, so raising the slider or a rising
 *     rain level only ever ADDS cells, and a full storm covers the whole sky (the old noise-quantised
 *     path topped out short of that and left punched holes right under the threshold — the reported
 *     bug 3);
 *   * with no weather and the slider at 1 the deck is exactly the clouds.png pattern — vanilla's own
 *     mix of large masses, small puffs and empty gaps, which no amount of noise tuning reproduces.
 * The quantised cell-centre sampling of the old path is gone with it: occupancy is a bitmap lookup,
 * so there is no threshold-vs-edge interaction left to produce holes.
 *
 * VOLUMETRIC keeps its smooth noise ramp, fed the weather-merged coverage. Full overcast short-
 * circuits to exactly 1: smoothstep never reaches 1 below threshold + EDGE, so a plain merge would
 * keep a residue of pinholes at "100%" coverage — and a storm sky has no pinholes.
 *
 * When the authored map is unavailable (cloudCellsAddr == 0 — texture missing, or a pack replaced it
 * with something non-256x256) the classic style degrades to the OLD noise-quantised deck rather than
 * to nothing, driven by the merged coverage so weather still closes the sky on that path.
 */
public float cloudCoverage(WorldPush push, float2 samplePos) {
    float retain = clamp(push.clouds.x, 0.0, 1.0);
    float fill = clamp(push.cloudColor.w, 0.0, 1.0);
    if (cloudStyle(push) == CLOUD_STYLE_CLASSIC) {
        if (push.cloudCellsAddr == 0u) {
            float merged = retain + (1.0 - retain) * fill;
            float threshold = 1.0 - clamp(merged, 0.0, 1.0);
            float2 cellCentre = (floor(samplePos / CLOUD_CELL_BLOCKS) + 0.5) * CLOUD_CELL_BLOCKS;
            return cloudCoverageField(cellCentre) > threshold + CLOUD_EDGE_SOFTNESS * 0.5 ? 1.0 : 0.0;
        }
        if (fill >= 1.0) {
            return 1.0; // a full storm is a full sky — skip the lookup entirely
        }
        int2 cell = int2(floor(samplePos / CLOUD_CELL_BLOCKS));
        int2 wrapped = int2(cell.x & CLOUD_CELL_MAP_MASK, cell.y & CLOUD_CELL_MAP_MASK);
        bool authored = cloudCellOccupied(push, cell) && cloudHash(wrapped) < retain;
        bool filled = cloudHash(wrapped + int2(127, 61)) < fill;
        return (authored || filled) ? 1.0 : 0.0;
    }
    return cloudVolumetricCoverage(retain + (1.0 - retain) * fill, samplePos);
}

/** Where a ray meets the deck, in the form both the visible pass and the shadow query need. */
public struct CloudHit {
    public bool hit;
    public float2 samplePos; // world-anchored deck coordinate to sample the density at
    public float distance;   // distance along the ray to the deck
    public float fade;       // horizon/view-limit fade
    public bool fromBelow;   // the deck is above the ray origin (we are looking at its underside)
};

/**
 * Intersect a ray with the deck's mid-plane. `originRel` and the deck height are both expressed
 * relative to the camera, which is what lets one function serve the miss shader (origin = the ray's own
 * origin, itself possibly a reflecting surface) and raygen (origin = the shading point) without either
 * needing absolute world coordinates — the terrain rebase would invalidate those anyway.
 *
 * `maxDistance` is the distance to the nearest scene hit along this ray (or a large number when the ray
 * escapes). A plane crossing BEYOND that point is behind solid geometry and is rejected, which is what
 * stops the deck from being drawn over terrain that is actually in front of it.
 *
 * Degenerate cases handled here rather than by callers, because each is a visible artefact:
 *   * a near-horizontal ray (|dir.y| tiny) would divide toward infinity — rejected outright, and the
 *     view-limit fade already takes alpha to zero long before that, so no edge appears;
 *   * a ray pointing away from the deck (t <= 0) must not intersect the plane behind it, which would
 *     paint a mirrored deck under the world.
 */
public CloudHit cloudTrace(WorldPush push, float3 originRel, float3 dir, float maxDistance) {
    CloudHit h;
    h.hit = false;
    h.samplePos = float2(0.0, 0.0);
    h.distance = 0.0;
    h.fade = 0.0;
    h.fromBelow = true;

    float deckRel = push.clouds.w - originRel.y; // deck mid-plane height relative to this ray's origin
    // Crossing fade. The flat style shades a plane, so a camera sitting exactly on it would flip
    // between the lit top face and the dark underside across a single pixel. Fading the deck out as the
    // camera passes through its nominal thickness turns that flip into a smooth transition — flying up
    // through the clouds dissolves them instead of popping. (The volumetric style needs no equivalent:
    // it integrates real density, so passing through simply marches less of it.)
    float halfThickness = max(push.cloudAnchor.z, 0.5) * 0.5;
    float crossFade = smoothstep(halfThickness * 0.5, halfThickness * 1.5, abs(deckRel));
    if (crossFade <= 0.0 || abs(dir.y) < 1.0e-4) {
        return h;
    }
    float t = deckRel / dir.y;
    if (t <= 0.0 || t >= maxDistance) {
        return h; // behind the ray, or behind solid geometry
    }
    float maxDist = max(push.cloudAnchor.w, 1.0);
    float horizontal = length(dir.xz) * t;
    if (horizontal >= maxDist) {
        return h;
    }
    h.hit = true;
    h.samplePos = push.cloudAnchor.xy + originRel.xz + dir.xz * t;
    h.distance = t;
    // The deck is a plane, so it reaches the horizon as an infinitely thin, infinitely dense band of
    // aliasing. Fading coverage out over the last 45% of the view limit replaces that band with open
    // sky, which is also how vanilla's finite cloud grid ends.
    h.fade = crossFade * (1.0 - smoothstep(maxDist * 0.55, maxDist, horizontal));
    h.fromBelow = deckRel > 0.0;
    return h;
}

/** Opacity the deck presents to a ray: density, the player's opacity slider, and the fades. */
public float cloudAlpha(WorldPush push, CloudHit h, float density) {
    if (!h.hit) {
        return 0.0;
    }
    return clamp(density * clamp(push.clouds.y, 0.0, 1.0) * h.fade, 0.0, 1.0);
}

/**
 * How much of the celestial (sun or moon) light survives the deck on its way to `pointRel`.
 *
 * This is the "Cloud Shadows" slider, and it is an analytic plane intersection plus one coverage
 * evaluation — no march, no extra ray, no added variance for the denoiser to chase, for either style.
 *
 * It samples the COVERAGE map at the deck's mid-plane, not the eroded 3D density, so for the volumetric
 * style the shadow follows the cloud's overall footprint rather than its individual billows. That is a
 * deliberate trade: matching per-lobe would mean marching the slab for every shading point of every
 * path vertex, and the difference is a slightly softer shadow edge that is indistinguishable in motion
 * from the real thing.
 * Points above the deck get t <= 0 and are unshadowed for free, which is the correct answer rather than
 * a special case.
 *
 * This deliberately does NOT call cloudTrace/cloudAlpha. Those helpers describe a VISIBLE cloud layer:
 * they apply camera-facing cross-fades and the finite view-distance fade stored in cloudAnchor.w. Using
 * that view query for sun visibility made the cloud-shadow multiplier depend on the observer (not just
 * on the receiver and the sun): when the camera crossed above a block shadow, the same terrain hit could
 * receive a different cloud fade and the already-blocked direct light looked like it had been shadowed a
 * second time. Sun visibility must be a light-path query only, so it intersects the deck analytically and
 * samples coverage without any view/camera fade.
 */
public float cloudSunShadow(WorldPush push, float3 pointRel, float3 lightDir) {
    if (!cloudsEnabled(push)) {
        return 1.0;
    }
    float strength = cloudShadowStrength(push);
    if (strength <= 0.0 || lightDir.y <= 1.0e-4) {
        return 1.0;
    }

    float deckRel = push.clouds.w - pointRel.y;
    float t = deckRel / lightDir.y;
    if (t <= 0.0) {
        return 1.0;
    }

    float2 samplePos = push.cloudAnchor.xy + pointRel.xz + lightDir.xz * t;
    float alpha = clamp(cloudCoverage(push, samplePos) * clamp(push.clouds.y, 0.0, 1.0), 0.0, 1.0);
    return 1.0 - strength * alpha;
}

// ---- Classic (vanilla-style) shading -------------------------------------------------------------

/**
 * Classic face shading, shared by the flat path and the analytic boxes. Vanilla shades cloud faces by
 * ORIENTATION with flat, constant tones — no smooth lighting model: top bright, underside markedly
 * darker, vertical sides in between. `faceLight` is that tone, picked by the caller from the face the
 * ray actually meets (which is a real geometric normal for boxes, and the view direction for the flat
 * sheet).
 *
 * Lit from worldPush.lightRadiance — the SAME value the ground's NEE uses — so the clouds ride every
 * curve the rest of the frame already follows: they redden through sunset on the atmosphere's own
 * transmittance, dim under the weather attenuation, and go to a dark sky-lit grey at night when the
 * moon takes over. Hand-picking a cloud colour is what makes cloud layers look pasted on.
 */
float3 cloudRadianceClassic(WorldPush push, float faceLight, float3 albedo, float3 skyBehind) {
    float3 sunRadiance = push.lightRadiance.xyz;
    float3 lit = albedo * CLOUD_INV_PI * sunRadiance * faceLight;
    // The classic deck is opaque, so it admits only a little sky fill — enough to keep it from going
    // black at night, when sunRadiance is near zero.
    return lit + skyBehind * 0.45;
}

/** Classic face tone for a unit face normal (see cloudRadianceClassic). */
float cloudClassicFaceTone(float3 normal) {
    if (normal.y > 0.5) {
        return 1.0;   // top face
    }
    if (normal.y < -0.5) {
        return 0.52;  // underside — vanilla's bottom face is markedly darker
    }
    return 0.78;      // vertical sides sit between the two
}

/**
 * The classic deck as REAL vanilla geometry: one 12x12-block box per authored clouds.png cell,
 * intersected analytically. No march, no density field — a cell is an axis-aligned box spanning the
 * slab, so the ray's crossing of the deck is a walk over the 2D cell grid (Amanatides & Woo style)
 * inside the slab's t-interval, stopping at the first occupied cell. That is exact by construction,
 * and it is what makes the classic style cheaper than a short march instead of the most expensive one:
 * the typical ray visits one or two cells.
 *
 * Two entry cases. An OUTSIDE ray meets the first occupied cell at the cell-boundary crossing the walk
 * arrives at — except when it enters the slab inside that cell, in which case the visible face is the
 * slab's top/bottom plane, exactly the face vanilla extrudes toward the viewer. A ray whose ORIGIN sits
 * inside an occupied box (the camera flying through a cloud) instead sees the box's exit face — vanilla
 * draws those interior faces for exactly this case (its FLAG_INSIDE_FACE ring).
 *
 * Depth is bounded by maxDistance like every other cloud entry point, so terrain in front of a box
 * occludes it; the horizon fade matches the other paths so the deck ends where they end.
 */
CloudVolume cloudClassicBoxes(WorldPush push, float3 originRel, float3 dir, float maxDistance,
                              float3 skyBehind) {
    CloudVolume result;
    result.scatter = float3(0.0, 0.0, 0.0);
    result.transmittance = 1.0;

    float thickness = max(push.cloudAnchor.z, 1.0);
    float slabBottom = push.clouds.w - thickness * 0.5 - originRel.y;
    float slabTop = push.clouds.w + thickness * 0.5 - originRel.y;

    // Slab entry/exit along the ray — identical bounds to cloudMarch, so both paths agree about where
    // the deck starts and stops for a given ray.
    float t0, t1;
    if (abs(dir.y) < 1.0e-6) {
        if (slabBottom > 0.0 || slabTop < 0.0) {
            return result; // parallel and outside the slab
        }
        t0 = 0.0;
        t1 = push.cloudAnchor.w;
    } else {
        float ta = slabBottom / dir.y;
        float tb = slabTop / dir.y;
        t0 = min(ta, tb);
        t1 = max(ta, tb);
    }
    t0 = max(t0, 0.0);
    t1 = min(t1, min(maxDistance, push.cloudAnchor.w));
    if (t1 <= t0) {
        return result;
    }
    float horizon = length(dir.xz) * t0;
    float fade = 1.0 - smoothstep(push.cloudAnchor.w * 0.55, push.cloudAnchor.w, horizon);
    if (fade <= 0.0) {
        return result;
    }

    // Grid walk happens in anchored deck space (anchor + camera-relative), where the authored cells are
    // axis-aligned and exactly periodic; y stays camera-relative because the slab bounds already are.
    float2 gridOrigin = push.cloudAnchor.xy + originRel.xz;
    float2 p0 = gridOrigin + dir.xz * t0;
    int2 cell = int2(floor(p0 / CLOUD_CELL_BLOCKS));

    float tHit = -1.0;
    float3 normal = float3(0.0, 1.0, 0.0);

    // t0 == 0 means the origin itself is inside the slab, so `cell` (built from the position at t0)
    // is the box the camera stands in — the visible surface is then the face the ray EXITS through
    // (vanilla draws those interior faces for exactly this case). For t0 > 0 the ray ENTERS the slab
    // at t0, and an occupied entry cell must be hit on its slab face right there: treating that case
    // as "inside" (the previous code did) skipped the near face entirely — from below, the deck then
    // showed only far faces and mid-slab side walls glimpsed through the gaps, which read as a
    // cybernetic grid in the clouds' shape instead of solid boxes.
    if (t0 <= 0.0 && cloudCellOccupied(push, cell)) {
        // Origin is inside an occupied box: the visible surface is the box face the ray EXITS through.
        float tExitX = 1.0e30;
        if (abs(dir.x) > 1.0e-8) {
            float boundX = dir.x > 0.0 ? (float(cell.x) + 1.0) * CLOUD_CELL_BLOCKS
                                       : float(cell.x) * CLOUD_CELL_BLOCKS;
            tExitX = (boundX - gridOrigin.x) / dir.x;
        }
        float tExitZ = 1.0e30;
        if (abs(dir.z) > 1.0e-8) {
            float boundZ = dir.z > 0.0 ? (float(cell.y) + 1.0) * CLOUD_CELL_BLOCKS
                                       : float(cell.y) * CLOUD_CELL_BLOCKS;
            tExitZ = (boundZ - gridOrigin.y) / dir.z;
        }
        float tExitY = dir.y > 0.0 ? slabTop / max(dir.y, 1.0e-8) : slabBottom / min(dir.y, -1.0e-8);
        if (tExitY <= tExitX && tExitY <= tExitZ) {
            tHit = tExitY;
            // Seen from inside, the ceiling IS the underside and the floor the top face — shade by the
            // face's own identity, not the viewing side, so the interior reads like vanilla's boxes.
            normal = float3(0.0, dir.y > 0.0 ? -1.0 : 1.0, 0.0);
        } else if (tExitX <= tExitZ) {
            tHit = tExitX;
            normal = float3(dir.x > 0.0 ? -1.0 : 1.0, 0.0, 0.0);
        } else {
            tHit = tExitZ;
            normal = float3(0.0, 0.0, dir.z > 0.0 ? -1.0 : 1.0);
        }
        if (tHit >= t1) {
            return result; // leaves the box beyond the bounded interval
        }
    } else {
        // Outside: walk the grid from the slab entry point until an occupied cell is crossed.
        // (A ray whose origin is OUTSIDE the slab but whose entry cell is occupied falls in here too:
        // the first-cell check below gives it the slab-face hit at t0 that the interior branch must
        // not steal — see the note above.)
        int stepX = dir.x >= 0.0 ? 1 : -1;
        int stepZ = dir.z >= 0.0 ? 1 : -1;
        float tDeltaX = abs(dir.x) > 1.0e-8 ? CLOUD_CELL_BLOCKS / abs(dir.x) : 1.0e30;
        float tDeltaZ = abs(dir.z) > 1.0e-8 ? CLOUD_CELL_BLOCKS / abs(dir.z) : 1.0e30;
        float edgeX = dir.x >= 0.0 ? (float(cell.x) + 1.0) * CLOUD_CELL_BLOCKS
                                   : float(cell.x) * CLOUD_CELL_BLOCKS;
        float edgeZ = dir.z >= 0.0 ? (float(cell.y) + 1.0) * CLOUD_CELL_BLOCKS
                                   : float(cell.y) * CLOUD_CELL_BLOCKS;
        float tMaxX = abs(dir.x) > 1.0e-8 ? (edgeX - p0.x) / dir.x + t0 : 1.0e30;
        float tMaxZ = abs(dir.z) > 1.0e-8 ? (edgeZ - p0.y) / dir.z + t0 : 1.0e30;
        // The slab entry point itself may already sit in an occupied cell — then the face seen is the
        // slab's own top/bottom plane, not a cell wall.
        if (cloudCellOccupied(push, cell)) {
            tHit = t0;
            normal = float3(0.0, dir.y > 0.0 ? -1.0 : 1.0, 0.0);
        } else {
            for (int i = 0; i < CLOUD_CLASSIC_MAX_CROSSINGS; i++) {
                float tNext;
                int3 stepAxis;
                if (tMaxX < tMaxZ) {
                    tNext = tMaxX;
                    cell.x += stepX;
                    tMaxX += tDeltaX;
                    stepAxis = int3(stepX, 0, 0);
                } else {
                    tNext = tMaxZ;
                    cell.y += stepZ;
                    tMaxZ += tDeltaZ;
                    stepAxis = int3(0, 0, stepZ);
                }
                if (tNext >= t1) {
                    break; // walked out of the bounded interval: open sky
                }
                if (cloudCellOccupied(push, cell)) {
                    tHit = tNext;
                    normal = float3(-stepAxis.x, 0.0, -stepAxis.z); // face the ray entered through
                    break;
                }
            }
        }
        if (tHit < 0.0) {
            return result; // no occupied cell before the interval ends
        }
    }

    float alpha = clamp(push.clouds.y, 0.0, 1.0) * fade;
    if (alpha <= 0.0) {
        return result;
    }
    // Authored colour: vanilla's own CLOUD_COLOR, already greyed by the game's weather resolve — this
    // is what fixes the white-in-rain deck without a hand-tuned ramp.
    float3 radiance = cloudRadianceClassic(push, cloudClassicFaceTone(normal), push.cloudColor.xyz,
                                           skyBehind);
    result.scatter = radiance * alpha;
    result.transmittance = 1.0 - alpha;
    return result;
}

// ---- Volumetric shading --------------------------------------------------------------------------
//
// This is the deck's light transport, and it is where "procedural cloud" turns into "cloud". Four
// questions, in the order a photon meets them:
//
//   1. WHERE is the cloud?  cloudVolumeDensity — a 2D coverage field (what a cloud LAYER is) times a
//      3D-eroded height profile (what an individual cloud is), the profile's shape chosen by the
//      weather-driven genus model above.
//   2. HOW MUCH light reaches a sample?  The three optical-depth probes. Self-shadowing, ambient
//      occlusion and ground bounce are three questions about three different directions, and answering
//      only the first is what leaves a deck looking like lit cotton wool with a black underside.
//   3. HOW does it scatter?  The multi-scattering expansion in cloudMarch. Cloud is optically thick —
//      measured optical depth of low water cloud is 12..92 — so a photon scatters tens of times before
//      it escapes, and single scattering renders that as a flat grey silhouette.
//   4. WHAT does the air in between do?  Aerial perspective, so the deck fades INTO the sky at the view
//      limit instead of being deleted there.
//
// Cost, stated honestly: a full-quality step is one density evaluation (coverage + turbulence + two 3D
// erosion octaves, ~40 hash lookups) plus a sun probe of CLOUD_LIGHT_STEPS shape-level densities plus
// two sky-probe steps. That is roughly twice the previous model per pixel, and it is the price of the
// look. What keeps it affordable: the cheap tier on diffuse bounces, shape-level probes, the distance
// LOD that drops the fine octave, and the transmittance early exit that stops the march once the deck
// has gone opaque.

// 4π and its reciprocal: hgLobe's normalisation, and the isotropic phase the multi-scattering expansion
// relaxes toward as the bounce order rises.
public static const float CLOUD_FOUR_PI = 12.566370614359172;
public static const float CLOUD_INV_FOUR_PI = 0.07957747154594767;

/** Single Henyey-Greenstein lobe, normalised to integrate to 1 over the sphere. */
float hgLobe(float cosT, float g) {
    float g2 = g * g;
    float d = 1.0 + g2 - 2.0 * g * cosT;
    return (1.0 - g2) / (CLOUD_FOUR_PI * max(d * sqrt(max(d, 1.0e-6)), 1.0e-4));
}

/**
 * Phase function: a normalised mixture of three Henyey-Greenstein lobes — a broad forward glow, the
 * tight forward peak that IS the silver lining on a backlit edge, and a weak backward lobe. See the
 * CLOUD_PHASE_* constants for the Mie reasoning and the weights.
 *
 * `g` is a parameter because the multi-scattering expansion relaxes it per bounce order: every
 * scattering randomises the direction a little more, so the phase drifts toward isotropic. All three
 * lobes scale with it (the silver peak most of all — it must not survive six bounces it should not),
 * and because the weights sum to 1 the mixture stays normalised at every order.
 */
float cloudPhaseG(float cosT, float g) {
    float ratio = g / CLOUD_HG_G;
    float broad = hgLobe(cosT, g);
    float silver = hgLobe(cosT, min(CLOUD_HG_SILVER * ratio, 0.97));
    float back = hgLobe(cosT, CLOUD_HG_BACK * ratio);
    return CLOUD_PHASE_BROAD * broad + CLOUD_PHASE_SILVER * silver + CLOUD_PHASE_BACK * back;
}

/**
 * Powder / dark-edge term, in [0,1): ~0 at a thin edge, ~1 in a dense interior.
 *
 * A single-scattering model brightens a wispy edge as readily as it brightens the core, and real cloud
 * does the opposite — thin edges transmit their light onward instead of scattering it back, which is
 * what gives a backlit deck dark, crisp fringes. Approximated from local density, the standard
 * Frostbite/Horizon trick, and applied with CLOUD_POWDER_STRENGTH so the caller controls how hard it
 * bites. It is then RELAXED toward 1 per octave inside the expansion (CLOUD_POWDER_OCTAVE_RELAX),
 * because by the third bounce the photon is deep in the bank and edge darkening no longer applies.
 */
float cloudPowder(float density) {
    return 1.0 - exp(-density * 4.0);
}

/**
 * Per-pixel, per-frame march dither, in [0,1).
 *
 * A ray march with a fixed sample pattern puts its truncation error at a fixed PLACE: bands, rings
 * around the deck's edge, and a step in every shadow terminator. Offsetting the march start by a hash
 * of the pixel index and the frame counter moves that error to a different pixel every frame, which
 * turns banding into high-frequency noise the temporal denoiser resolves — the standard rotating
 * Bayer/blue-noise trick, needing no texture.
 *
 * Two deliberate choices here. It is NOT math.slang's PCG stream: this module imports world_common and
 * nothing else, so every stage that draws clouds (including the guide and shadow miss shaders, which
 * declare no buffers at all) stays free of world_core's bindings — a plain 32-bit integer hash is four
 * instructions and carries no stream state. And DispatchRaysIndex() is safe: clouds is imported only by
 * fog, world.rgen and world.rmiss, all ray-tracing stages, and the flat primary pass never calls in.
 */
float cloudDither(WorldPush push) {
    uint2 pixel = uint2(DispatchRaysIndex().xy);
    uint h = pixel.x * 1973u + pixel.y * 9277u + push.frameIndex * 26699u;
    h = (h ^ (h >> 15u)) * 2246822519u;
    h = (h ^ (h >> 13u)) * 3266489917u;
    h = h ^ (h >> 16u);
    return float(h & 0x00ffffffu) * (1.0 / 16777216.0);
}

/**
 * 3D density inside the slab, per style.
 *
 * CLASSIC is a box: the density is the quantised cell coverage, constant through the whole thickness
 * with only a hair of taper at the very top and bottom faces. That is deliberately NOT billowy — it is
 * what makes the marched result read as vanilla's solid cuboid clouds rather than a soft blob, and it
 * is why the classic style still looks like Minecraft once it has real height.
 *
 * VOLUMETRIC is built the way the sky builds a deck, in three layers:
 *   * COVERAGE — the 2D field, weather-merged, deciding WHERE cloud is. A cloud layer's horizontal
 *     structure is genuinely two-dimensional (it is one condensing air mass), so this stays 2D and is
 *     shared with the shadow query;
 *   * HEIGHT PROFILE — the genus model deciding how deep the cloud develops at that spot: flat base at
 *     the condensation level, crown rounding off where convection runs out of steam, belly bulging
 *     outward. This is what makes a heap a heap and a sheet a sheet;
 *   * EROSION — two octaves of 3D billow noise subtracting from the profile. The third dimension lives
 *     HERE, and it is the difference between a cloud and a slab: because the noise varies with height,
 *     the crown breaks into individual cauliflower heads instead of the lobes lining up vertically the
 *     way a 2D pattern extruded through a height profile always does.
 *
 * `detail` is one of CLOUD_DETAIL_* (the light probes ask for less than the visible march), `detailFade`
 * is the distance LOD on the fine octave, and both are explained at their constants.
 */
float cloudVolumeDensity(WorldPush push, CloudWeather w, float3 posRel, float heightFrac,
                         float slabDepth, int detail, float detailFade) {
    float2 samplePos = push.cloudAnchor.xy + posRel.xz;
    float hf = clamp(heightFrac, 0.0, 1.0);

    if (cloudStyle(push) == CLOUD_STYLE_CLASSIC) {
        float coverage = cloudCoverage(push, samplePos);
        if (coverage <= 0.0) {
            return 0.0;
        }
        // Near-square vertical profile: full density across the body, clipped hard at both faces so the
        // silhouette from the side is a rectangle, matching vanilla's cloud boxes.
        float faces = smoothstep(0.0, 0.06, hf) * smoothstep(0.0, 0.06, 1.0 - hf);
        return coverage * faces;
    }

    // ---- Coverage: where the cloud is. One shared function, so the deck and its shadow cannot disagree.
    float coverage = cloudVolumetricCoverage(w.coverage, samplePos);
    if (coverage <= 0.0) {
        return 0.0;
    }

    // Height in blocks above the deck's own base. Every vertical term below is a function of THIS and
    // never of the camera-relative Y, so the deck's internal structure is pinned to the world instead of
    // swimming past the eye as the camera rises or falls.
    float height = hf * slabDepth;
    float open = 1.0 - w.sheet;

    // ---- Height profile.
    //
    // The base is the lifting condensation level: below it the air is unsaturated and there is no cloud
    // at all, which is why every real deck has a FLAT bottom when seen from the side. A heap's base is
    // sharp (one parcel that just reached saturation), a sheet's frays into mist (stratus forms by
    // shallow cooling over a wide area rather than by a rising parcel).
    float baseRamp = lerp(CLOUD_BASE_RAMP_HEAP, CLOUD_BASE_RAMP_SHEET, w.sheet);
    float bottom = smoothstep(0.0, baseRamp, hf);

    // The crown is where the top starts rounding off. Heaps round at ~0.7 of the slab; towers fill it
    // completely, because convection has no cap until it hits the tropopause; a sheet flattens at half,
    // because the inversion that made it stops all vertical development. Dense cores tower — the LOCAL
    // coverage lifts the crown, so the thick middle of a bank billows up into towers while its wispy
    // edges stay low and flat. That one coupling is most of why the result reads as a field of
    // individual clouds rather than as a single extruded slab.
    float heapCrown = lerp(CLOUD_CROWN_START_HEAP, 1.0,
                           smoothstep(CLOUD_TOWER_COVERAGE_LO, CLOUD_TOWER_COVERAGE_HI, coverage));
    float crownStart = lerp(heapCrown, CLOUD_CROWN_START_TOWER, w.convection);
    crownStart = lerp(crownStart, CLOUD_CROWN_START_SHEET, w.sheet);
    // The dome is clamped to close AT the slab top at the latest. Without the clamp a tall crown's fade
    // would end above the slab and the deck would be sliced flat by its own ceiling — the single most
    // obvious artefact of a slab-based deck, and exactly the "straight top that follows the thickness
    // slider" look this model exists to avoid. With it, every genus rounds off on its own schedule and
    // the slab top is only ever reached by towers, whose domes close exactly there.
    float crownEnd = min(crownStart + CLOUD_CROWN_ROUNDING, 1.0);
    float top = 1.0 - smoothstep(crownStart, crownEnd, hf);

    float profile = clamp(bottom * top, 0.0, 1.0);
    if (profile <= 0.0) {
        return 0.0;
    }

    // ---- Belly bulge (heaps only). A cumulus is widest around its lower-middle and pulls in toward
    // both base and crown, so the coverage is relaxed there: the same cloud grows sideways in its belly.
    // A sheet has no belly — it is a layer, not a parcel — so the term is scaled out by `open`.
    float belly = max(1.0 - abs(hf - CLOUD_BELLY_HEIGHT) * 2.0, 0.0);
    coverage = clamp(coverage + (smoothstep(0.0, 1.0, belly) - 0.35) * CLOUD_BULGE * open, 0.0, 1.0);
    if (coverage <= 0.0) {
        return 0.0;
    }

    // ---- Turbulent displacement (wind shear).
    //
    // Wind speed and direction change with altitude, so updrafts lean downwind and a crown curls while
    // its base stays flat. Displacing the sample position by a smooth low-frequency noise before the
    // erosion is read is the standard stand-in for that: HZD and Frostbite sample a curl-noise texture,
    // which this module cannot, because a deck that must survive the anchor wrap may only sample fields
    // that are periodic with it. Altitude enters as a coordinate OFFSET, which is what makes the
    // displacement grow and slide with height — shear — at 2D-noise cost rather than 3D. The visible
    // effect is that towers lean and crowns curl instead of every height showing the same footprint.
    float warpAmp = CLOUD_WARP_AMPLITUDE_BLOCKS * lerp(1.0, CLOUD_WARP_SHEAR, hf) * open;
    float2 warpUv = samplePos * (CLOUD_VOLUMETRIC_SCALE / (CLOUD_CELL_BLOCKS * CLOUD_WARP_DIV))
            + float2(hf * 0.9, hf * 0.4);
    float2 warp = float2(cloudNoise(warpUv), cloudNoise(warpUv + float2(41.0, 17.0))) - 0.5;
    float2 warpedXZ = samplePos + warp * warpAmp;
    float warpedHeight = height + (warp.x + warp.y) * warpAmp * CLOUD_WARP_VERTICAL;

    // ---- Erosion: two octaves of 3D billow noise, weighted. The fine one fades out with distance
    // (detailFade) and is skipped below the FULL tier. Both octaves average 0.5, which is why the cheap
    // tier can drop one without changing how much sky the deck closes off on average.
    float erosionField = 0.5;
    if (detail >= CLOUD_DETAIL_COARSE) {
        float coarse = cloudBillow3(cloudDetailCoord(warpedXZ, warpedHeight, CLOUD_BILLOW_DIV_COARSE));
        erosionField = coarse;
        if (detail >= CLOUD_DETAIL_FULL && detailFade > 0.0) {
            float fine = cloudBillow3(cloudDetailCoord(warpedXZ, warpedHeight, CLOUD_BILLOW_DIV_FINE)
                    + float3(19.0, 7.0, 23.0));
            erosionField = lerp(coarse, lerp(coarse, fine, CLOUD_DETAIL_FINE_WEIGHT), detailFade);
        }
    }
    // Cellular shaping: push the billow toward its own extremes before it erodes anything, so erosion
    // bites in defined scoops with crisp cell boundaries instead of a smooth wash. That ridge-and-cell
    // character is what Worley (cellular) noise gives a cloud crown in the texture-based implementations;
    // this gets most of the same bubbly-cauliflower read out of the value lattice for zero extra hashes.
    erosionField = erosionField * erosionField * (3.0 - 2.0 * erosionField);

    // Where erosion bites: hardest where the field is thin (the fraying edge of a cloud) and at the slab
    // extremes (the crown breaking into lobes, the base dissolving into mist), leaving the interior
    // solid. Uniform erosion is what makes procedural cloud read as flat fluff.
    float erosionWeight = (1.0 - coverage) * CLOUD_EROSION_EDGE
            + smoothstep(0.55, 1.0, hf) * CLOUD_EROSION_CROWN
            + smoothstep(0.18, 0.0, hf) * CLOUD_EROSION_BASE;
    // The SHAPE tier — what the light probes sample — substitutes the octave's EXPECTED value (0.5) for
    // the noise itself. Self-shadowing is decided by the deck's bulk, and an unbiased mean costs nothing,
    // whereas skipping erosion entirely would make every probe read the deck as denser than it is.
    float erosion = erosionWeight * (detail >= CLOUD_DETAIL_COARSE ? erosionField : 0.5);

    // Edge sharpening: an exponent > 1 thins the field (a wispy, mist-like underside), < 1 fattens it (a
    // hard, well-defined crown). This is the standard edge-sharpening exponent, and it is what separates "soft
    // grey blob" from "cloud with a crisp top and a fraying base".
    float sharpen = lerp(CLOUD_EDGE_SHARPEN_BASE, CLOUD_EDGE_SHARPEN_CROWN, hf);

    // Dense core: a cumulus interior reaches 1-2 g m^-3 of liquid water while its fraying edge is a
    // fraction of that, so coverage is super-linear toward the core rather than left flat. A field that
    // peaks at ~0.5 reads as haze no matter how deep the slab is.
    float core = coverage * (0.85 + 0.75 * coverage);
    return pow(clamp(core - erosion, 0.0, 1.0), sharpen) * profile;
}

/**
 * Optical depth from a sample toward the sun or moon, as ∫ density dl in blocks of unit-density cloud.
 * Returned RAW (not exponentiated) because the multi-scattering expansion needs the same quantity at
 * several different extinction coefficients — see cloudMarch.
 *
 * Marched with exponentially growing strides over roughly one deck depth, sampling SHAPE-level density.
 * The growth is the point: self-shadowing is decided within a few tens of blocks of the sample, while
 * the shadow cast by the whole bank arrives from the far side of it, and a uniform march of the same
 * step count resolves neither end. Six growing strides cover both.
 *
 * The span is the deck depth divided by the light's elevation (floored at
 * CLOUD_LIGHT_MIN_SUN_ELEVATION): a low sun has to travel much further sideways to cross the same slab,
 * and without the floor sunrise self-shadowing would stop after one deck depth and light the entire bank
 * from within — the flat, directionless look of a deck with no shadows.
 */
float cloudSunOpticalDepth(WorldPush push, CloudWeather w, float3 posRel, float3 lightDir,
                           float slabBottom, float slabDepth, int steps, float dither) {
    if (steps <= 0) {
        return 0.0;
    }
    float span = slabDepth / max(abs(lightDir.y), CLOUD_LIGHT_MIN_SUN_ELEVATION);
    float stride = span * (CLOUD_LIGHT_STEP_GROWTH - 1.0)
            / (pow(CLOUD_LIGHT_STEP_GROWTH, float(steps)) - 1.0);
    // Jitter inside the stride instead of always sampling its centre: with six strides a centred march
    // leaves a visible step in the shadow terminator, and the jitter is free (the ray already has one).
    float jitter = 0.5 + (dither - 0.5) * 0.8;
    float travelled = 0.0;
    float total = 0.0;
    for (int i = 0; i < steps; i++) {
        float3 p = posRel + lightDir * (travelled + stride * jitter);
        float above = p.y - slabBottom;
        if (above >= 0.0 && above <= slabDepth) {
            total += cloudVolumeDensity(push, w, p, above / slabDepth, slabDepth,
                    CLOUD_DETAIL_SHAPE, 0.0) * stride;
        }
        travelled += stride;
        stride *= CLOUD_LIGHT_STEP_GROWTH;
    }
    return total;
}

/**
 * Optical depth from a sample straight up to the top of the deck: how much sky that sample can see, i.e.
 * the deck's own ambient occlusion. Two steps at full quality.
 *
 * Passing steps == 0 asks for the analytic estimate instead, used by the cheap tier: ambient occlusion
 * is a broad low-frequency quantity, and a diffuse bounce is already an average over the hemisphere, so
 * marching it there would cost more than the detail it buys. The estimate assumes this sample's density
 * persists over CLOUD_SKY_ANALYTIC_FILL of the deck above it.
 */
float cloudSkyOpticalDepth(WorldPush push, CloudWeather w, float3 posRel, float heightFrac,
                           float slabBottom, float slabDepth, float sampleDensity, int steps,
                           float dither) {
    float above = (1.0 - clamp(heightFrac, 0.0, 1.0)) * slabDepth;
    if (above <= 0.0) {
        return 0.0;
    }
    if (steps <= 0) {
        return sampleDensity * CLOUD_SKY_ANALYTIC_FILL * above;
    }
    float stepLen = above / float(steps);
    float total = 0.0;
    for (int i = 0; i < steps; i++) {
        float3 p = posRel + float3(0.0, stepLen * (float(i) + 0.5 + (dither - 0.5) * 0.5), 0.0);
        total += cloudVolumeDensity(push, w, p, (p.y - slabBottom) / slabDepth, slabDepth,
                CLOUD_DETAIL_SHAPE, 0.0) * stepLen;
    }
    return total;
}

/**
 * Optical depth from a sample DOWN to the deck's base, for sunlight bounced off the ground back up into
 * the cloud's underside.
 *
 * Analytic rather than marched, and deliberately so: the ground is a broad diffuse source, so the term
 * is soft by nature; marching down for every sample would add a third probe to the most expensive loop
 * in the shader; and all that matters is the trend, which is that a sample high in the crown has the
 * whole deck between it and the ground while one at the base has almost none. The average density along
 * that path is mixed toward 1 as the sample rises, because the deck below a crown sample is the dense
 * part of the deck.
 */
float cloudGroundOpticalDepth(float sampleDensity, float heightFrac, float slabDepth) {
    float average = lerp(sampleDensity, 1.0, clamp(heightFrac * 2.0 - 1.0, 0.0, 1.0));
    return average * clamp(heightFrac, 0.0, 1.0) * slabDepth;
}

/**
 * Everything about the lighting of one march that does not change along the ray. Bundled so the
 * per-sample expansion below takes nine arguments instead of nineteen, and so the tier decisions
 * (bounce orders, probe resolution) are made once, in cloudMarch, rather than re-derived per step.
 */
struct CloudLight {
    float3 albedo;         // deck albedo: CLOUD_ALBEDO tinted by the frame's own cloud colour
    float3 sunRadiance;    // the celestial this frame is lit by — the sun by day, the moon by night
    float3 skyRadiance;    // sky ambient arriving from above
    float3 groundRadiance; // sunlight bounced off the lit ground back up into the deck's underside
    float3 lightDir;       // toward that celestial
    float cosT;            // dot(march direction, lightDir): +1 looking into the light
    float sigmaT;          // extinction per block at unit density
    int octaves;           // bounce orders in the expansion
    int sunSteps;          // strides in the sun probe
    int skySteps;          // steps in the zenith probe (0 = analytic)
};

/**
 * In-scattered radiance at one sample: the multi-scattering expansion.
 *
 * Each pass of the loop is one BOUNCE ORDER. Order 0 is single scattering — light arrives from the
 * celestial and leaves toward the eye — and order N has been scattered N more times inside the bank
 * before leaving. Rather than tracing those paths (impossible at this budget), the approximation
 * re-evaluates the same three light terms with the coefficients scaled by
 * k = CLOUD_MULTI_SCATTER_FALLOFF^N: scattering and extinction both shrink, because a photon deep
 * inside the bank is less affected by the cloud still in front of it, and the phase relaxes toward
 * isotropic by the same k, because each bounce randomises the direction a little more. The geometric
 * series converges, costs no extra march, and is what puts a bright soft interior, a lit crown and a
 * dark-but-not-black base into the deck — the difference between a cloud and a lit silhouette of one.
 *
 * The three optical depths are computed ONCE and shared by every order: the orders differ in how much
 * they are attenuated by them, not in what they are.
 */
float3 cloudSampleScatter(WorldPush push, CloudWeather w, CloudLight light, float3 posRel,
                          float density, float heightFrac, float slabBottom, float slabDepth,
                          float dither) {
    float sunOD = cloudSunOpticalDepth(push, w, posRel, light.lightDir, slabBottom, slabDepth,
                                       light.sunSteps, dither);
    float skyOD = cloudSkyOpticalDepth(push, w, posRel, heightFrac, slabBottom, slabDepth, density,
                                       light.skySteps, dither);
    float groundOD = cloudGroundOpticalDepth(density, heightFrac, slabDepth);

    // Powder darkens thin edges, and lets go toward the light: at a backlit edge what reaches the eye is
    // the forward-scatter peak rather than absorption, so powder that survives there eats the silver
    // lining it exists to frame.
    float powder = lerp(1.0, cloudPowder(density), CLOUD_POWDER_STRENGTH);
    powder = lerp(powder, 1.0, CLOUD_POWDER_SUN_RELAX * max(light.cosT, 0.0));

    float scatterAmt = 1.0;
    float extinctAmt = 1.0;
    float phaseG = CLOUD_HG_G;
    float3 total = float3(0.0, 0.0, 0.0);
    for (int order = 0; order < light.octaves; order++) {
        float k = pow(CLOUD_MULTI_SCATTER_FALLOFF, float(order));
        // Phase relaxed toward isotropic by k (Wrenninge). The ambient terms are isotropic already, so
        // they are not phase-weighted — only the directional light is.
        float phase = lerp(CLOUD_INV_FOUR_PI, cloudPhaseG(light.cosT, phaseG), k);
        float sigmaOrder = light.sigmaT * extinctAmt;
        float3 lit = light.sunRadiance * (phase * exp(-sunOD * sigmaOrder))
                + light.skyRadiance * exp(-skyOD * sigmaOrder)
                + light.groundRadiance * exp(-groundOD * sigmaOrder);
        total += lit * (scatterAmt * powder);
        scatterAmt *= CLOUD_MULTI_SCATTER_FALLOFF;
        extinctAmt *= CLOUD_MULTI_SCATTER_EXTINCT_FALLOFF;
        phaseG *= CLOUD_MULTI_SCATTER_PHASE_FALLOFF;
        // Deep inside the bank the thin-edge darkening of the single-scattering model stops applying.
        powder = lerp(powder, sqrt(powder), CLOUD_POWDER_OCTAVE_RELAX);
    }
    return total * (light.albedo * CLOUD_SCATTER_GAIN);
}
/** Result of a volumetric march: premultiplied scattered radiance and the surviving transmittance. */
public struct CloudVolume {
    public float3 scatter;
    public float transmittance;
};

/**
 * Ray-march the slab and return in-scattered radiance plus transmittance.
 *
 * Front-to-back emission/absorption integration: at each step the sample's in-scattering is accumulated
 * weighted by how much light still reaches the eye, and the transmittance is decremented by
 * Beer-Lambert. The caller composites with `col * transmittance + scatter`, so the result is correct
 * over any background — including a terrain hit, which is what makes the volumetric style occlude and
 * be occluded correctly.
 *
 * For the VOLUMETRIC style the per-sample in-scattering is a MULTI-SCATTERING EXPANSION rather than one
 * sun term plus a constant ambient: CLOUD_MULTI_SCATTER_OCTAVES bounce orders, each with its own
 * relaxation of the extinction, the phase and the powder term, fed by three optical-depth probes (sun,
 * sky, ground bounce). See the section header above for why, and the constants for the physics each
 * number comes from. The CLASSIC style keeps its flat vanilla-style face tone — it is meant to look like
 * Minecraft's cloud boxes, not like a cloud — but still gets the same slab integration, dithered start
 * and early exit, and borrows the sun probe (damped) for its self-shadowing, so the two styles at least
 * agree about where the deck ends and how it is sampled.
 *
 * `highQuality` picks the tier: the full march for camera rays and specular bounces, the cheap one for
 * diffuse indirect, where the cloud contributes a broad sky-fill term that is averaged over the
 * hemisphere and denoised anyway.
 */
public CloudVolume cloudMarch(WorldPush push, float3 originRel, float3 dir, float maxDistance,
                              float3 skyBehind, bool highQuality) {
    int marchSteps = highQuality ? CLOUD_MARCH_STEPS : CLOUD_MARCH_STEPS_CHEAP;
    int lightSteps = highQuality ? CLOUD_LIGHT_STEPS : CLOUD_LIGHT_STEPS_CHEAP;
    CloudVolume result;
    result.scatter = float3(0.0, 0.0, 0.0);
    result.transmittance = 1.0;

    float thickness = max(push.cloudAnchor.z, 1.0);
    // Crossing EXCLUSION. The flat path fades the deck out as the camera passes through its nominal
    // thickness (cloudTrace's crossFade) so the transition reads as dissolving cloud instead of a
    // one-pixel flip between lit top and dark underside. The march had no equivalent: with the camera
    // sitting near the deck plane, near-horizontal rays start INSIDE the slab and integrate a whole
    // slab-crossing of in-scatter from the first step, which painted a bright horizontal band around
    // the camera tracking it everywhere — the reported "line" that brightens everything nearby. The
    // fix is not another fade of coverage (coverage fading still lets the march accumulate light); the
    // slab itself is optically excluded inside the crossing region: sigma scales by the same crossFade
    // curve the flat path uses, so both extinction AND the in-scatter it feeds collapse together, and
    // at the mid-plane the deck contributes exactly nothing while the camera crosses it.
    float deckRel = push.clouds.w - originRel.y;
    float halfThickness = max(thickness, 0.5) * 0.5;
    float crossFade = smoothstep(halfThickness * 0.5, halfThickness * 1.5, abs(deckRel));
    if (crossFade <= 0.0) {
        return result;
    }
    float slabBottom = push.clouds.w - thickness * 0.5 - originRel.y;
    float slabTop = push.clouds.w + thickness * 0.5 - originRel.y;

    // Slab entry/exit along the ray. A near-horizontal ray inside the slab would march forever, so it
    // is bounded by the view limit like every other ray.
    float t0, t1;
    if (abs(dir.y) < 1.0e-4) {
        if (slabBottom > 0.0 || slabTop < 0.0) {
            return result; // parallel and outside the slab
        }
        t0 = 0.0;
        t1 = push.cloudAnchor.w;
    } else {
        float ta = slabBottom / dir.y;
        float tb = slabTop / dir.y;
        t0 = min(ta, tb);
        t1 = max(ta, tb);
    }
    t0 = max(t0, 0.0);
    t1 = min(t1, min(maxDistance, push.cloudAnchor.w));
    // Cap how far a single ray may travel INSIDE the slab. A ray looking at the horizon enters the deck
    // at a grazing angle and stays in it for hundreds of blocks, accumulating an optical depth no
    // vertical view ever reaches — which is why distant cloud went solid white even at low opacity and
    // low thickness, while the same cloud overhead looked correct. Real cumulus does not behave like an
    // infinite slab either: you see individual clouds with sky between them, not a continuous wall.
    //
    // A few slab depths is enough to fully develop a cloud, so clamping here costs nothing in the
    // near-field and removes the horizon wall entirely.
    t1 = min(t1, t0 + thickness * CLOUD_MAX_SLAB_CROSSINGS);
    if (t1 <= t0) {
        return result;
    }

    // Distance fade, matched to the flat style's horizon fade so the two agree about where cloud ends.
    float horizon = length(dir.xz) * t0;
    float fade = 1.0 - smoothstep(push.cloudAnchor.w * 0.55, push.cloudAnchor.w, horizon);
    if (fade <= 0.0) {
        return result;
    }

    float3 sunRadiance = push.lightRadiance.xyz;
    float3 lightDir = push.lightDir.xyz;
    float cosT = dot(dir, lightDir);
    float opacity = clamp(push.clouds.y, 0.0, 1.0);
    // Scale the step count to the distance actually being marched, so a thick deck is sampled as finely
    // as a thin one instead of just taking longer strides. Clamped both ways: never coarser than the
    // base count, never more expensive than the cap.
    int stepCap = highQuality ? CLOUD_MARCH_STEPS_MAX : CLOUD_MARCH_STEPS_CHEAP_MAX;
    marchSteps = clamp(int((t1 - t0) / CLOUD_TARGET_STEP_BLOCKS), marchSteps, stepCap);
    float stepLen = (t1 - t0) / float(marchSteps);
    bool classic = cloudStyle(push) == CLOUD_STYLE_CLASSIC;
    // Classic clouds are opaque boxes, not haze: they need a much higher extinction so a box saturates
    // within its own thickness instead of reading as translucent haze. Vanilla's clouds you cannot see
    // through, and that is the property being reproduced.
    // Extinction is normalised by the slab depth: a 100-block bank and a 10-block sheet reach the same
    // optical depth straight down, so THICKNESS controls shape and OPACITY controls see-through, with
    // no cross-talk. opacity is deliberately NOT folded in here — see the cap after the march.
    float sigma = CLOUD_EXTINCTION * (classic ? CLOUD_CLASSIC_EXTINCTION_SCALE : 1.0)
            * (CLOUD_REFERENCE_THICKNESS / max(thickness, 1.0)) * fade * crossFade;
    // Vanilla shades cloud faces by ORIENTATION with flat, constant tones — no smooth lighting model.
    // Reproducing that inside the march is what keeps the classic style looking like Minecraft even
    // though it is now a real volume: the box's top is bright, its underside dark, its vertical sides
    // in between, picked from the view direction the same way vanilla picks a quad's face.
    float classicFace = 1.0;
    if (classic) {
        float grazing = 1.0 - abs(dir.y);
        classicFace = dir.y < 0.0 ? 1.0 : 0.52;   // looking down at tops vs up at undersides
        classicFace = lerp(classicFace, 0.78, grazing);
    }

    // ---- Per-march lighting state, resolved once.
    //
    // `weather` is the genus model: one reading of the coverage and rain/thunder lanes that decides the
    // height profile, the bulge, the erosion and the storm absorption together, so no two parts of the
    // deck can disagree about what the sky is doing. The dither is per pixel and per frame (see
    // cloudDither) and offsets the march start, which is what turns the truncation banding into noise
    // the denoiser resolves.
    CloudWeather weather = cloudWeather(push);
    float dither = cloudDither(push);

    CloudLight light;
    light.sunRadiance = sunRadiance;
    light.skyRadiance = skyBehind;
    light.lightDir = lightDir;
    light.cosT = cosT;
    // Extinction per block of unit-density cloud. `sigma` already carries the slab-depth normalisation
    // and both fades; precipitating cloud adds absorption on top of it, which is why a storm's underside
    // reads grey-green rather than merely shadowed. Scattering follows extinction because liquid cloud's
    // single-scattering albedo is ~0.9999: cloud is dark from path length, not from absorption.
    //
    // The storm term is VOLUMETRIC-only. Classic already greys in rain through push.cloudColor (vanilla's
    // own CLOUD_COLOR), and adding absorption on top would darken the boxes twice for the same weather —
    // the classic style is meant to keep looking like Minecraft.
    light.sigmaT = sigma * (classic ? 1.0 : 1.0 + weather.absorbing * CLOUD_STORM_ABSORPTION);
    float sigmaS = light.sigmaT * CLOUD_SINGLE_SCATTER_ALBEDO;
    light.octaves = highQuality ? CLOUD_MULTI_SCATTER_OCTAVES : CLOUD_MULTI_SCATTER_OCTAVES_CHEAP;
    light.sunSteps = lightSteps;
    light.skySteps = highQuality ? CLOUD_SKY_STEPS : 0;
    // Sunlight reflected off the lit ground back up into the deck's underside — the term that lifts a
    // cloud base from black to soft grey. Nothing bounces when the light is below the horizon.
    light.groundRadiance = sunRadiance * (CLOUD_GROUND_ALBEDO * max(lightDir.y, 0.0));
    // The frame's cloud colour IS the deck's albedo tint: vanilla's own CLOUD_COLOR attribute, resolved
    // per dimension and per weather, so a storm greys the deck and a sunset warms it on the game's curve
    // rather than on a hand-tuned one. White in the Overworld on a clear day, so this changes nothing
    // about the default look — the volumetric style simply stopped ignoring the setting.
    light.albedo = CLOUD_ALBEDO * push.cloudColor.xyz;

    int detail = highQuality ? CLOUD_DETAIL_FULL : CLOUD_DETAIL_COARSE;
    // Distance LOD on the fine erosion octave. A 6-block lobe is sub-pixel past CLOUD_DETAIL_LOD_FAR,
    // and the atmosphere between the eye and the deck has already washed the contrast out of it, so the
    // hashes spent there buy nothing. The cheap tier never resolves it at all.
    float detailFade = highQuality
            ? 1.0 - smoothstep(CLOUD_DETAIL_LOD_NEAR, CLOUD_DETAIL_LOD_FAR, t0)
            : 0.0;

    // Dithered march start: the first sample sits a hashed fraction of a step in, so neighbouring pixels
    // and neighbouring frames truncate the integral at different places.
    float marchStart = t0 + stepLen * dither;
    for (int i = 0; i < marchSteps; i++) {
        if (result.transmittance < CLOUD_MIN_TRANSMITTANCE) {
            result.transmittance = 0.0;
            // The deck has gone opaque: nothing behind it can show through, and the remaining samples
            // are the most expensive thing in this loop (each is a light probe).
            break;
        }
        float3 p = originRel + dir * (marchStart + stepLen * float(i));
        float heightFrac = clamp((p.y - slabBottom) / max(slabTop - slabBottom, 1.0e-3), 0.0, 1.0);
        float density = cloudVolumeDensity(push, weather, p, heightFrac, thickness, detail, detailFade);
        if (density <= 0.0) {
            continue; // empty air: no extinction, and crucially no probes. Most of a scattered deck is.
        }
        float sigmaStep = light.sigmaT * density;
        float sampleTransmittance = exp(-sigmaStep * stepLen);
        float3 inScatter;
        if (classic) {
            // Flat, vanilla-style face tone: classic clouds are meant to look like Minecraft's boxes, not
            // like a cloud, so they keep the poster-flat shading and merely borrow the new probe.
            // Self-shadowing is deliberately damped (mixed only 40% in) so the boxes do not develop soft
            // volumetric gradients.
            float lightT = exp(-cloudSunOpticalDepth(push, weather, p, lightDir, slabBottom, thickness,
                                                     lightSteps, dither) * light.sigmaT);
            float shade = lerp(1.0, lightT, 0.4);
            inScatter = push.cloudColor.xyz * CLOUD_INV_PI
                    * (sunRadiance * classicFace * shade * 3.0 + skyBehind * 1.4);
        } else {
            inScatter = cloudSampleScatter(push, weather, light, p, density, heightFrac, slabBottom,
                                           thickness, dither);
        }
        // Energy-conserving accumulation. For a homogeneous step the exact integral of the source term S
        // attenuated by extinction sigma over a stride of length L is S * (sigma_s/sigma_t) * (1-e^-tau),
        // i.e. the single-scattering albedo times the light the step ABSORBED — independent of how long
        // the stride was. That is what makes the deck's brightness a property of the cloud rather than of
        // the march resolution: a coarse step through thin cloud and a fine one through thick cloud
        // deposit the same energy, so raising the step count refines the silhouette without brightening
        // the deck (the fixed-count version banded for exactly this reason).
        result.scatter += result.transmittance * inScatter * (sigmaS / max(light.sigmaT, 1.0e-6))
                * (1.0 - sampleTransmittance);
        result.transmittance *= sampleTransmittance;
    }

    // ---- Aerial perspective (volumetric only).
    //
    // The air between the eye and the deck dims the deck's own scatter and puts sky radiance in its
    // place, which is why distant clouds lose contrast and take on the horizon's colour instead of
    // simply vanishing. Blended over the same range as the density fade above, so the view-limit cutoff
    // is hidden by cloud dissolving INTO the sky rather than by cloud being deleted at a line. The target
    // is the sky radiance behind the deck weighted by how much of it the deck blocked — the ordinary
    // transmittance-ratio blend for aerial perspective through any participating medium.
    if (!classic) {
        float aerial = CLOUD_AERIAL_STRENGTH
                * smoothstep(CLOUD_DETAIL_LOD_NEAR, push.cloudAnchor.w, t0);
        result.scatter = lerp(result.scatter, skyBehind * (1.0 - result.transmittance), aerial);
    }

    // ---- Opacity as a genuine ceiling, applied ONCE to the finished march.
    //
    // It used to scale the extinction, which is per unit length — so the total optical depth still grew
    // with the slab depth and with the path length through it. That is why a low opacity still went
    // fully solid at 100% thickness, and why even a thin deck turned opaque toward the horizon, where a
    // grazing ray traverses hundreds of blocks of slab. The slider had no ceiling at all.
    //
    // Capping the finished result instead makes it exactly a blend between "no cloud" and "this cloud":
    // at 20% the cloud can never be more than 20% opaque, at any thickness, at any view angle. Scatter
    // is premultiplied so it scales by the same factor, which keeps
    // `background * transmittance + scatter` energy-correct.
    result.scatter *= opacity;
    result.transmittance = 1.0 - (1.0 - result.transmittance) * opacity;
    return result;
}

// ---- Unified entry point -------------------------------------------------------------------------

/**
 * Ambient sky fill for cloud shading when the real sky radiance is not available.
 *
 * The miss shader can pass the actual atmosphere result, but a ray that ends on terrain has no sky
 * value to hand — so this derives a cheap stand-in from the celestial radiance the frame is already
 * lit by. It follows the same day/night and weather curve as everything else, and keeps a small floor
 * so clouds at night are dark grey rather than black.
 */
public float3 cloudSkyAmbient(WorldPush push) {
    float3 sun = push.lightRadiance.xyz;
    return sun * 0.10 + float3(0.012, 0.017, 0.028);
}

/**
 * Clouds crossed along ONE ray segment, as premultiplied scattered radiance plus the transmittance the
 * background keeps. Both styles answer in this same form.
 *
 * This shape is deliberate: callers composite clouds with two lines
 * ({@code L += throughput * scatter; throughput *= transmittance;}), and being a premultiplied
 * participating-medium term inside the path integral is what gives clouds correct behaviour over
 * reflections, refractions and indirect bounces for free.
 *
 * `maxDistance` is the distance to the nearest scene hit along the ray (or a large value when the ray
 * escapes to the sky). Bounding the cloud by it is the fix for the "world shows through the clouds"
 * bug — see cloudSegmentNote below.
 */
public CloudVolume cloudSegment(WorldPush push, float3 originRel, float3 dir, float maxDistance,
                                float3 ambient, bool highQuality) {
    CloudVolume result;
    result.scatter = float3(0.0, 0.0, 0.0);
    result.transmittance = 1.0;
    if (!cloudsEnabled(push)) {
        return result;
    }
    // Three physical decks, picked by style and thickness:
    //   * classic with the authored map: ANALYTIC boxes — vanilla's exact cell geometry intersected
    //     directly, no march at all (cloudClassicBoxes). This is the normal classic path;
    //   * volumetric (and the classic map-unavailable fallback): the ray-marched slab;
    //   * a (near) zero thickness collapses to the flat sheet, which is what that slider setting asks
    //     for. It shades like the classic deck of whichever style is active.
    bool classic = cloudStyle(push) == CLOUD_STYLE_CLASSIC;
    if (push.cloudAnchor.z > CLOUD_FLAT_EPSILON) {
        if (classic && push.cloudCellsAddr != 0u) {
            return cloudClassicBoxes(push, originRel, dir, maxDistance, ambient);
        }
        return cloudMarch(push, originRel, dir, maxDistance, ambient, highQuality);
    }
    CloudHit h = cloudTrace(push, originRel, dir, maxDistance);
    if (!h.hit) {
        return result;
    }
    float alpha = cloudAlpha(push, h, cloudCoverage(push, h.samplePos));
    if (alpha <= 0.0) {
        return result;
    }
    // The flat sheet keeps each style's look: the authored colour for classic, the volumetric albedo
    // for the volumetric style (whose field and shading are otherwise untouched).
    float3 albedo = classic ? push.cloudColor.xyz : CLOUD_ALBEDO;
    float grazing = 1.0 - abs(dir.y);
    float faceLight = h.fromBelow ? 0.52 : 1.0;
    faceLight = lerp(faceLight, 0.78, grazing);
    // Premultiplied, so `background * transmittance + scatter` reproduces the lerp exactly.
    result.scatter = cloudRadianceClassic(push, faceLight, albedo, ambient) * alpha;
    result.transmittance = 1.0 - alpha;
    return result;
}

// THE BUG THIS FIXES. Clouds used to be composited only inside world.rmiss, which runs only when a ray
// hits NOTHING. Flying above the deck and looking down, the ray hits the ground — a hit, not a miss —
// so the clouds lying between the camera and that ground were never drawn at all and the world showed
// straight through them. Routing every consumer through cloudSegment with the real hit distance fixes
// both halves of that: cloud in FRONT of a surface is now drawn over it, and cloud BEHIND a surface is
// correctly rejected by the maxDistance test instead of being painted on top.

/** Composite clouds over a background in one call, for callers that hold a finished colour. */
public float3 cloudLayer(WorldPush push, float3 originRel, float3 dir, float maxDistance,
                         float3 background, float3 ambient, bool highQuality) {
    CloudVolume v = cloudSegment(push, originRel, dir, maxDistance, ambient, highQuality);
    return background * v.transmittance + v.scatter;
}
