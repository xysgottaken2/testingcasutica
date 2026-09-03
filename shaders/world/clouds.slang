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
//   * CLOUD_STYLE_VOLUMETRIC — photoreal cumulus, and 100% PROCEDURAL. Nothing about its shape comes
//     from a texture: the whole field is integer hashes evaluated at run time (see the noise library
//     below), so there is no PNG to ship, no 3D texture to upload, no resolution ceiling, and no two
//     clouds in the sky are the same cloud. Photon bakes the same Perlin-Worley combination offline
//     into a 3D texture (sixthsurge/volume-noise-generator); this evaluates it analytically instead,
//     following Schneider's "Real-Time Volumetric Cloudscapes" (GPU Pro 7): a low-frequency
//     Perlin-Worley base shape, severely eroded by a high-frequency Worley fBm, marched with a
//     cone-tapered light march, Beer-Lambert extinction, a dual-lobe Henyey-Greenstein phase, the
//     beer-powder multiple-scattering term and a height-gradient ambient.
//     Its DEPTH is not a slider either: RtCloudGenesis resolves it from the weather and the diurnal
//     convective cycle into the cloudGenus lane, so the deck grows from flat cumulus humilis at night
//     into towering congestus in a storm. Cloud Height still sets the base; Cloud Thickness does not
//     touch this style at all.
//
// The two styles answer "how deep is the deck" from different places on purpose: classic from the
// Cloud Thickness slider, volumetric from the genesis model. The weather fill (cloudColor.w) closes
// either sky completely in a storm.
//
// DEPTH-CORRECT AGAINST THE WORLD. Every entry point that produces visible cloud takes the distance to
// the nearest scene hit and stops there, so terrain in front of a cloud occludes it. Getting this wrong
// is exactly the bug where the world appeared to punch through the deck from above (see cloudLayer).
//
// Only world_common is imported: world.rmiss must NOT pull in world_core (that module declares the
// raygen bindings), so every entry point here takes the WorldPush explicitly, exactly like
// world_common's own worldFeature/worldFlag accessors.

import world_common;

// ---- Pattern geometry and the periodicity contract.
//
// Every hash in this module wraps its lattice index to CLOUD_PERIOD_CELLS, which makes each noise
// octave EXACTLY periodic over CLOUD_PERIOD_CELLS * (its lattice size in blocks). That is load-bearing,
// not decoration: RtComposite pushes a sample anchor already reduced modulo
// CLOUD_FIELD_PERIOD_BLOCKS, both to fold in the wind scroll (which grows without bound with world
// time) and to keep the anchor a small float far from a world border's 30M-block coordinates. Wrapping
// an aperiodic field would teleport the whole sky the moment the anchor rolled over; wrapping a
// periodic one is seamless — but ONLY if the wrap distance is a whole number of EVERY octave's period
// at once, plus the classic deck's own 3072-block cell-map period and its 6144-block noise fallback.
//
// So the rule for the constants below is hard: every lattice size must be a POWER OF TWO that divides
// CLOUD_LATTICE_MAX_BLOCKS. Java's period is then
//
//     lcm(CLOUD_PERIOD_CELLS * CLOUD_LATTICE_MAX_BLOCKS, CLOUD_CELL_MAP_CELLS * CLOUD_CELL_BLOCKS)
//   = lcm(512 * 512, 256 * 12) = lcm(262144, 3072) = 786432 blocks
//
// Powers of two keep every one of those multiplies exact in binary floating point, so the identity
// holds bit-for-bit rather than approximately. 786432 blocks is 256 times the deck's own view limit,
// so the repeat is never visible in one frame — and it is 32 times the old 24576-block wrap, which is
// what lets the coarsest octave be a 512-block lattice instead of a 24-block one. That is the whole
// difference between "clouds the size of a house, tiled" and a sky with individual clouds in it.
// RtCloudShaderRegressionTest parses both sides of this contract and fails the build on a drift.
public static const float CLOUD_CELL_BLOCKS = 12.0; // vanilla's cloud cell size (classic noise fallback)
public static const int   CLOUD_PERIOD_CELLS = 512; // power of two, so the wrap below is a mask
public static const int   CLOUD_CELL_MASK = CLOUD_PERIOD_CELLS - 1;
// The coarsest lattice the volumetric field may use, in blocks. The binding constraint on the Java
// anchor wrap — see above. Any new octave must divide this.
public static const float CLOUD_LATTICE_MAX_BLOCKS = 512.0;

// Width of the coverage ramp for the CLASSIC noise fallback (the deck used when clouds.png is
// unavailable). Classic with the authored map quantises instead; the volumetric style uses its own,
// sharper ramp — see CLOUD_VOLUMETRIC_EDGE.
public static const float CLOUD_EDGE_SOFTNESS = 0.22;
public static const float3 CLOUD_ALBEDO = float3(0.94, 0.95, 0.98);
public static const float CLOUD_INV_PI = 0.31830988618;

// Below this the deck is treated as a flat sheet: the classic thickness slider at 0 must reproduce the
// old plane exactly rather than degenerate into a zero-length march. The volumetric deck never reaches
// it — its depth comes from the genesis model, whose shallowest genus is still tens of blocks.
public static const float CLOUD_FLAT_EPSILON = 0.25;

// Style ids; the active one comes from featureFlags (see cloudStyle).
public static const uint CLOUD_STYLE_CLASSIC = 0u;
public static const uint CLOUD_STYLE_VOLUMETRIC = 1u;

// ---- Volumetric field lattices (blocks). All powers of two dividing CLOUD_LATTICE_MAX_BLOCKS.
//
// The scales are the single biggest reason this deck reads as weather rather than as Minecraft. A
// cumulus humilis puff is ~100 blocks across and a whole convective mass is thousands; the old field
// put its largest feature at 24 blocks, which is a cloud the size of a house, and no amount of
// lighting can make that read as sky. Each octave below is one physical level of the cloud's anatomy:
public static const float CLOUD_AIRMASS_LATTICE = 512.0;   // is this part of the sky cloudy at all
public static const float CLOUD_COVERAGE_LATTICE = 256.0;  // individual masses, and the gaps between
public static const float CLOUD_VARIETY_LATTICE = 128.0;   // per-cloud size/height variation
public static const float CLOUD_WARP_LATTICE = 128.0;      // domain warp: straight edges -> curling lobes
public static const float CLOUD_SHAPE_LATTICE = 64.0;      // the cauliflower domes themselves
public static const float CLOUD_SHAPE_LATTICE_FINE = 32.0; // sub-lobes on each dome
public static const float CLOUD_EROSION_LATTICE = 32.0;    // Worley: cavities and aerated recuts
public static const float CLOUD_EROSION_LATTICE_FINE = 16.0; // Worley: the wispy edge detail
public static const float CLOUD_EROSION_LATTICE_CROWN = 64.0; // Worley 3D: big holes through the crown

