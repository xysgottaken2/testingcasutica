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
//   * CLOUD_STYLE_VOLUMETRIC — photoreal cumulus built from INDIVIDUAL CLOUDS. Instead of one fBm slab
//     whose thresholded patches all share a single scale, the deck is a CELLULAR field: each lattice
//     cell is one cloud with its own hash-derived size, height, flatness and density, so no two
//     clouds look alike (small puffs, wide sheets, tall towers), with blue sky between them and a
//     thin, wispy CIRROSTRATUS layer floating in its own slab above the deck. Density is the smooth
//     sum of the surrounding cells' metaballs, domain-warped and cauliflower-eroded per cloud,
//     marched with light-marched self-shadowing, Beer-Lambert extinction, a dual-lobe
//     Henyey-Greenstein phase and a powder (dark-edge) term. Its thickness is FIXED on the Java side
//     (the slider is locked for this style) so per-cloud heights and the cirrus gap stay consistent.
//
// The classic style honours the thickness slider; the volumetric style uses a FIXED deck depth (the
// slider is locked for it on the Java side) so its per-cloud heights and the cirrus gap above stay
// consistent. The weather fill (cloudColor.w) closes either sky completely in a storm.
//
// DEPTH-CORRECT AGAINST THE WORLD. Every entry point that produces visible cloud takes the distance to
// the nearest scene hit and stops there, so terrain in front of a cloud occludes it. Getting this wrong
// is exactly the bug where the world appeared to punch through the deck from above (see cloudLayer).
//
// Only world_common is imported: world.rmiss must NOT pull in world_core (that module declares the
// raygen bindings), so every entry point here takes the WorldPush explicitly, exactly like
// world_common's own worldFeature/worldFlag accessors.

import world_common;

// ---- Pattern geometry. The field is EXACTLY periodic, because every hash in this module wraps its
// cell index to a period that divides the anchor wrap: cloudHash/cloudNoise repeat every 512 cells *
// 12 blocks = 6144, the cellular lattices repeat exactly at the wrap itself (256 * 96 = 24576 for
// cumulus, 128 * 192 for cirrus), and every detail scale is a power-of-two divisor of 24576. That is
// load-bearing, not decoration: RtComposite pushes a sample anchor already reduced modulo 24576
// (CLOUD_FIELD_PERIOD_BLOCKS — both to fold in the wind scroll, which grows without bound with world
// time, and to keep the anchor a small float far from a Minecraft world border's 30M-block
// coordinates). Wrapping an aperiodic noise would teleport the whole sky the moment the anchor rolled
// over; wrapping a periodic one is seamless. The repeat is four times the deck's own view limit, so it
// is never visible in one frame.
public static const float CLOUD_CELL_BLOCKS = 12.0; // vanilla's cloud cell size
public static const int   CLOUD_PERIOD_CELLS = 512; // power of two, so the wrap below is a mask
public static const int   CLOUD_CELL_MASK = CLOUD_PERIOD_CELLS - 1;
// Coverage ramp width for the classic noise-quantised fallback deck (see cloudCoverage). The
// volumetric style uses its own wider ramp over the cellular blob field (CLOUD_CELL_EDGE_SOFTNESS).
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
//     march and the full step count.
//   * CHEAP is used for diffuse indirect bounces. Those contribute a broad, low-frequency sky-fill term
//     that gets averaged over the hemisphere and then denoised; resolving cloud detail there is
//     invisible in the result but would multiply the cost by the bounce count. It keeps the same
//     extinction and phase, so the ENERGY stays right — only the detail is coarser.
// Quality comes from the light march and the phase function rather than raw step count.
public static const int   CLOUD_MARCH_STEPS = 32;
public static const int   CLOUD_LIGHT_STEPS = 12;
public static const int   CLOUD_MARCH_STEPS_CHEAP = 8;
public static const int   CLOUD_LIGHT_STEPS_CHEAP = 4;
// Upper bounds used when the step count is scaled to the path length (see cloudMarch). A fixed step
// COUNT means a deeper slab silently gets coarser steps, which bands: cloud lobes are tens of blocks
// wide, so a 60-block step walks straight past them. These cap the cost of that scaling.
public static const int   CLOUD_MARCH_STEPS_MAX = 64;
public static const int   CLOUD_MARCH_STEPS_CHEAP_MAX = 16;
// Target distance between samples. Comfortably finer than a lobe, so the march resolves shape; the
// volumetric detail noise is sampled at 24-block cells, so 5-block steps resolve it without the
// stepped, layered look a coarse stride produces.
public static const float CLOUD_TARGET_STEP_BLOCKS = 5.0;
public static const float CLOUD_EXTINCTION = 0.115; // per block, at density 1
// Optical depth is normalised against this thickness, so making the deck taller adds VOLUME without
// making it more opaque. Without it, tau = density * sigma * pathLength grows with the slab depth and
// the thickness slider silently doubles as a second opacity slider.
public static const float CLOUD_REFERENCE_THICKNESS = 40.0;
// Longest in-slab path a single ray may integrate, in slab depths. Bounds the grazing/horizon case
// (see cloudMarch); a few crossings already saturate a real cloud.
public static const float CLOUD_MAX_SLAB_CROSSINGS = 3.5;
// Octave divisor for the domain warp. Each divisor is another space the periodic hash is sampled in,
// so the anchor wrap (24576 blocks, see CLOUD_FIELD_PERIOD_BLOCKS in Java) must be a whole hash period
// in every one of them simultaneously. cloudNoise has a 512-cell period at 12 blocks per cell, so its
// period at divisor D is 512 * 12 * D blocks; all of these are powers of two, giving periods 12288 /
// 6144 / 1536 that each divide 24576 exactly. (The old volumetric model had a CLOUD_VOLUMETRIC_SCALE
// lane for the same reason; the cellular model samples its lattices directly and needs no scale lane
// at all — see the cellular-field note below. The 3D cauliflower detail inside cloudVolumeDensity
// carries its own explicit wrap masks instead.)
public static const float CLOUD_WARP_DIV = 2.0;
// How much wider a cloud gets around its belly than at its base/crown. Deliberately modest and
// base-heavy (the belly peak sits in the lower-middle of each cloud) — a strong symmetric bulge is
// what made clouds read as barrels. See the note in cloudVolumeDensity.
public static const float CLOUD_BULGE = 0.22;
public static const float CLOUD_HG_G = 0.72;        // forward-scattering anisotropy of cloud droplets
public static const float CLOUD_HG_BACK = -0.28;    // weak backward lobe (see cloudPhase)
public static const float CLOUD_POWDER_STRENGTH = 0.7; // dark-edge / multiple-scattering approximation
// Classic clouds are opaque boxes; this scales their extinction so a box saturates within its own
// thickness rather than looking like translucent haze.
public static const float CLOUD_CLASSIC_EXTINCTION_SCALE = 6.0;

// ---- Cellular cumulus lattice (volumetric style).
//
// Real skies are collections of individual clouds — small puffs, wide sheets, tall towers — not a
// threshold of one noise field, which is why the old fBm deck read as a single repeated texture.
// The volumetric deck is therefore built on a CELLULAR field: one "cloud system" per lattice cell,
// each with hash-derived properties (presence, radius, flatness, top, bottom, density, billow).
// Density is the smooth sum of the surrounding cells' metaballs, so clouds merge into banks where
// cells overlap and stay distinct where they do not, and the presence hash leaves gaps of open sky.
//
// SIZES ARE REAL. A real cumulus is roughly a kilometre across AND about as tall as it is wide
// (Stull: fair-weather cumulus ~1 km, congestus much taller than wide, cloud diameters lognormally
// distributed with a long tail of giants). At 1 block = 1 metre a 1 km cloud is 1000 blocks — too
// wide for a single cell, so big clouds are built from a few overlapping cells while single cells
// span ~150-500 blocks. The old lattice (96-block cells, radius 0.55-1.25 cells) produced clouds
// that shrank to a third of their nominal radius once thresholded — 34-80 blocks, small puffs
// instead of clouds. This lattice uses 192-block cells and a flatter falloff that holds ~60% of the
// radius, and the footprint stays BROAD for every shape (see cloudLatticeCell) — no skinny barrels,
// no pancakes — while the 3D cauliflower erosion breaks up the silhouette so nothing reads as a
// smooth round blob.
//
// DEPTH IS REAL TOO. The volumetric slab is FIXED at 384 blocks deep (CLOUD_VOLUMETRIC_THICKNESS_BLOCKS
// in RtComposite), so tower crowns reach ~375 blocks while flat sheets stay thin — the deck reads as
// deep, heaped cumulus instead of a pancake layer. The per-cell top/bottom fractions below span that
// whole depth, so height varies from thin bands (sheets) to near-full-slab towers.
//
// Periodicity: 128 cells * 192 blocks = 24576 blocks, exactly the anchor wrap
// (CLOUD_FIELD_PERIOD_BLOCKS in RtComposite) — every cell wraps onto itself at the seam, so the
// field is seamless by construction, with no scale factor to desync. All the detail scales below
// are power-of-two divisors of this same period (see the per-function notes). The largest radius
// is clamped to 2.4 cells = 460 blocks, below the ~480-block reach of the nearest two-ring cell,
// so the 3x3 neighbourhood below is exact.
public static const float CLOUD_LATTICE_BLOCKS = 192.0;
public static const int   CLOUD_LATTICE_MASK = 127;        // 128 cells -> 24576 blocks
// Footprint radius, in lattice cells. Broad by design — see cloudLatticeCell. These are only the
// hard clamp bounds; the upper one keeps the 3x3 neighbourhood exact (2.4 cells < the 2.5-cell
// reach of the nearest ring-2 cell).
public static const float CLOUD_LATTICE_RADIUS_MIN = 0.9;
public static const float CLOUD_LATTICE_RADIUS_MAX = 2.4;
// Presence is squared (hash^2) before use: uniform hash would leave ~half the sky covered by
// overlapping big clouds at the default slider — the real sky has large clouds with BLUE SKY between
// them. Squaring skews cells toward low presence (gaps) with a few strong ones (the big clouds),
// which also mirrors the lognormal size distribution of real cloud fields. See cloudLatticeCell.
public static const float CLOUD_LATTICE_PRESENCE_EXP = 2.0;
// Coverage ramp width over the blob field. The metaball sum is much smoother than raw noise, so the
// ramp is a little wider than the old noise field's (CLOUD_EDGE_SOFTNESS) to keep edges soft.
public static const float CLOUD_CELL_EDGE_SOFTNESS = 0.30;

// ---- Cirrostratus veil (volumetric style only).
//
// A thin, wide, wispy sheet ABOVE the cumulus deck — the high layer of a real sky. Cirrostratus is
// nearly transparent: it dims the sky softly and catches the sun, but never blocks it the way
// cumulus does, so it is integrated with low extinction and no self-shadow light march.
//
// The lattice is 64 cells of 384 blocks = 24576 blocks — the same wrap, a coarser scale — so the
// veil and the deck stay seamlessly periodic together. The veil floats a fixed gap above the
// cumulus slab top inside its own thin slab; both bounds are derived from the pushed deck, so the
// two layers always stay in the same relationship no matter where the player puts the deck height.
public static const float CLOUD_CIRRUS_LATTICE_BLOCKS = 384.0;
public static const int   CLOUD_CIRRUS_MASK = 63;          // 64 cells -> 24576 blocks
public static const float CLOUD_CIRRUS_RADIUS_MIN = 1.1;   // veil systems are WIDE — kilometres
public static const float CLOUD_CIRRUS_RADIUS_MAX = 1.6;
public static const float CLOUD_CIRRUS_GAP_BLOCKS = 96.0;  // gap above the cumulus slab top
public static const float CLOUD_CIRRUS_SLAB_THICKNESS = 64.0;
// Cirrus extinction is well below cumulus (0.115 * 40/64 reference): at full coverage and an average
// band the integrated optical depth comes out ~0.3, so the densest veil still lets ~75% of the light
// through — nearly transparent, exactly what makes it a veil rather than a second cloud deck.
public static const float CLOUD_CIRRUS_EXTINCTION_SCALE = 0.55;
// How much of the (soft, diffuse) cirrus shadow feeds the cloudShadowStrength slider.
public static const float CLOUD_CIRRUS_SHADOW_STRENGTH = 0.30;
public static const int   CLOUD_CIRRUS_STEPS = 10;
public static const int   CLOUD_CIRRUS_STEPS_CHEAP = 4;

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

// 3D hash for the volumetric detail noise. `wrapMask` keeps the X and Z axes periodic at the caller's
// chosen scale (a power-of-two cell count over the 24576-block wrap — the same trick cloudHash uses);
// Y needs no wrap: the density is only ever sampled inside the finite slab, so it never crosses a
// period. Mixing the three axes with distinct primes keeps the lobes isotropic.
uint cloudHash3(int3 p, int2 wrapMask) {
    uint3 c = uint3(uint(p.x & wrapMask.x), uint(p.y & wrapMask.y), uint(p.z));
    uint h = c.x * 374761393u + c.y * 668265263u + c.z * 1442695040u;
    h = (h ^ (h >> 13u)) * 1274126177u;
    h = h ^ (h >> 16u);
    return h;
}

/**
 * 3D value noise, smoothstep-interpolated (8 hashes per sample). This is what gives clouds their
 * CAULIFLOWER: a 2D noise can roughen the footprint but leaves the vertical profile smooth, so clouds
 * read as round blobs with flat, layered tops; 3D lobes carve lumpy crowns, ragged bases and
 * irregular silhouettes the way real cumulus looks (and the way UE5's Perlin-Worley base + detail
 * erosion does it).
 */
float cloudNoise3D(float3 p, int2 wrapMask) {
    int3 i = int3(floor(p));
    float3 f = frac(p);
    float3 u = f * f * (3.0 - 2.0 * f);
    float h000 = cloudHash3(i, wrapMask);
    float h100 = cloudHash3(i + int3(1, 0, 0), wrapMask);
    float h010 = cloudHash3(i + int3(0, 1, 0), wrapMask);
    float h110 = cloudHash3(i + int3(1, 1, 0), wrapMask);
    float h001 = cloudHash3(i + int3(0, 0, 1), wrapMask);
    float h101 = cloudHash3(i + int3(1, 0, 1), wrapMask);
    float h011 = cloudHash3(i + int3(0, 1, 1), wrapMask);
    float h111 = cloudHash3(i + int3(1, 1, 1), wrapMask);
    float x00 = lerp(h000, h100, u.x);
    float x10 = lerp(h010, h110, u.x);
    float x01 = lerp(h001, h101, u.x);
    float x11 = lerp(h011, h111, u.x);
    return lerp(lerp(x00, x10, u.y), lerp(x01, x11, u.y), u.z);
}