// ---- Volumetric march budget.
//
// This is the whole cost of the volumetric style, and it multiplies by SPP and by path depth, so it is
// split into two tiers rather than being one flat number:
//   * FULL is used where the clouds are actually looked at — the camera ray and specular/mirror bounces
//     (reflections of the sky in water and glass). This is what the player sees, so it gets the light
//     march, the Worley erosion and the full step count.
//   * CHEAP is used for diffuse indirect bounces. Those contribute a broad, low-frequency sky-fill term
//     that gets averaged over the hemisphere and then denoised; resolving cloud detail there is
//     invisible in the result but would multiply the cost by the bounce count. It keeps the same
//     extinction and phase, so the ENERGY stays right — only the detail is coarser.
// Quality comes from the light march and the phase function rather than raw step count.
public static const int   CLOUD_MARCH_STEPS = 28;
public static const int   CLOUD_LIGHT_STEPS = 5;
public static const int   CLOUD_MARCH_STEPS_CHEAP = 6;
public static const int   CLOUD_LIGHT_STEPS_CHEAP = 2;
// Upper bounds used when the step count is scaled to the path length (see cloudMarch). A fixed step
// COUNT means a deeper slab silently gets coarser steps, which bands: cloud lobes are tens of blocks
// wide, so a 60-block step walks straight past them. These cap the cost of that scaling.
public static const int   CLOUD_MARCH_STEPS_MAX = 48;
public static const int   CLOUD_MARCH_STEPS_CHEAP_MAX = 12;
// Target distance between samples. The finest feature in the field is a 16-block Worley cell, so 8
// blocks resolves it with two samples across — and because the features are now ~4x larger than the old
// field's, this is a strictly finer march relative to the shape than the 6-block step it replaces.
public static const float CLOUD_TARGET_STEP_BLOCKS = 8.0;
// Longest path a single ray may integrate INSIDE the slab, in blocks. This replaces a cap measured in
// slab crossings: the genesis model makes the slab up to 207 blocks deep, so a fixed number of
// crossings would let a grazing horizon ray march 700+ blocks and turn the deck's cost into a function
// of the weather. An absolute cap bounds the worst case identically for every genus, and 640 blocks is
// well past the distance at which the horizon fade has already taken the cloud down to nothing.
public static const float CLOUD_MAX_MARCH_BLOCKS = 640.0;
public static const float CLOUD_EXTINCTION = 0.115; // per block, at density 1
// Optical depth is normalised against this thickness, so making the deck taller adds VOLUME without
// making it more opaque. Without it, tau = density * sigma * pathLength grows with the slab depth and
// a storm's deep congestus deck would go black on its own underside. With it, a 34-block humilis and a
// 207-block congestus reach the same optical depth straight down — the deep one is a bigger cloud, not
// a darker one, and the extra self-shadowing comes from the light march instead.
public static const float CLOUD_REFERENCE_THICKNESS = 40.0;
// How far the self-shadowing light march reaches, as a multiple of the slab's own depth. Self-shadowing
// operates on the scale of the cloud, so scaling with the depth keeps the shading self-similar across
// genera: a humilis gets a tight, crisp terminator and a congestus gets the long internal gradients a
// 200-block tower actually has.
public static const float CLOUD_LIGHT_DISTANCE_SCALE = 1.15;
// Multiple-scattering octave (Schneider's): the LIGHT march sees a more transparent medium than the
// eye march does, which is the cheap stand-in for the second and later bounces that a single-scattering
// integral cannot represent. It is what stops a dense crown from going black the moment it is thick
// enough to shadow itself, and it costs nothing but one multiply.
public static const float CLOUD_LIGHT_EXTINCTION_SCALE = 0.30;
// Powder / dark-edge term: how strongly local density darkens a sample, and the density scale it is
// evaluated at. See cloudPowder for why this reads DENSITY and not the step's optical depth.
public static const float CLOUD_POWDER_STRENGTH = 0.70;
public static const float CLOUD_POWDER_DENSITY = 4.0;
// Half-width of the region around the deck's mid-plane in which the slab is optically EXCLUDED, so a
// camera sitting on the plane cannot accumulate a bright horizontal band from near-horizontal rays.
// A fixed number of blocks, deliberately NOT a fraction of the slab depth: the genesis model makes the
// slab up to 207 blocks deep, and scaling the zone with it would punch a 100-block hole through the
// middle of every cloud the player flies through.
public static const float CLOUD_CROSS_EXCLUSION_BLOCKS = 20.0;

// ---- Volumetric shape and erosion.
//
// The silhouette these constants produce is the one the whole rework exists for: a HARD, flat base at
// the condensation level, a body that stays dense, and a crown that breaks into rounded domes with
// cavities torn through it. "Bread dough" — the smooth, featureless lump a plain fBm gives — comes from
// eroding uniformly and from letting the base soften; both are explicitly avoided here.
public static const float CLOUD_VOLUMETRIC_EDGE = 0.16;   // coverage ramp width: sharp blue-sky gaps
public static const float CLOUD_COVERAGE_CONTRAST = 0.55; // push airmass mid-tones to the extremes
public static const float CLOUD_BASE_FADE_BLOCKS = 3.0;   // condensation level: ramp 0->1 over 3 blocks
public static const float CLOUD_BASE_RELIEF = 0.045;      // base undulation, fraction of slab depth
public static const float CLOUD_CROWN_FLOOR = 0.34;       // lowest a crown may start rounding off
public static const float CLOUD_WARP_AMPLITUDE = 18.0;    // domain warp, blocks, at the crown
public static const float CLOUD_CORE_DENSITY = 1.18;      // > 1 so an uneroded core is optically thick
public static const float CLOUD_EROSION_GAIN = 0.95;      // scales the Worley fBm's bite
public static const float CLOUD_EROSION_EDGE = 0.62;      // erosion weight on the cloud's thin edges
public static const float CLOUD_EROSION_CROWN = 0.58;     // ... on the crown, where domes break up
public static const float CLOUD_EROSION_BASE = 0.28;      // ... on the base: light, so it stays flat
public static const float CLOUD_INTERIOR_STRUCTURE = 0.45; // how much the shape field carves the core
public static const float CLOUD_AMBIENT_TOP = 0.62;       // sky fill at the crown (sees the whole sky)
public static const float CLOUD_AMBIENT_BASE = 0.18;      // ... at the base (occluded by its own cloud)
public static const float CLOUD_SUN_GAIN = 4.0;           // direct-scatter scale, matches the sky's HDR
public static const float CLOUD_AERIAL_PERSPECTIVE = 0.55; // distant cloud blends toward the sky behind