/**
 * Raw coverage field in [0,1], before either style interprets it. Three octaves at INTEGER scales with
 * whole-cell offsets, so every octave shares the base period and the sum stays exactly periodic — see
 * the note on CLOUD_CELL_BLOCKS.
 *
 * This is the fallback shape source for the CLASSIC style when the authored clouds.png map is
 * unavailable (cloudCellsAddr == 0), preserving the old noise-quantised deck; the volumetric style
 * uses the cellular lattice instead (see cloudLatticeSample).
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
 * VOLUMETRIC uses the cellular cumulus field: the smooth sum of the surrounding lattice cells'
 * metaballs (cloudLatticeSample), thresholded exactly like the old noise ramp. Full overcast
 * short-circuits to exactly 1: smoothstep never reaches 1 below threshold + EDGE, so a plain merge
 * would keep a residue of pinholes at "100%" coverage — and a storm sky has no pinholes.
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
    return cloudCoverageVolumetric(push, samplePos);
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
    float shadow = 1.0;
    // The cumulus deck: points at or above its mid-plane get t <= 0 and are unshadowed by it for free.
    if (t > 0.0) {
        float2 samplePos = push.cloudAnchor.xy + pointRel.xz + lightDir.xz * t;
        float alpha = clamp(cloudCoverage(push, samplePos) * clamp(push.clouds.y, 0.0, 1.0), 0.0, 1.0);
        shadow = 1.0 - strength * alpha;
    }
    // The cirrostratus veil above the deck casts a soft, diffuse shadow of its own. It is far weaker
    // than the cumulus footprint (thin, nearly transparent cloud), and it uses the cheap veil
    // approximation so the whole query stays one analytic plane + one noise sample (see
    // cloudCirrusShadowAlpha). Points at or above the veil get tc <= 0 and are unshadowed by it for
    // free — including points that sit between the two layers, which the cumulus plane no longer
    // shadows.
    if (cirrusEnabled(push)) {
        float cumulusTopRel = push.clouds.w + push.cloudAnchor.z * 0.5 - pointRel.y;
        float cirrusMidRel = cumulusTopRel + CLOUD_CIRRUS_GAP_BLOCKS
                + CLOUD_CIRRUS_SLAB_THICKNESS * 0.5;
        float tc = cirrusMidRel / lightDir.y;
        if (tc > 0.0) {
            float2 cirrusPos = push.cloudAnchor.xy + pointRel.xz + lightDir.xz * tc;
            float cirrusAlpha = cloudCirrusShadowAlpha(push, cirrusPos);
            shadow *= 1.0 - strength * CLOUD_CIRRUS_SHADOW_STRENGTH * cirrusAlpha;
        }
    }
    return shadow;
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

/** Single Henyey-Greenstein lobe. */
float hgLobe(float cosT, float g) {
    float g2 = g * g;
    float d = 1.0 + g2 - 2.0 * g * cosT;
    return (1.0 - g2) / (4.0 * 3.14159265359 * max(d * sqrt(max(d, 1.0e-6)), 1.0e-4));
}

/**
 * Dual-lobe phase. A single forward lobe gives the sun-facing glow but leaves the rest of the cloud
 * flat; real droplet scattering also has a weak backward lobe, which is what lights the side of a cloud
 * facing away from the sun and stops it collapsing into a silhouette. Mixing the two is the standard
 * cheap stand-in for a full Mie phase and costs one extra lobe evaluation.
 */
float cloudPhase(float cosT) {
    return lerp(hgLobe(cosT, CLOUD_HG_BACK), hgLobe(cosT, CLOUD_HG_G), 0.7);
}

/**
 * Powder / dark-edge term. Multiple scattering makes the dense INTERIOR of a cloud brighter than its
 * thin edges when lit from behind the viewer — the opposite of what single-scattering alone predicts,
 * and its absence is why cheap volumetric clouds look like flat grey cotton. Approximated from local
 * density, which is the standard Frostbite/Horizon trick.
 */
float cloudPowder(float density) {
    return 1.0 - exp(-density * 4.0);
}

// ---- Cellular cumulus field ----------------------------------------------------------------------

// Per-cell cloud attributes. Two 32-bit hashes per cell are unpacked into 8-bit slices, so the whole
// neighbourhood costs a handful of integer mixes rather than a hash per attribute.
struct CloudCell {
    float presence; // how much cloud this cell owns (0..1); near-zero cells are the gaps of open sky
    float radius;   // footprint radius in lattice cells (see CLOUD_LATTICE_RADIUS_MIN/MAX)
    float flatness; // 0 = tall tower, 1 = wide flat sheet
    float top;      // crown height as a fraction of the slab (0.40..1.00)
    float bottom;   // base height as a fraction of the slab (0.02..0.34)
    float density;  // optical density multiplier (0.65..1.30)
    float billow;   // how much cauliflower erosion the crown gets (0.35..1.25)
};

uint cloudLatticeHashU(int2 cell, uint seed) {
    // Same integer mix as cloudHash, but masked to the 256-cell lattice period so the field repeats
    // exactly at 24576 blocks (see CLOUD_LATTICE_MASK). The seed lane decorrelates attributes that
    // share a cell.
    uint2 c = uint2(uint(cell.x & CLOUD_LATTICE_MASK), uint(cell.y & CLOUD_LATTICE_MASK));
    uint h = c.x * 374761393u + c.y * 668265263u + seed * 2246822519u;
    h = (h ^ (h >> 13u)) * 1274126177u;
    h = h ^ (h >> 16u);
    return h;
}

CloudCell cloudLatticeCell(int2 cell) {
    uint h0 = cloudLatticeHashU(cell, 0u);
    uint h1 = cloudLatticeHashU(cell, 1u);
    CloudCell c;
    // Presence is squared (see CLOUD_LATTICE_PRESENCE_EXP): most cells stay near zero — the open sky
    // between clouds — while the strong tail becomes the big clouds. A squared hash is the cheapest
    // way to get that skew and it keeps the field exactly periodic.
    float p = float(h0 & 0xffu) * (1.0 / 255.0);
    c.presence = p * p;
    // The vertical extent couples to flatness: towers span almost the whole slab (low base, high
    // crown — real congestus is taller than it is wide), while flat sheets hug a thin band high in
    // the slab (real stratocumulus). The tower crown can reach 100% of the 384-block slab, so the
    // tallest towers are ~375 blocks; sheets stay ~30-100. A mild skew (pow 1.2) keeps the sky
    // mostly round puffs and broad towers with a few flat sheets.
    float flatN = float((h0 >> 16u) & 0xffu) * (1.0 / 255.0);
    float radN = float((h0 >> 8u) & 0xffu) * (1.0 / 255.0);
    c.flatness = pow(flatN, 1.2);
    float topN = float(h1 & 0xffu) * (1.0 / 255.0);
    float botN = float((h1 >> 8u) & 0xffu) * (1.0 / 255.0);
    c.top = lerp(lerp(0.55, 1.00, topN), lerp(0.40, 0.52, topN), c.flatness);
    c.bottom = lerp(lerp(0.02, 0.22, botN), lerp(0.24, 0.34, botN), c.flatness);
    // Footprint: BROAD regardless of height, with the floor set high enough that even the tallest
    // tower is a wide column, never a thin barrel (real congestus is roughly as wide as it is tall,
    // and the coverage ramp only keeps ~60% of the nominal radius). Sheets spread wider via the
    // flatness factor, exactly how stratocumulus spreads out. Coupling the radius to the vertical
    // span was tried and shrank the clouds back into small puffs — the barrel look was actually the
    // SMOOTH SILHOUETTE (symmetric bulge, smooth crown), which the 3D erosion and the base-heavy
    // bulge below fix instead. Clamped to keep the 3x3 neighbourhood exact (max 2.4 cells).
    c.radius = clamp(lerp(1.2, 2.1, c.flatness) * lerp(0.95, 1.15, radN),
                     CLOUD_LATTICE_RADIUS_MIN, CLOUD_LATTICE_RADIUS_MAX);
    c.density = lerp(0.65, 1.30, float((h1 >> 16u) & 0xffu) * (1.0 / 255.0));
    c.billow = lerp(0.35, 1.25, float((h1 >> 24u) & 0xffu) * (1.0 / 255.0));
    return c;
}

/**
 * Metaball falloff: (1 - rel^2)^2 — flat near the centre and zero beyond the radius with zero slope,
 * so a finite neighbourhood is exact (C1). The flatter plateau is what keeps a cloud near its full
 * nominal radius instead of shrinking to a third of it: at the coverage threshold (~0.45) a single
 * cell still holds ~60% of its radius (the old linear (1 - rel)^2 cut at ~33%).
 */
float cloudLatticeWeight(float distBlocks, float radiusBlocks) {
    float rel = distBlocks / max(radiusBlocks, 1.0);
    float w = 1.0 - rel * rel;
    w = max(w, 0.0);
    return w * w;
}

/** Blended neighbourhood sample: raw blob sum plus attribute fields weighted by the same falloff. */
struct CloudCellSample {
    float blob;     // raw weighted presence sum, BEFORE thresholding (see cloudCoverageVolumetric)
    float bottom;   // blended base fraction
    float top;      // blended crown fraction
    float flatness; // blended flatness
    float density;  // blended density multiplier
    float billow;   // blended erosion amount
};

CloudCellSample cloudLatticeSample(float2 samplePos) {
    float2 uv = samplePos / CLOUD_LATTICE_BLOCKS;
    int2 base = int2(floor(uv));
    CloudCellSample s;
    s.blob = 0.0;
    s.bottom = 0.0;
    s.top = 0.0;
    s.flatness = 0.0;
    s.density = 0.0;
    s.billow = 0.0;
    float totalW = 0.0;
    // 3x3 neighbourhood, exact: the radius is clamped to 2.4 cells = 460 blocks, which is less than
    // the ~480-block reach of the nearest ring-2 cell centre (2.5 cells away), so no cell outside the
    // 3x3 ring can ever contribute.
    for (int dz = -1; dz <= 1; dz++) {
        for (int dx = -1; dx <= 1; dx++) {
            int2 cell = base + int2(dx, dz);
            CloudCell a = cloudLatticeCell(cell);
            float2 centre = float2(float(cell.x), float(cell.y)) * CLOUD_LATTICE_BLOCKS
                    + float2(CLOUD_LATTICE_BLOCKS * 0.5, CLOUD_LATTICE_BLOCKS * 0.5);
            float dist = length(samplePos - centre);
            float w = cloudLatticeWeight(dist, a.radius * CLOUD_LATTICE_BLOCKS);
            // Weight by presence too, so empty cells neither add blob nor drag the blended
            // attributes: a cloud's shape is decided by the cells that actually own cloud.
            w *= a.presence;
            s.blob += w;
            s.bottom += a.bottom * w;
            s.top += a.top * w;
            s.flatness += a.flatness * w;
            s.density += a.density * w;
            s.billow += a.billow * w;
            totalW += w;
        }
    }
    float inv = 1.0 / max(totalW, 1.0e-4);
    s.bottom *= inv;
    s.top *= inv;
    s.flatness *= inv;
    s.density *= inv;
    s.billow *= inv;
    return s;
}

/**
 * Volumetric coverage from the cellular cumulus field: the blob sum thresholded against the
 * weather-merged coverage.
 *
 * The threshold maps the coverage SLIDER onto the blob scale. The blob is the presence-weighted sum
 * of the surrounding metaballs: in a fully merged cell it reaches ~2-3.5 (several strong cells
 * overlapping), and an isolated strong cell reaches ~1-1.5. With the naive threshold (1 - merged)
 * the slider would need to pass 1.5 before a cloud even appeared — the deck would be sky until
 * "70%", then flood. Instead the threshold goes DOWN with coverage, exactly like the old noise ramp:
 * lerp(2.2, 0.45, merged) is calibrated (via simulation of the lattice field) so 0 stays empty,
 * the default 0.55 gives scattered big cumulus with plenty of blue sky, and 1.0 is a near-overcast.
 */
float cloudCoverageVolumetric(WorldPush push, float2 samplePos) {
    float retain = clamp(push.clouds.x, 0.0, 1.0);
    float fill = clamp(push.cloudColor.w, 0.0, 1.0);
    float merged = retain + (1.0 - retain) * fill;
    if (merged >= 1.0) {
        return 1.0; // full storm: full sky, skip the lookup
    }
    if (merged <= 0.0) {
        return 0.0;
    }
    CloudCellSample s = cloudLatticeSample(samplePos);
    float blob = s.blob;
    if (blob <= 0.0) {
        return 0.0;
    }
    float threshold = lerp(2.2, 0.45, merged);
    return smoothstep(threshold, threshold + CLOUD_CELL_EDGE_SOFTNESS, blob);
}

/**
 * 3D density inside the slab, per style.
 *
 * CLASSIC is a box: the density is the quantised cell coverage, constant through the whole thickness
 * with only a hair of taper at the very top and bottom faces. That is deliberately NOT billowy — it is
 * what makes the marched result read as vanilla's solid cuboid clouds rather than a soft blob, and it
 * is why the classic style still looks like Minecraft once it has real height.
 *
 * VOLUMETRIC is cumulus, and each cloud is its own individual (see the cellular field above): the
 * blended cell attributes give every cloud its own vertical extent (a sheet's flat band vs a tower's
 * full-slab span), its own bulge around its own middle, its own warp strength and its own erosion, so
 * no two clouds in the sky share a silhouette.
 */