public static const float CLOUD_HG_G = 0.72;        // forward-scattering anisotropy of cloud droplets
public static const float CLOUD_HG_BACK = -0.28;    // weak backward lobe (see cloudPhase)
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
// a world position that can be hundreds of thousands of blocks from the origin, where a float hash
// starts losing mantissa bits and the pattern degenerates into stripes. The mask is what makes the
// field periodic.
/** Raw 32-bit mix of a 2D lattice cell, already wrapped to the field's period. */
uint cloudHashBits(int2 cell) {
    uint2 c = uint2(uint(cell.x & CLOUD_CELL_MASK), uint(cell.y & CLOUD_CELL_MASK));
    uint h = c.x * 374761393u + c.y * 668265263u;
    h = (h ^ (h >> 13u)) * 1274126177u;
    return h ^ (h >> 16u);
}

/** [0,1) float from a 2D cell. The classic deck's per-cell decisions and its noise fallback. */
float cloudHash(int2 cell) {
    return float(cloudHashBits(cell) & 0x00ffffffu) * (1.0 / 16777216.0);
}

// Value noise on the cell lattice, smoothstep-interpolated. floor/frac agree for negative coordinates
// (floor(-0.3) = -1, frac(-0.3) = 0.7), so the field is continuous across the origin.
//
// Kept for two consumers that need EXACTLY the old field and nothing better: the classic deck's
// noise-quantised fallback (when clouds.png is unavailable) and the per-cell stable hashes cloudCoverage
// uses to thin and fill authored cells. The volumetric style no longer reads it — value noise is the
// reason it looked like bread dough: interpolating scalar values gives flat, blobby plateaus with the
// lattice visible in the second derivative, whereas gradient noise below gives rounded, directional
// structure with no plateau at all.
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

// ---- Procedural noise library (the volumetric deck's entire shape source).
//
// NO TEXTURES, NO PNGs, NO PRECOMPUTED ANYTHING. Every value below is an integer hash of a lattice cell
// computed at the moment it is sampled. That is a deliberate choice with three consequences worth
// stating, because they are the reason this module is longer than a texture fetch:
//   * every cloud is genuinely unique. A 3D texture tiles; this field's period is 786432 blocks, 256
//     times the view limit, so no two clouds a player can compare are the same cloud;
//   * there is no resolution limit and no upload. Photon bakes exactly this combination — Perlin-Worley
//     base, Worley fBm detail — into a 128^3 texture offline (sixthsurge/volume-noise-generator) and
//     trilinearly samples it. Evaluating it analytically costs ALU instead of bandwidth and memory,
//     and buys unlimited detail frequency;
//   * the periodicity contract above is a real constraint on the constants, which is why every lattice
//     size in this module is a power of two.
//
// The hash is integer-mixed rather than the sky's float hash13: sample coordinates here reach 786432
// blocks, where a float hash has lost enough mantissa bits to degenerate into stripes.

/** Raw 32-bit mix of a 3D lattice cell, wrapped on all three axes. */
uint cloudHashBits(int3 cell) {
    uint3 c = uint3(uint(cell.x & CLOUD_CELL_MASK), uint(cell.y & CLOUD_CELL_MASK),
                    uint(cell.z & CLOUD_CELL_MASK));
    uint h = c.x * 374761393u + c.y * 668265263u + c.z * 2246822519u;
    h = (h ^ (h >> 13u)) * 1274126177u;
    h = (h ^ (h >> 15u)) * 3266489917u;
    return h ^ (h >> 16u);
}

/** Two independent [0,1) floats from a 2D cell, for Worley feature-point jitter. */
float2 cloudHashFloat2(int2 cell) {
    uint h = cloudHashBits(cell);
    return float2(float(h & 0xffffu), float((h >> 16u) & 0xffffu)) * (1.0 / 65536.0);
}

/** Three independent [0,1) floats from a 3D cell, for Worley feature-point jitter. */
float3 cloudHashFloat3(int3 cell) {
    uint h = cloudHashBits(cell);
    uint h2 = h * 2654435761u;
    h2 = h2 ^ (h2 >> 15u);
    return float3(float(h & 0xffffu), float((h >> 16u) & 0xffffu), float(h2 & 0xffffu))
            * (1.0 / 65536.0);
}

/**
 * A Perlin gradient from a hash. Unpacked from three 10-bit lanes and normalised, with the degenerate
 * zero vector replaced: isotropic enough for cloud shape, and it keeps the whole gradient in registers
 * instead of indexing a constant table with a per-lane divergent index.
 */
float2 cloudGradient(uint h) {
    float2 g = float2(float(h & 1023u), float((h >> 10u) & 1023u)) * (2.0 / 1023.0) - 1.0;
    float len2 = dot(g, g);
    return len2 > 1.0e-8 ? g * rsqrt(len2) : float2(1.0, 0.0);
}

float3 cloudGradient(uint h, uint seed) {
    uint m = (h * 2246822519u) ^ (seed * 3266489917u);
    m = m ^ (m >> 14u);
    float3 g = float3(float(m & 1023u), float((m >> 10u) & 1023u), float((m >> 20u) & 1023u))
            * (2.0 / 1023.0) - 1.0;
    float len2 = dot(g, g);
    return len2 > 1.0e-8 ? g * rsqrt(len2) : float3(1.0, 0.0, 0.0);
}

/** Perlin's improved quintic fade: zero first AND second derivative at the lattice, so no grid shows. */
float cloudFade(float t) {
    return t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
}

float2 cloudFade(float2 t) {
    return t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
}

float3 cloudFade(float3 t) {
    return t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
}

/**
 * 2D gradient (Perlin) noise in roughly [-1,1]. Four taps.
 */