float cloudVolumeDensity(WorldPush push, float3 posRel, float heightFrac) {
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

    // ---- Volumetric cumulus: individual clouds, no two alike.
    //
    // The old volumetric deck was one fBm slab: thresholding a noise field produces patches that all
    // share one scale, one height profile and one silhouette, which is why the sky read as a single
    // repeated texture instead of as a collection of clouds. Real skies are collections of SEPARATE
    // clouds — tiny puffs, wide sheets, tall towers — each with its own size, height and shape, with
    // blue sky between them.
    //
    // The deck is now built on the CELLULAR field above: one cloud per lattice cell with hash-derived
    // presence, radius, flatness, top, bottom, density and billow, blended across the 3x3
    // neighbourhood. The blob sum decides where cloud is (clouds merge into banks where cells
    // overlap, stay distinct where they do not, and gaps of open sky fall between), and the blended
    // attributes decide what kind of cloud it is.
    CloudCellSample s = cloudLatticeSample(samplePos);
    if (s.blob <= 0.0) {
        return 0.0;
    }
    float retain = clamp(push.clouds.x, 0.0, 1.0);
    float fill = clamp(push.cloudColor.w, 0.0, 1.0);
    float merged = retain + (1.0 - retain) * fill;
    // Same slider-to-blob mapping as cloudCoverageVolumetric — the density and the coverage/shadow
    // answer must agree about where cloud is (see that function's note on the threshold).
    float threshold = lerp(2.2, 0.45, merged);
    float coverage = merged >= 1.0 ? 1.0
            : smoothstep(threshold, threshold + CLOUD_CELL_EDGE_SOFTNESS, s.blob);
    if (coverage <= 0.0) {
        return 0.0;
    }

    // Per-cell vertical extent, blended across neighbours so one cloud's crown flows into the next.
    // The bottom is the condensation level (flat, fairly sharp); the crown is rounded and pushes
    // higher where the cloud is denser, so a dense core billows into a tower while a thin edge stays
    // low and flat — the same behaviour as the old towerTop, but per cloud instead of per field.
    float bottomFrac = clamp(s.bottom, 0.0, 0.55);
    float topFrac = clamp(s.top, bottomFrac + 0.08, 1.0);
    float hfLocal = (hf - bottomFrac) / max(topFrac - bottomFrac, 1.0e-3);
    float baseEdge = smoothstep(bottomFrac - 0.08, bottomFrac + 0.03, hf);
    // Real cumulus congestion is capped by the inversion: a tower's crown flattens at its top instead
    // of rounding off. Towers (flatness low) get a hard crown; sheets (flatness high) keep the soft
    // rounded top — a stratus sheet has no cauliflower crown to flatten.
    float crownStart = lerp(topFrac * 0.70, topFrac, coverage);
    float crownSoft = 1.0 - smoothstep(crownStart, topFrac, hf);
    float crownHard = 1.0 - smoothstep(topFrac - 0.10, topFrac, hf);
    float crownEdge = lerp(crownHard, crownSoft, clamp(s.flatness, 0.0, 1.0));
    float profile = baseEdge * crownEdge;
    if (profile <= 0.0) {
        return 0.0;
    }

    // Gentle base-heavy bulge: widest in the LOWER-middle, like real cumulus. The old symmetric
    // mid-height bulge made every cloud a barrel — widest at exactly half height with smooth sides.
    float belly = 1.0 - abs(hfLocal - 0.38) * 1.6;
    coverage = clamp(coverage + smoothstep(0.0, 1.0, max(belly, 0.0)) * CLOUD_BULGE - CLOUD_BULGE * 0.30,
                     0.0, 1.0);
    if (coverage <= 0.0) {
        return 0.0;
    }

    // Domain warp, amplitude growing with height and scaled to the bigger cells: bases stay flat,
    // crowns curl into rounded lobes. All sampled scales stay within the shared 24576-block period
    // (see the constants note: /24 -> period 12288, /12 -> 6144, /3 -> 1536, all dividing it).
    float hfLocalClamped = clamp(hfLocal, 0.0, 1.0);
    float2 warpUv = samplePos / (CLOUD_CELL_BLOCKS * CLOUD_WARP_DIV);
    float2 warp = float2(cloudNoise(warpUv), cloudNoise(warpUv + float2(41.0, 17.0))) - 0.5;
    float2 warped = samplePos + warp * CLOUD_LATTICE_BLOCKS * (0.30 + 0.60 * hfLocalClamped);

    // 3D CAULIFLOWER — the change that kills the "round blob" look. The old detail was 2D: it
    // roughened the footprint but left the vertical profile smooth, which is why clouds read as
    // round blobs with flat, layered tops (and, seen from the side, as horizontal slabs). Two
    // octaves of 3D lobes (96 and 24 blocks) carve lumpy crowns, ragged bases and irregular
    // silhouettes the way UE5's Perlin-Worley base + detail erosion does, while the dense core
    // stays intact. The x/z masks make each octave exactly periodic over the 24576-block wrap
    // (24576/96 = 256 cells and 24576/24 = 1024 cells, both powers of two); y needs no wrap —
    // density is only sampled inside the finite slab.
    float3 dUv = float3(warped.x, posRel.y, warped.y);
    float lobes1 = 1.0 - abs(cloudNoise3D(dUv / 96.0 + float3(11.0, 0.0, 17.0), int2(255, 255)) * 2.0 - 1.0);
    float lobes2 = 1.0 - abs(cloudNoise3D(dUv / 24.0 + float3(5.0, 0.0, 29.0), int2(1023, 1023)) * 2.0 - 1.0);
    float detail = lobes1 * 0.45 + lobes2 * 0.55;

    // Erode hardest at the silhouette (footprint edge and top/bottom extremes), least in the core:
    // the shape becomes irregular without the cloud dissolving into fog. The cell's own billow
    // decides how churned it is; flat sheets stay calm (damped by flatness).
    float edge = 1.0 - coverage;
    float extremes = smoothstep(0.55, 1.0, hfLocalClamped) * 0.85
            + smoothstep(0.15, 0.0, hfLocalClamped) * 0.5;
    float erosion = detail * (0.30 + 0.70 * (edge * 0.60 + extremes * 0.40)) * s.billow;
    erosion *= lerp(1.0, 0.55, clamp(s.flatness, 0.0, 1.0));

    // Dense core: cumulus interiors are optically thick, and a field that peaks at ~0.5 can never look
    // like anything but haze no matter how deep the slab is. The cell's own density multiplier sets
    // the final optical thickness, so some clouds read denser than others at the same size.
    float density = coverage * (0.85 + 0.75 * coverage) - erosion;
    density *= s.density;
    return clamp(density, 0.0, 1.0) * profile;
}

// ---- Cirrostratus veil ---------------------------------------------------------------------------

/** Whether the thin cirrostratus layer above the volumetric deck is active this frame. */
public bool cirrusEnabled(WorldPush push) {
    return worldFeature(push, FEATURE_CLOUDS_CIRRUS);
}

// Per-cell attributes of the cirrus lattice. Same unpacking trick as the cumulus lattice: two hashes
// per cell, sliced into 8-bit fields.
struct CloudCirrusSample {
    float blob;    // raw weighted presence sum
    float band;    // vertical band width as a fraction of the cirrus slab (0.10..0.34)
    float density; // optical density multiplier (0.30..0.60)
    float wisp;    // wispy erosion amount (0.40..1.20)
};

uint cloudCirrusHashU(int2 cell, uint seed) {
    // Same mix as the cumulus lattice with different seeds, so the veil decorrelates from the deck.
    uint2 c = uint2(uint(cell.x & CLOUD_CIRRUS_MASK), uint(cell.y & CLOUD_CIRRUS_MASK));
    uint h = c.x * 1540483477u + c.y * 1442695040u + seed * 2654435761u;
    h = (h ^ (h >> 13u)) * 1274126177u;
    h = h ^ (h >> 16u);
    return h;
}

CloudCirrusSample cloudCirrusSample(float2 samplePos) {
    float2 uv = samplePos / CLOUD_CIRRUS_LATTICE_BLOCKS;
    int2 base = int2(floor(uv));
    CloudCirrusSample s;
    s.blob = 0.0;
    s.band = 0.0;
    s.density = 0.0;
    s.wisp = 0.0;
    float totalW = 0.0;
    // 3x3 neighbourhood, exact: the largest reachable radius is 1.6 * 384 = 614 blocks, less than the
    // ~960-block reach of the nearest ring-2 cell centre (2.5 cells away), so no cell outside the 3x3
    // ring can ever contribute.
    for (int dz = -1; dz <= 1; dz++) {
        for (int dx = -1; dx <= 1; dx++) {
            int2 cell = base + int2(dx, dz);
            uint h0 = cloudCirrusHashU(cell, 0u);
            uint h1 = cloudCirrusHashU(cell, 1u);
            float presence = float(h0 & 0xffu) * (1.0 / 255.0);
            float radius = lerp(CLOUD_CIRRUS_RADIUS_MIN, CLOUD_CIRRUS_RADIUS_MAX,
                                float((h0 >> 8u) & 0xffu) * (1.0 / 255.0));
            float band = lerp(0.10, 0.34, float((h0 >> 16u) & 0xffu) * (1.0 / 255.0));
            float density = lerp(0.30, 0.60, float(h1 & 0xffu) * (1.0 / 255.0));
            float wisp = lerp(0.40, 1.20, float((h1 >> 8u) & 0xffu) * (1.0 / 255.0));
            float2 centre = float2(float(cell.x), float(cell.y)) * CLOUD_CIRRUS_LATTICE_BLOCKS
                    + float2(CLOUD_CIRRUS_LATTICE_BLOCKS * 0.5, CLOUD_CIRRUS_LATTICE_BLOCKS * 0.5);
            float dist = length(samplePos - centre);
            float w = cloudLatticeWeight(dist, radius * CLOUD_CIRRUS_LATTICE_BLOCKS) * presence;
            s.blob += w;
            s.band += band * w;
            s.density += density * w;
            s.wisp += wisp * w;
            totalW += w;
        }
    }
    float inv = 1.0 / max(totalW, 1.0e-4);
    s.band *= inv;
    s.density *= inv;
    s.wisp *= inv;
    return s;
}

/**
 * Density of the cirrostratus veil at a point inside the cirrus slab.
 *
 * Coverage is the cirrus blob thresholded against the weather-merged coverage, gated by a large-scale
 * VEIL field that organises the layer into systems (clear sky between them) instead of a uniform
 * haze. The vertical profile is a thin band that UNDULATES (real cirrus is not a flat ribbon), and
 * fibrous filaments — 3D noise stretched long along the wind axis x, short across z and thin
 * through the band — carry nearly all of the visible density, so the veil reads as drifting wisps
 * rather than a grey sheet. Density stays well below cumulus: this is the nearly transparent high
 * layer.
 */
float cloudCirrusDensity(WorldPush push, float2 samplePos, float heightFrac) {
    float retain = clamp(push.clouds.x, 0.0, 1.0);
    float fill = clamp(push.cloudColor.w, 0.0, 1.0);
    float merged = retain + (1.0 - retain) * fill;
    if (merged <= 0.02) {
        return 0.0;
    }
    CloudCirrusSample s = cloudCirrusSample(samplePos);
    if (s.blob <= 0.0) {
        return 0.0;
    }
    // The veil's own large-scale field, so systems of cirrus drift across the sky with clear air
    // between them. Sampled at 48-block noise cells (~500 m): a wide veil is a few of those, and the
    // scale is a divisor of the wrap (period 24576).
    float veil = cloudNoise(samplePos / (CLOUD_CELL_BLOCKS * 4.0) + float2(53.0, 89.0));
    veil = smoothstep(0.30, 0.78, veil);
    float threshold = 1.0 - merged * 0.85;
    float coverage = smoothstep(threshold, threshold + 0.55, min(s.blob, 1.0));
    coverage *= lerp(0.10, 1.0, veil);
    if (coverage <= 0.0) {
        return 0.0;
    }

    // Thin band that undulates: the centre wobbles with a wide noise so the veil is never a flat
    // horizontal ribbon. Per-cell width keeps some veils wispier than others.
    float band = clamp(s.band, 0.08, 0.45);
    float wobble = cloudNoise(samplePos / (CLOUD_CELL_BLOCKS * 8.0) + float2(7.0, 3.0));
    float centre = 0.5 + (wobble - 0.5) * 0.6;
    float profile = smoothstep(centre - band, centre - band * 0.5, heightFrac)
            * (1.0 - smoothstep(centre + band * 0.5, centre + band, heightFrac));
    if (profile <= 0.0) {
        return 0.0;
    }

    // Fibrous filaments, the visible structure of the veil: 3D lobes stretched long along the wind
    // axis (x sampled at low frequency), short across z, and thin through the band (y at high
    // frequency, clamped to [0,1]). The x/z scales are 3*2^k so the mask wraps at the 24576 period:
    // /48 -> 512 cells (mask 511), /12 -> 2048 cells (mask 2047); the second octave /96 (mask 255)
    // and /24 (mask 1023) adds fine wisps. Sharpened (pow) so the veil is distinct filaments on
    // faint haze, not a uniform grey sheet.
    float fil1 = cloudNoise3D(float3(samplePos.x / 48.0, heightFrac * 6.0, samplePos.y / 12.0),
                              int2(511, 2047));
    float fil2 = cloudNoise3D(float3(samplePos.x / 96.0 + 31.0, heightFrac * 3.0 + 5.0,
                                     samplePos.y / 24.0 + 7.0), int2(255, 1023));
    float filaments = (1.0 - abs(fil1 * 2.0 - 1.0)) * 0.65
            + (1.0 - abs(fil2 * 2.0 - 1.0)) * 0.35;
    filaments = pow(max(filaments, 0.0), 1.4);

    float density = coverage * s.density * lerp(0.10, 1.0, filaments);
    return clamp(density, 0.0, 1.0) * profile;
}

/**
 * Cheap, soft shadow term for the cirrus veil, sampled at the veil's mid-plane along the light path.
 *
 * The full field is a 3x3 lattice look-up per query, which is what the cumulus shadow pays; a second
 * one on every shading point for a layer that only dims the sun by a few percent is not worth the
 * cost. The veil's own large-scale field is a single noise sample and reproduces the soft diffuse
 * character of real cirrostratus shading well enough at that scale.
 */