float cloudPerlin2(float2 p) {
    int2 i = int2(floor(p));
    float2 f = p - float2(i);
    float2 u = cloudFade(f);
    float n00 = dot(cloudGradient(cloudHashBits(i)), f);
    float n10 = dot(cloudGradient(cloudHashBits(i + int2(1, 0))), f - float2(1.0, 0.0));
    float n01 = dot(cloudGradient(cloudHashBits(i + int2(0, 1))), f - float2(0.0, 1.0));
    float n11 = dot(cloudGradient(cloudHashBits(i + int2(1, 1))), f - float2(1.0, 1.0));
    return lerp(lerp(n00, n10, u.x), lerp(n01, n11, u.x), u.y) * 1.45;
}

/**
 * 3D gradient (Perlin) noise in roughly [-1,1]. Eight taps — the workhorse of the cloud's body, and the
 * reason a dome looks like a dome rather than like a blob: gradient noise has a directional structure
 * value noise cannot produce, so neighbouring lobes lean and roll against each other.
 */
float cloudPerlin3(float3 p) {
    int3 i = int3(floor(p));
    float3 f = p - float3(i);
    float3 u = cloudFade(f);
    float n000 = dot(cloudGradient(cloudHashBits(i), 1u), f);
    float n100 = dot(cloudGradient(cloudHashBits(i + int3(1, 0, 0)), 2u), f - float3(1.0, 0.0, 0.0));
    float n010 = dot(cloudGradient(cloudHashBits(i + int3(0, 1, 0)), 3u), f - float3(0.0, 1.0, 0.0));
    float n110 = dot(cloudGradient(cloudHashBits(i + int3(1, 1, 0)), 4u), f - float3(1.0, 1.0, 0.0));
    float n001 = dot(cloudGradient(cloudHashBits(i + int3(0, 0, 1)), 5u), f - float3(0.0, 0.0, 1.0));
    float n101 = dot(cloudGradient(cloudHashBits(i + int3(1, 0, 1)), 6u), f - float3(1.0, 0.0, 1.0));
    float n011 = dot(cloudGradient(cloudHashBits(i + int3(0, 1, 1)), 7u), f - float3(0.0, 1.0, 1.0));
    float n111 = dot(cloudGradient(cloudHashBits(i + int3(1, 1, 1)), 8u), f - float3(1.0, 1.0, 1.0));
    return lerp(lerp(lerp(n000, n100, u.x), lerp(n010, n110, u.x), u.y),
                lerp(lerp(n001, n101, u.x), lerp(n011, n111, u.x), u.y), u.z) * 1.75;
}

/**
 * 2D Worley (cellular) noise: distance to the nearest jittered feature point, in [0,1]. Nine taps.
 *
 * This is the ingredient the old field had no equivalent of, and it is what a "cauliflower" silhouette
 * actually is. `1 - F1` is a rounded lobe centred on each feature point and zero along the cell
 * boundaries, so summing two octaves of it gives domes sitting on domes with sharp, scalloped valleys
 * between — the structure value noise cannot make because its extrema are interpolated plateaus rather
 * than points.
 */
float cloudWorley2(float2 p) {
    int2 i = int2(floor(p));
    float2 f = p - float2(i);
    float best = 1.0e9;
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            float2 d = float2(float(dx), float(dy)) + cloudHashFloat2(i + int2(dx, dy)) - f;
            best = min(best, dot(d, d));
        }
    }
    return clamp(sqrt(best), 0.0, 1.0);
}

/**
 * 3D Worley (cellular) noise: distance to the nearest jittered feature point, in [0,1]. Twenty-seven
 * taps, and therefore used exactly once per sample and only where it earns its keep — the crown, where
 * the erosion has to punch real holes through the cloud rather than merely roughen a silhouette.
 */
float cloudWorley3(float3 p) {
    int3 i = int3(floor(p));
    float3 f = p - float3(i);
    float best = 1.0e9;
    for (int dz = -1; dz <= 1; dz++) {
        for (int dy = -1; dy <= 1; dy++) {
            for (int dx = -1; dx <= 1; dx++) {
                float3 d = float3(float(dx), float(dy), float(dz))
                        + cloudHashFloat3(i + int3(dx, dy, dz)) - f;
                best = min(best, dot(d, d));
            }
        }
    }
    return clamp(sqrt(best), 0.0, 1.0);
}

/** An uncorrelated [0,1) float from three floats, for per-ray stochastic sample placement. */
float cloudRand(float3 v) {
    uint h = uint(int(v.x)) * 374761393u + uint(int(v.y)) * 668265263u + uint(int(v.z)) * 2246822519u;
    h = (h ^ (h >> 13u)) * 1274126177u;
    return float((h ^ (h >> 16u)) & 0x00ffffffu) * (1.0 / 16777216.0);
}

/**
 * The classic deck's noise fallback field, in [0,1]. Three octaves at INTEGER scales with whole-cell
 * offsets, so every octave shares the 6144-block base period and the sum stays exactly periodic.
 *
 * This used to be the shared truth both styles were built on; it is now ONLY the deck drawn when
 * clouds.png is unavailable. The volumetric style moved to the gradient/cellular field below, because a
 * 12-block lattice cannot describe a cloud — its largest feature is 48 blocks across, which is a puff
 * the size of a house, tiled.
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
 * The volumetric deck's 2D coverage mask: WHERE the sky is cloud, before any 3D shape is applied.
 *
 * Two octaves of gradient noise on the two coarsest lattices, and nothing else — this is the cheap
 * predicate every march step evaluates first, so it is also the empty-space rejection that keeps the
 * whole style affordable. Getting it to look like WEATHER rather than like a grey wash comes from two
 * deliberate choices:
 *
 *   * CONTRAST. A raw fBm spends most of its area near its own mean, so thresholding it gives a sky
 *     that is thin haze everywhere with nothing decisively empty. Pushing the mid-tones toward the
 *     extremes (CLOUD_COVERAGE_CONTRAST) makes a mass a mass and a gap a gap — which is where the sharp
 *     blue-sky windows between formations come from. The curve is symmetric about 0.5, so the mean is
 *     preserved and the coverage slider still means "fraction of sky covered";
 *   * SCALE SEPARATION. The 512-block airmass octave decides which region of the sky is convecting at
 *     all and dominates (0.72); the 256-block octave only carves the individual masses out of it
 *     (0.28). Two octaves at similar scales would give a self-similar fractal sky, which is exactly the
 *     "noise cloud" look — real skies have a few big systems in them with structure inside each.
 *
 * Full overcast short-circuits to exactly 1: smoothstep never reaches 1 below threshold + EDGE, so a
 * plain merge would leave a residue of pinholes at "100%" coverage, and a storm sky has no pinholes.
 */