float cloudCirrusShadowAlpha(WorldPush push, float2 samplePos) {
    float retain = clamp(push.clouds.x, 0.0, 1.0);
    float fill = clamp(push.cloudColor.w, 0.0, 1.0);
    float merged = retain + (1.0 - retain) * fill;
    if (merged <= 0.02) {
        return 0.0;
    }
    // Same large-scale field as cloudCirrusDensity, so the shadow matches the visible veil.
    float veil = cloudNoise(samplePos / (CLOUD_CELL_BLOCKS * 4.0) + float2(53.0, 89.0));
    return smoothstep(0.30, 0.78, veil) * min(merged * 1.2, 1.0);
}

/**
 * Ray-march the cirrus slab (volumetric style only).
 *
 * Same front-to-back integration as the cumulus march but tailored for a thin veil: fewer steps, no
 * self-shadow light march (a few blocks of optical depth cannot shadow itself), low extinction, and
 * a stronger ambient term so the sheet reads as lit haze rather than cotton. The camera crossing
 * fade and the horizon fade match the cumulus slab's so the two layers end and dissolve together.
 */
CloudVolume cloudMarchCirrus(WorldPush push, float3 originRel, float3 dir, float maxDistance,
                             float3 skyBehind, bool highQuality, float cumulusSlabTop) {
    CloudVolume result;
    result.scatter = float3(0.0, 0.0, 0.0);
    result.transmittance = 1.0;

    float cirBottom = cumulusSlabTop + CLOUD_CIRRUS_GAP_BLOCKS;
    float cirTop = cirBottom + CLOUD_CIRRUS_SLAB_THICKNESS;
    float t0, t1;
    if (abs(dir.y) < 1.0e-4) {
        if (cirBottom > 0.0 || cirTop < 0.0) {
            return result; // parallel and outside the cirrus slab
        }
        t0 = 0.0;
        t1 = push.cloudAnchor.w;
    } else {
        float ta = cirBottom / dir.y;
        float tb = cirTop / dir.y;
        t0 = min(ta, tb);
        t1 = max(ta, tb);
    }
    t0 = max(t0, 0.0);
    t1 = min(t1, min(maxDistance, push.cloudAnchor.w));
    if (t1 <= t0) {
        return result;
    }

    // Camera crossing the veil dissolves it, like the cumulus crossing fade (see cloudMarch).
    float midRel = (cirBottom + cirTop) * 0.5;
    float crossFade = smoothstep(CLOUD_CIRRUS_SLAB_THICKNESS * 0.25,
                                 CLOUD_CIRRUS_SLAB_THICKNESS * 0.75, abs(midRel));
    if (crossFade <= 0.0) {
        return result;
    }
    float horizon = length(dir.xz) * t0;
    float fade = 1.0 - smoothstep(push.cloudAnchor.w * 0.55, push.cloudAnchor.w, horizon);
    if (fade <= 0.0) {
        return result;
    }

    int steps = highQuality ? CLOUD_CIRRUS_STEPS : CLOUD_CIRRUS_STEPS_CHEAP;
    steps = clamp(int((t1 - t0) / CLOUD_TARGET_STEP_BLOCKS), steps, highQuality ? 24 : 8);
    float stepLen = (t1 - t0) / float(steps);
    float sigma = CLOUD_EXTINCTION * CLOUD_CIRRUS_EXTINCTION_SCALE
            * (CLOUD_REFERENCE_THICKNESS / CLOUD_CIRRUS_SLAB_THICKNESS) * fade * crossFade;

    float3 sunRadiance = push.lightRadiance.xyz;
    float phase = cloudPhase(dot(dir, push.lightDir.xyz));
    for (int i = 0; i < steps; i++) {
        float3 p = originRel + dir * (t0 + stepLen * (float(i) + 0.5));
        float heightFrac = clamp((p.y - cirBottom) / CLOUD_CIRRUS_SLAB_THICKNESS, 0.0, 1.0);
        float density = cloudCirrusDensity(push, push.cloudAnchor.xy + p.xz, heightFrac);
        if (density <= 0.0) {
            continue;
        }
        float extinction = density * sigma * stepLen;
        float sampleTransmittance = exp(-extinction);
        // Sun glow through the veil plus a strong sky-ambient term: cirrostratus is lit haze, and its
        // ice crystals scatter strongly forward, so the veil brightens into a halo around the sun
        // (the phase is boosted relative to cumulus) while staying faint elsewhere.
        float3 inScatter = CLOUD_ALBEDO * (sunRadiance * phase * 4.5 * cloudPowder(density)
                                           + skyBehind * 0.7);
        result.scatter += result.transmittance * inScatter * (1.0 - sampleTransmittance);
        result.transmittance *= sampleTransmittance;
        if (result.transmittance < 0.01) {
            result.transmittance = 0.0;
            break; // fully saturated; further steps cannot contribute
        }
    }
    return result;
}

/** Optical depth from a point toward the light, for self-shadowing inside the slab. */
float cloudLightTransmittance(WorldPush push, float3 posRel, float3 lightDir,
                              float slabBottom, float slabTop, int lightSteps) {
    float thickness = max(slabTop - slabBottom, 0.1);
    // March a short distance toward the light; step so the march covers roughly the slab's own depth,
    // which is the scale self-shadowing operates on. Fewer steps cover the same distance with longer
    // strides, so the transmittance stays in the right range instead of the march falling short.
    float stepLen = thickness / (float(lightSteps) * max(abs(lightDir.y), 0.35));
    float optical = 0.0;
    for (int i = 0; i < lightSteps; i++) {
        float3 p = posRel + lightDir * (stepLen * (float(i) + 0.5));
        if (p.y < slabBottom || p.y > slabTop) {
            break; // left the slab: nothing further can shadow this sample
        }
        optical += cloudVolumeDensity(push, p, (p.y - slabBottom) / thickness) * stepLen;
    }
    return exp(-optical * CLOUD_EXTINCTION);
}

/** Result of a volumetric march: premultiplied scattered radiance and the surviving transmittance. */
public struct CloudVolume {
    public float3 scatter;
    public float transmittance;
};

/**
 * Ray-march the slab and return in-scattered radiance plus transmittance.
 *
 * Front-to-back emission/absorption integration: at each step the sample's in-scattering (sun radiance,
 * attenuated by the light march, shaped by the HG phase, plus a sky ambient term) is accumulated
 * weighted by how much light still reaches the eye, and the transmittance is decremented by
 * Beer-Lambert. The caller composites with `col * transmittance + scatter`, so the result is correct
 * over any background — including a terrain hit, which is what makes the volumetric style occlude and
 * be occluded correctly.
 */
public CloudVolume cloudMarch(WorldPush push, float3 originRel, float3 dir, float maxDistance,
                              float3 skyBehind, bool highQuality) {
    bool classic = cloudStyle(push) == CLOUD_STYLE_CLASSIC;
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
    float slabBottom = push.clouds.w - thickness * 0.5 - originRel.y;
    float slabTop = push.clouds.w + thickness * 0.5 - originRel.y;
    float opacity = clamp(push.clouds.y, 0.0, 1.0);

    // Cirrostratus veil, integrated FIRST and independently of the cumulus slab: the veil has its own
    // bounds, fades and step count, and it can lie AHEAD of the camera even when the cumulus slab is
    // entirely behind it (the camera flying in the clear air between the two layers). Every cumulus
    // early return below therefore hands the veil to the caller through cloudCompositeCirrus; an
    // unreachable layer yields an empty volume, so compositing an empty side is a no-op.
    bool cirrusActive = !classic && cirrusEnabled(push);
    CloudVolume cirrusVolume;
    cirrusVolume.scatter = float3(0.0, 0.0, 0.0);
    cirrusVolume.transmittance = 1.0;
    if (cirrusActive) {
        cirrusVolume = cloudMarchCirrus(push, originRel, dir, maxDistance, skyBehind, highQuality,
                                        slabTop);
    }
    // There is deliberately NO early return on crossFade itself: while the camera crosses the deck,
    // sigma below is scaled to zero so the deck contributes nothing, and the veil above (already
    // integrated) must keep rendering. When the veil is inactive this returns the same empty result
    // the old early return produced, so the classic path is untouched.
    if (crossFade <= 0.0) {
        return cloudCompositeCirrus(result, cirrusVolume, cirrusActive, dir.y, opacity);
    }

    // Slab entry/exit along the ray. A near-horizontal ray inside the slab would march forever, so it
    // is bounded by the view limit like every other ray.
    float t0, t1;
    if (abs(dir.y) < 1.0e-4) {
        if (slabBottom > 0.0 || slabTop < 0.0) {
            // Parallel and outside the deck. The veil (if any) is above the deck, so a horizontal ray
            // cannot meet it either; the composite is a no-op that still applies the opacity ceiling.
            return cloudCompositeCirrus(result, cirrusVolume, cirrusActive, dir.y, opacity);
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
        // The ray never crosses the cumulus slab (behind the camera, or cut off by terrain before the
        // deck). The veil may still be ahead of it — the composite decides; an empty veil is a no-op.
        return cloudCompositeCirrus(result, cirrusVolume, cirrusActive, dir.y, opacity);
    }

    // Distance fade, matched to the flat style's horizon fade so the two agree about where cloud ends.
    float horizon = length(dir.xz) * t0;
    float fade = 1.0 - smoothstep(push.cloudAnchor.w * 0.55, push.cloudAnchor.w, horizon);
    if (fade <= 0.0) {
        return cloudCompositeCirrus(result, cirrusVolume, cirrusActive, dir.y, opacity);
    }

    float3 sunRadiance = push.lightRadiance.xyz;
    float cosT = dot(dir, push.lightDir.xyz);
    float phase = cloudPhase(cosT);
    // Scale the step count to the distance actually being marched, so a thick deck is sampled as finely
    // as a thin one instead of just taking longer strides. Clamped both ways: never coarser than the
    // base count, never more expensive than the cap.
    int stepCap = highQuality ? CLOUD_MARCH_STEPS_MAX : CLOUD_MARCH_STEPS_CHEAP_MAX;
    marchSteps = clamp(int((t1 - t0) / CLOUD_TARGET_STEP_BLOCKS), marchSteps, stepCap);
    float stepLen = (t1 - t0) / float(marchSteps);
    // Classic clouds are opaque boxes, not haze: they need a much higher extinction so a box saturates
    // within its own thickness instead of reading as translucent fog. Vanilla's clouds you cannot see
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

    for (int i = 0; i < marchSteps; i++) {
        float3 p = originRel + dir * (t0 + stepLen * (float(i) + 0.5));
        float heightFrac = (p.y - slabBottom) / max(slabTop - slabBottom, 1.0e-3);
        float density = cloudVolumeDensity(push, p, clamp(heightFrac, 0.0, 1.0));
        if (density <= 0.0) {
            continue;
        }
        float extinction = density * sigma * stepLen;
        float sampleTransmittance = exp(-extinction);
        float lightT = cloudLightTransmittance(push, p, push.lightDir.xyz, slabBottom, slabTop,
                                               lightSteps);
        float3 inScatter;
        if (classic) {
            // Flat, vanilla-style face tone. Self-shadowing is deliberately damped (mixed only 40% in)
            // so cloud boxes keep the poster-flat look instead of developing soft volumetric gradients.
            float shade = lerp(1.0, lightT, 0.4);
            inScatter = push.cloudColor.xyz * CLOUD_INV_PI
                    * (sunRadiance * classicFace * shade * 3.0 + skyBehind * 1.4);
        } else {
            // Direct sun scattering + an ambient sky term so the shadowed interior is grey rather than
            // black. Powder brightens dense interiors (multiple-scattering approximation).
            float powder = lerp(1.0, cloudPowder(density), CLOUD_POWDER_STRENGTH);
            inScatter = CLOUD_ALBEDO
                    * (sunRadiance * lightT * phase * powder * 4.0 + skyBehind * 0.35);
        }
        // Energy-conserving accumulation: integrate in-scatter over the step's absorbed fraction.
        result.scatter += result.transmittance * inScatter * (1.0 - sampleTransmittance);
        result.transmittance *= sampleTransmittance;
        if (result.transmittance < 0.01) {
            result.transmittance = 0.0;
            break; // fully saturated; further steps cannot contribute
        }
    }

    // ---- Opacity as a genuine ceiling, applied ONCE to the finished (cumulus + cirrus) march.
    //
    // It used to scale the extinction, which is per unit length — so the total optical depth still grew
    // with the slab depth and with the path length through it. That is why a low opacity still went
    // fully solid at 100% thickness, and why even a thin deck turned opaque toward the horizon, where a
    // grazing ray traverses hundreds of blocks of slab. The slider had no ceiling at all.
    //
    // Capping the finished result instead makes it exactly a blend between "no cloud" and "this cloud":
    // at 20% the cloud can never be more than 20% opaque, at any thickness, at any view angle. Scatter
    // is premultiplied so it scales by the same factor, which keeps
    // `background * transmittance + scatter` energy-correct. The ceiling applies to the veil too, so a
    // low opacity dims the whole cloudscape, not just the deck.
    return cloudCompositeCirrus(result, cirrusVolume, cirrusActive, dir.y, opacity);
}

/**
 * Composite the cirrus veil with the cumulus march result and apply the opacity ceiling to the whole.
 *
 * The veil always sits ABOVE the cumulus slab, so an upward ray meets the deck first and the veil is
 * dimmed by the deck's surviving transmittance, while a downward ray meets the veil first (usually
 * empty — the veil is above the camera). Composing in that order keeps the nearer layer from ever
 * being dimmed by the farther one. The premultiplied result is then capped by the opacity slider
 * exactly as the cumulus-only march capped it.
 */
CloudVolume cloudCompositeCirrus(CloudVolume result, CloudVolume cirrusVolume, bool cirrusActive,
                                 float dirY, float opacity) {
    if (cirrusActive) {
        if (dirY >= 0.0) {
            result.scatter += result.transmittance * cirrusVolume.scatter;
            result.transmittance *= cirrusVolume.transmittance;
        } else {
            result.scatter = cirrusVolume.scatter + cirrusVolume.transmittance * result.scatter;
            result.transmittance = cirrusVolume.transmittance * result.transmittance;
        }
    }
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
 * This shape is deliberate: it is exactly how {@code medium.slang} reports the ambient fog, so callers
 * composite clouds with the identical two lines they already use for fog
 * ({@code L += throughput * scatter; throughput *= transmittance;}) and clouds inherit fog's correct
 * behaviour over reflections, refractions and indirect bounces for free.
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