public float cloudCoverageVolumetric(WorldPush push, float2 deckXZ) {
    float retain = clamp(push.clouds.x, 0.0, 1.0);
    float fill = clamp(push.cloudColor.w, 0.0, 1.0);
    float coverage = retain + (1.0 - retain) * fill;
    if (coverage >= 1.0) {
        return 1.0;
    }
    float airmass = cloudPerlin2(deckXZ / CLOUD_AIRMASS_LATTICE) * 0.5 + 0.5;
    float masses = cloudPerlin2(deckXZ / CLOUD_COVERAGE_LATTICE + float2(31.0, 17.0)) * 0.5 + 0.5;
    float field = airmass * 0.72 + masses * 0.28;
    // Symmetric contrast about the mean: masses commit, gaps clear.
    field = lerp(field, smoothstep(0.0, 1.0, field), CLOUD_COVERAGE_CONTRAST);
    float threshold = 1.0 - coverage;
    // Narrower ramp than the classic fallback, and narrowing further as the sky closes: scattered
    // cumulus needs crisp edges to read as individual clouds, while an overcast ceiling wants a soft one
    // so it does not develop a visible threshold contour overhead.
    float ramp = CLOUD_VOLUMETRIC_EDGE * (0.6 + 0.4 * (1.0 - coverage));
    return smoothstep(threshold, threshold + ramp, field);
}

/**
 * Per-cloud VARIETY, in [0,1]: how strongly developed this particular cloud is, independently of its
 * neighbours. One low-frequency gradient-noise reading per position, used to scale the cloud's crown
 * height and its erosion.
 *
 * Without it every cloud in a deck of the same genus is the same cloud at a different offset: same
 * height, same flatness, same amount of cauliflower. Real convective skies are a population — a few
 * towers, many flat humilis, everything in between, all in the same airmass. This is what makes the
 * population, and it costs four hash taps.
 */
float cloudVariety(float2 deckXZ) {
    return cloudPerlin2(deckXZ / CLOUD_VARIETY_LATTICE + float2(97.0, 53.0)) * 0.5 + 0.5;
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
 * VOLUMETRIC delegates to cloudCoverageVolumetric: a gradient-noise airmass field on a 512-block
 * lattice, not this deck's 12-block one. Same weather lanes, same full-overcast short-circuit, entirely
 * different scale — and it is the function the cloud-shadow query samples too, so a shadow always sits
 * under the cloud that casts it.
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
    //
    // The zone is clamped to a fixed number of blocks: the genesis model can hand the volumetric deck a
    // 207-block slab, and a zone proportional to that would dissolve the deck over a 200-block band
    // around its mid-plane — a hole the size of the cloud, exactly where the player is flying through
    // it. See CLOUD_CROSS_EXCLUSION_BLOCKS.
    float halfThickness = min(max(push.cloudAnchor.z, 0.5) * 0.5, CLOUD_CROSS_EXCLUSION_BLOCKS);
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
// Everything below is the photoreal deck, and none of it reads a texture. The functions are ordered the
// way a sample is evaluated: the scattering terms first, then the density field they apply to, then the
// light march that shadows it, then the march that integrates it.

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
 * Beer-Lambert transmittance along the light path.
 *
 * The whole of the self-shadowing model, and deliberately not dressed up: for a medium with extinction
 * sigma and density rho, the fraction of the sun's radiance surviving an optical depth
 * `tau = integral(sigma * rho ds)` is exactly `exp(-tau)`. Two properties of that limit are load-bearing
 * and are the reason nothing is multiplied into it here:
 *
 *   * tau -> 0 gives 1. A sample at the sunlit crown of a cloud, with clear sky between it and the sun,
 *     MUST be the brightest thing in the deck. Every "powder"-style bell curve that is popular in cloud
 *     literature (including `2 * exp(-tau) * (1 - exp(-2 tau))`) tends to ZERO at tau = 0, which paints
 *     a dark band across the top of every cloud the moment the light march leaves the slab on its first
 *     sample — and with a 207-block congestus deck that band is 20 blocks tall and impossible to miss;
 *   * tau -> large gives 0, and the rate is set by the medium, not by the march. Which is why the light
 *     march's own extinction is scaled by CLOUD_LIGHT_EXTINCTION_SCALE: that reduced-extinction octave is
 *     the cheap stand-in for the light arriving after one or more forward bounces, and it is what keeps a
 *     dense core from going black the instant it is thick enough to shadow itself.
 */
float cloudBeerLambert(float tau) {
    return exp(-max(tau, 0.0));
}

/**
 * Powder / dark-edge term, from local DENSITY rather than from the step's optical depth.
 *
 * Multiple scattering makes the dense INTERIOR of a cloud brighter than its thin edges relative to what
 * single scattering alone predicts — the opposite of what a pure Beer-Lambert integral gives, and its
 * absence is why cheap volumetric clouds look like flat grey cotton. This is the standard
 * Frostbite/Horizon approximation of that: a saturating curve on density, so a wisp at density 0.1
 * keeps only a third of its scatter while a core at 0.9 keeps nearly all of it.
 *
 * Density and NOT `density * sigma * stepLen`, which is the tempting alternative and is wrong: stepLen
 * is a discretisation parameter that the march chooses from the path length, so shading by it would make
 * a cloud's brightness depend on how far away it is and how many steps the ray happened to get. Two rays
 * through the same wisp must shade the same however the march was budgeted.
 */
float cloudPowder(float density) {
    return 1.0 - exp(-density * CLOUD_POWDER_DENSITY);
}

/**
 * 3D density inside the slab, per style.
 *
 * CLASSIC is a box: the density is the quantised cell coverage, constant through the whole thickness
 * with only a hair of taper at the very top and bottom faces. That is deliberately NOT billowy — it is
 * what makes the marched result read as vanilla's solid cuboid clouds rather than a soft blob, and it
 * is why the classic style still looks like Minecraft once it has real height.
 *
 * VOLUMETRIC is cumulus, built as four separable decisions rather than one tuned expression. That
 * separation is the point of the rework: the previous version was a single formula in which coverage,
 * profile, bulge and erosion all multiplied into each other, so no constant could be changed without
 * moving three others. Here each stage owns one property of the cloud:
 *
 *   1. WHERE  — a 2D coverage mask on a 512-block lattice (cloudCoverageVolumetric). Also the cheap
 *      empty-space predicate: most of a scattered sky is air, and rejecting it with four hash taps
 *      instead of a hundred is what makes the rest affordable;
 *   2. HOW TALL — a vertical profile with a HARD flat base at the condensation level and a crown whose
 *      height is set by how developed that particular cloud is (coverage x variety x genus), perturbed
 *      by the shape field so the top is a line of domes rather than a plane;
 *   3. WHAT SHAPE — a domain-warped 3D gradient-noise fBm. The warp is what turns a lattice-aligned
 *      blob into a curling, rounded lobe, and it is scaled to zero at the base so the flat floor stays
 *      flat;
 *   4. WHAT IS ERODED — a Worley fBm that subtracts density, weighted so it bites hardest at the cloud's
 *      thin edges and its crown and barely at all at the base. This is the stage that removes the
 *      "massa de pao" look: cellular noise has point extrema, so subtracting it punches round holes and
 *      scalloped valleys through the silhouette instead of merely roughening it.
 *
 * `detail` selects the tier. The light march passes false and gets stages 1-3 with a single shape
 * octave and no erosion at all: self-shadowing is a low-frequency signal, so resolving billows on it is
 * invisible in the result and would multiply the cost by the light-step count. The SILHOUETTE stays
 * identical between the two tiers — same coverage, same relief, same profile — so a cloud never shadows
 * a shape other than its own.
 */
float cloudVolumeDensity(WorldPush push, float3 posRel, float heightFrac, float slabDepth, bool detail) {
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

    // ---- Volumetric cumulus. Fully procedural; see the four stages above.
    float depth = max(slabDepth, 1.0);
    float heightAboveBase = hf * depth;

    // (1) WHERE. Four hash taps, and the answer most of a scattered sky gives is "nowhere".
    float coverage = cloudCoverageVolumetric(push, samplePos);
    if (coverage <= 0.0) {
        return 0.0;
    }

    float genus = clamp(push.cloudGenus.w, 0.0, 1.0);
    float turbulence = clamp(push.cloudGenus.z, 0.0, 1.0);

    // (2) HOW TALL. The condensation level is not a plane: warm air rising off uneven terrain lifts the
    // base by a few blocks here and drops it there, which is why real cumulus bases look flat but not
    // machined. A low-frequency 2D reading, scaled by the slab depth so a deep deck gets proportionally
    // more relief, and small enough (4.5%) that the base still reads as decisively FLAT.
    float relief = cloudPerlin2(samplePos / CLOUD_COVERAGE_LATTICE + float2(71.0, 23.0))
            * CLOUD_BASE_RELIEF * depth;
    float aboveBase = heightAboveBase - relief;
    float h = clamp(aboveBase / depth, 0.0, 1.0);
    // The base ramp is in BLOCKS, not as a fraction of the slab: a 3-block condensation edge is sharp at
    // 34 blocks of deck and equally sharp at 207, whereas a fractional ramp would turn the deep genus's
    // base into a soft grey gradient — the single most "Minecraft cloud" thing a volumetric deck can do.
    float bottom = smoothstep(0.0, CLOUD_BASE_FADE_BLOCKS, aboveBase);

    // (3) WHAT SHAPE. Domain warp first, because the shape octaves are read at the WARPED position: that
    // is what bends the lattice into curling lobes. Amplitude ramps from zero at the base, so the floor
    // stays a floor and only the body and crown curl.
    float2 warpUv = samplePos / CLOUD_WARP_LATTICE;
    float warpAmp = CLOUD_WARP_AMPLITUDE * smoothstep(0.0, 0.30, h);
    float3 warp = float3(cloudPerlin2(warpUv),
                         cloudPerlin2(warpUv + float2(41.0, 17.0)),
                         cloudPerlin2(warpUv + float2(83.0, 61.0))) * warpAmp;
    float3 warped = float3(samplePos + warp.xz, heightAboveBase + warp.y);

    float shape;
    if (detail) {
        shape = (cloudPerlin3(warped / CLOUD_SHAPE_LATTICE) * 0.5 + 0.5) * 0.62
              + (cloudPerlin3(warped / CLOUD_SHAPE_LATTICE_FINE + float3(19.0, 7.0, 11.0)) * 0.5 + 0.5) * 0.38;
    } else {
        shape = cloudPerlin3(warped / CLOUD_SHAPE_LATTICE) * 0.5 + 0.5;
    }

    // Per-cloud development: this cloud's own crown height, independent of its neighbours. Without it
    // every cloud of a genus is the same cloud at a different offset, and the sky reads as a tiled
    // heightmap instead of a population.
    float variety = 0.5;
    if (detail) {
        variety = cloudVariety(samplePos);
    }
    float development = clamp(coverage * (0.45 + 0.85 * variety), 0.0, 1.0);
    float towerTop = lerp(CLOUD_CROWN_FLOOR, 1.0, development);
    // A storm's genus lifts the whole population's crowns, and only the DENSE part of each cloud: thin
    // edges stay low even in a congestus airmass, which is what gives a storm deck its torn skyline of
    // towers rising out of a ragged base rather than one uniformly tall slab.
    towerTop = lerp(towerTop, 1.0, genus * 0.35 * coverage);
    // Domes. The crown is perturbed by the shape field itself, so the top of the cloud is a line of
    // rounded summits at slightly different heights — the cauliflower silhouette — rather than a plane
    // with noise subtracted from it.
    towerTop *= 1.0 + (shape - 0.5) * 0.36;
    float top = 1.0 - smoothstep(towerTop * 0.66, towerTop, h);
    float profile = clamp(bottom * top, 0.0, 1.0);

    float mask = coverage * profile;
    if (mask <= 0.0) {
        return 0.0;
    }

    // (4) WHAT IS ERODED.
    float crown = smoothstep(0.50, 1.0, h);
    float frayedBase = smoothstep(0.16, 0.0, h);
    float erosionWeight = (1.0 - mask) * CLOUD_EROSION_EDGE
            + crown * CLOUD_EROSION_CROWN
            + frayedBase * CLOUD_EROSION_BASE;
    float density;
    if (detail && erosionWeight > 0.0) {
        // Shearing the cellular lattice with height makes one 2D Worley evaluation serve as a cheap
        // stand-in for a 3D one across the body: the pattern slides as the sample rises, so a lobe at
        // the base does not continue upward as an identical lobe, and the erosion acquires vertical
        // structure without paying 27 taps everywhere. The true 3D search is spent only on the crown,
        // where the erosion has to punch holes THROUGH the cloud rather than roughen a silhouette.
        float2 shear = warped.xz + warped.y * float2(0.40, -0.25);
        float w1 = 1.0 - cloudWorley2(shear / CLOUD_EROSION_LATTICE);
        float w2 = 1.0 - cloudWorley2(shear / CLOUD_EROSION_LATTICE_FINE + float2(23.0, 9.0));
        float billow = w1 * 0.62 + w2 * 0.38;
        billow = lerp(billow, billow * 0.5 + (1.0 - cloudWorley3(
                warped / CLOUD_EROSION_LATTICE_CROWN + float3(5.0, 3.0, 7.0))) * 0.5, crown);
        float erosion = billow * erosionWeight * lerp(0.65, 1.25, turbulence) * CLOUD_EROSION_GAIN;
        // CORE_DENSITY is above 1 on purpose: an uneroded core must saturate, because a field that peaks
        // at 0.5 can never look like anything but haze no matter how deep the slab is.
        density = clamp(mask * CLOUD_CORE_DENSITY - erosion, 0.0, 1.0);
        // Carve the interior too, lightly: multiple scattering means a real cloud's inside is not a
        // uniform block of density, and a faint shape imprint is what stops a cross-section (seen when
        // flying through) from reading as solid plaster.
        density *= lerp(1.0, 0.70 + 0.60 * shape, CLOUD_INTERIOR_STRUCTURE);
    } else {
        density = clamp(mask * CLOUD_CORE_DENSITY, 0.0, 1.0);
        density *= lerp(1.0, 0.70 + 0.60 * shape, CLOUD_INTERIOR_STRUCTURE * 0.5);
    }
    return clamp(density, 0.0, 1.0);
}

/**
 * Optical depth from a sample toward the light — the Beer-Lambert self-shadowing integral, returned RAW
 * (integral of density over distance, no extinction folded in) so each caller applies its own law: the
 * volumetric deck takes it through the multiple-scattering octave and the powder term, while the classic
 * boxes take a plain exponential and damp it, because they are opaque and must not grow a translucent
 * rim or any internal gradient at all.
 *
 * Cone-tapered sampling: the distances grow quadratically rather than uniformly, so the samples are
 * dense where the density gradient is steepest (right next to the sample, which is what decides whether
 * this point is in shadow at all) and sparse out toward the light, where the shadow is already decided
 * and only its softness is at stake. Five samples spaced this way read like a dozen spaced evenly, which
 * is the entire reason a per-step light march is affordable here.
 *
 * The distance scales with the slab's own depth (CLOUD_LIGHT_DISTANCE_SCALE): self-shadowing operates on
 * the scale of the cloud, so a 34-block humilis gets a tight crisp terminator and a 207-block congestus
 * gets the long internal gradients a tower that size actually has, from the same sample count.
 *
 * Samples that leave the slab stop the march — nothing outside the deck can shadow a point inside it —
 * which also makes a sun low on the horizon march the full distance sideways and a high sun terminate
 * after two or three samples. The cost follows the geometry instead of being paid uniformly.
 */
float cloudLightOpticalDepth(WorldPush push, float3 posRel, float3 lightDir,
                             float slabBottom, float slabTop, float lightDistance, int lightSteps) {
    float depth = max(slabTop - slabBottom, 0.1);
    float optical = 0.0;
    float previous = 0.0;
    for (int i = 0; i < lightSteps; i++) {
        float f = float(i + 1) / float(lightSteps);
        float d = lightDistance * (0.35 * f + 0.65 * f * f);
        float segment = d - previous;
        previous = d;
        float3 p = posRel + lightDir * d;
        if (p.y < slabBottom || p.y > slabTop) {
            break; // left the deck: nothing further along this path can shadow the sample
        }
        optical += cloudVolumeDensity(push, p, (p.y - slabBottom) / depth, depth, false) * segment;
    }
    return optical;
}

/** Result of a volumetric march: premultiplied scattered radiance and the surviving transmittance. */
public struct CloudVolume {
    public float3 scatter;
    public float transmittance;
};

/**
 * Ray-march the slab and return in-scattered radiance plus transmittance.
 *
 * Volume ray casting in the sense the term is usually meant for clouds: the ray is divided into segments
 * and the medium is sampled once per segment, with no distance field to march against — cloud density is
 * not an SDF and sphere tracing does not apply. Front-to-back emission/absorption integration: at each
 * step the sample's in-scattering (sun radiance, attenuated by the light march, shaped by the HG phase;
 * plus a height-graded sky ambient) is accumulated weighted by how much light still reaches the eye, and
 * the transmittance is decremented by Beer-Lambert. The caller composites with
 * `col * transmittance + scatter`, so the result is correct over any background — including a terrain
 * hit, which is what makes the volumetric style occlude and be occluded correctly.
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
    //
    // Clamped to a fixed block count rather than a fraction of the slab, for the reason cloudTrace
    // gives: the genesis model can hand this deck a 207-block slab, and a proportional zone would
    // punch a hole straight through the middle of every cloud the player flies into.
    float deckRel = push.clouds.w - originRel.y;
    float halfThickness = min(max(thickness, 0.5) * 0.5, CLOUD_CROSS_EXCLUSION_BLOCKS);
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
    // vertical view ever reaches — which is why distant cloud went solid white even at low opacity,
    // while the same cloud overhead looked correct. Real cumulus does not behave like an infinite slab
    // either: you see individual clouds with sky between them, not a continuous wall.
    //
    // The cap is an absolute distance now rather than a number of slab depths, because the genesis model
    // made the slab depth weather-dependent: measuring the budget in crossings would make a storm's
    // horizon rays 6x more expensive than a fair-weather one's, and cost would follow the sky instead of
    // staying bounded. 640 blocks is well past where the horizon fade has taken the cloud to nothing.
    t1 = min(t1, t0 + CLOUD_MAX_MARCH_BLOCKS);
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
    float cosT = dot(dir, push.lightDir.xyz);
    float phase = cloudPhase(cosT);
    float opacity = clamp(push.clouds.y, 0.0, 1.0);
    // Scale the step count to the distance actually being marched, so a deep deck is sampled as finely
    // as a shallow one instead of just taking longer strides. Clamped both ways: never coarser than the
    // base count, never more expensive than the cap.
    int stepCap = highQuality ? CLOUD_MARCH_STEPS_MAX : CLOUD_MARCH_STEPS_CHEAP_MAX;
    marchSteps = clamp(int((t1 - t0) / CLOUD_TARGET_STEP_BLOCKS), marchSteps, stepCap);
    float stepLen = (t1 - t0) / float(marchSteps);
    bool classic = cloudStyle(push) == CLOUD_STYLE_CLASSIC;

    // Extinction, split in two. sigmaMEDIUM is the medium's own property — normalised by the slab depth
    // so a deep deck adds VOLUME rather than opacity, with no cross-talk into the opacity slider. sigma
    // is what the eye march actually integrates, additionally carrying the two view fades, which are
    // properties of WHERE THE OBSERVER IS and must never leak into the light march: a cloud's shadow on
    // itself cannot depend on the camera, or self-shadowing would swim as the player turns.
    float sigmaMedium = CLOUD_EXTINCTION * (classic ? CLOUD_CLASSIC_EXTINCTION_SCALE : 1.0)
            * (CLOUD_REFERENCE_THICKNESS / max(thickness, 1.0));
    float sigma = sigmaMedium * fade * crossFade;
    float lightDistance = thickness * CLOUD_LIGHT_DISTANCE_SCALE;

    // Stochastic sample placement, per ray rather than per step. A uniform grid of samples through a
    // volume aliases: the step length is 8 blocks and the finest feature in the field is a 16-block
    // Worley cell, so a grid phased unluckily against the field resolves the same two lobes every step
    // and the march bands. Offsetting the whole grid by one random fraction of a step turns that
    // structure into variance, which the frame's own accumulation and the denoiser are already built to
    // remove — the same trade the tracer makes everywhere else. The cheap tier stays deterministic: its
    // result is averaged over a hemisphere anyway, so it would only be spending entropy.
    float jitter = 0.5;
    if (highQuality) {
        jitter = cloudRand(float3(dir.x * 977.0 + dir.z * 337.0, dir.y * 613.0 + dir.x * 179.0,
                                  float(push.frameIndex) * 0.7177 + dir.z * 271.0));
    }

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
        float3 p = originRel + dir * (t0 + stepLen * (float(i) + jitter));
        float heightFrac = clamp((p.y - slabBottom) / max(slabTop - slabBottom, 1.0e-3), 0.0, 1.0);
        float density = cloudVolumeDensity(push, p, heightFrac, thickness, highQuality);
        if (density <= 0.0) {
            continue;
        }
        float extinction = density * sigma * stepLen;
        float sampleTransmittance = exp(-extinction);
        float tau = cloudLightOpticalDepth(push, p, push.lightDir.xyz, slabBottom, slabTop,
                                           lightDistance, lightSteps) * sigmaMedium;
        float3 inScatter;
        if (classic) {
            // Flat, vanilla-style face tone. Plain Beer-Lambert (no powder) because these boxes are
            // opaque and must not grow a translucent rim, and self-shadowing deliberately damped — mixed
            // only 40% in — so cloud boxes keep the poster-flat look instead of developing soft
            // volumetric gradients.
            float shade = lerp(1.0, cloudBeerLambert(tau), 0.4);
            inScatter = push.cloudColor.xyz * CLOUD_INV_PI
                    * (sunRadiance * classicFace * shade * 3.0 + skyBehind * 1.4);
        } else {
            // Single scattering from the sun through the beer-powder attenuation, plus an ambient term
            // graded by HEIGHT inside the cloud. That gradient is not decoration: a sample near the crown
            // sees most of the sky, a sample near the base sees the underside of its own cloud, so the
            // ambient has to fall off toward the floor or the whole deck shades as one uniform grey
            // volume. It is what makes the underside read as SHADED rather than merely dark, and it
            // costs one lerp.
            float3 ambient = skyBehind * lerp(CLOUD_AMBIENT_BASE, CLOUD_AMBIENT_TOP, heightFrac);
            // The sun's own colour leaks into the ambient at the base, where what little light reaches
            // there has been through a lot of cloud — forward-scattered, so warm and dim.
            ambient += sunRadiance * 0.035 * (1.0 - heightFrac);
            // Beer-Lambert along the light path, on the reduced-extinction multiple-scattering octave;
            // the powder term darkens the thin edges relative to the core; the dual-lobe phase puts the
            // silver lining on the sun-facing rim and the weak backward lobe keeps the shaded side from
            // collapsing into a silhouette.
            float lightTransmittance =
                    cloudBeerLambert(tau * CLOUD_LIGHT_EXTINCTION_SCALE);
            float powder = lerp(1.0, cloudPowder(density), CLOUD_POWDER_STRENGTH);
            inScatter = CLOUD_ALBEDO
                    * (sunRadiance * lightTransmittance * powder * phase * CLOUD_SUN_GAIN + ambient);
        }
        // Energy-conserving accumulation: integrate in-scatter over the step's absorbed fraction.
        result.scatter += result.transmittance * inScatter * (1.0 - sampleTransmittance);
        result.transmittance *= sampleTransmittance;
        if (result.transmittance < 0.01) {
            result.transmittance = 0.0;
            break; // fully saturated; further steps cannot contribute
        }
    }

    // Aerial perspective, on the same curve as the horizon fade: past the point where the deck has begun
    // to thin out with distance it also has to lose CONTRAST against the sky behind it, or the horizon
    // keeps a hard-edged cut-out skyline sitting on top of the atmosphere instead of sinking into it.
    // Blending the premultiplied scatter toward `skyBehind * absorbed` is exactly that — the cloud still
    // occludes the same fraction of sky, it just stops being a different colour from it.
    float aerial = smoothstep(push.cloudAnchor.w * 0.55, push.cloudAnchor.w, horizon);
    if (aerial > 0.0 && !classic) {
        float absorbed = 1.0 - result.transmittance;
        result.scatter = lerp(result.scatter, skyBehind * absorbed,
                              aerial * CLOUD_AERIAL_PERSPECTIVE);
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
