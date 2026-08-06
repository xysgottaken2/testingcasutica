// Cloud deck — two selectable styles over ONE authored cell map.
//
// NOTE: this file is the post-rework state (see docs/cloud-rework-plan.md). The procedural noise
// field was replaced by vanilla's authored textures/environment/clouds.png cell map, transported
// through the WorldPush BDA ring by RtCloudCells (same mechanism as the DH ready mask, no new
// binding). Cloud shape is authored data now, exactly like vanilla — see cloudCellShown.
//
// Caustica cancels vanilla's LevelRenderer outright (see LevelRendererMixin), and vanilla's cloud pass
// lives inside it — so under the ray-traced renderer there were simply no clouds in the world at all.
// The sky shader modelled an atmosphere, a sun, a moon and a starfield, and the weather code even
// hid the celestial discs "behind the cloud deck" during rain, but nothing ever drew that deck. This
// module is that deck.
//
// TWO STYLES, ONE MAP. The authored cell grid is the single source of truth for WHERE clouds are;
// both styles, and the shadow query, are built on that same 256x256 cell map, so a cloud and the
// shadow it casts are always in the same place.
//   * CLOUD_STYLE_CLASSIC — vanilla's blocky clouds, verbatim. Cells are extruded into axis-aligned
//     boxes and intersected ANALYTICALLY (cloudTraceBoxes): a 2D grid traversal steps the ray through
//     the cells inside the slab and the first shown cell is slab-tested exactly. No march, no light
//     loop, no noise — and the silhouette is genuinely square-edged, like vanilla's geometry.
//     The thickness slider sets the box height (minimum 4 blocks, vanilla's own extrusion height).
//   * CLOUD_STYLE_VOLUMETRIC — billowy cumulus built on the SAME cells. The authored occupancy
//     (binary, one byte lookup) replaces the old noise coverage field; the domain-warped fBm is
//     kept as interior detail and edge erosion, marched with light-marched self-shadowing,
//     Beer-Lambert extinction, a dual-lobe Henyey-Greenstein phase and a powder (dark-edge) term.
//     Vertical development is reserved: only cells whose whole 4-neighbourhood is occupied grow
//     towers through the full slab; isolated cells stay low and flat (see cloudVolumeDensity).
//
// COLOUR COMES FROM VANILLA. The weather-resolved EnvironmentAttributes.CLOUD_COLOR (already
// computed by LevelExtractor into LevelRenderState.cloudColor, which Caustica does not cancel) is
// pushed in the cloudColor lane: clear weather is near-white, rain greys it (~0.62), thunder
// darkens it almost to black. No shader-side weather ramp.
//
// DEPTH-CORRECT AGAINST THE WORLD. Every entry point that produces visible cloud takes the distance to
// the nearest scene hit and stops there, so terrain in front of a cloud occludes it. Getting this wrong
// is exactly the bug where the world appeared to punch through the deck from above (see cloudLayer).
//
// Only world_common is imported: world.rmiss must NOT pull in world_core (that module declares the
// raygen bindings), so every entry point here takes the WorldPush explicitly, exactly like
// world_common's own worldFeature/worldFlag accessors.

import world_common;

// ---- Authored cell map. Vanilla's clouds.png is 256x256 pixels; each pixel is one 12-block cell
// (CLOUD_CELL_BLOCKS, vanilla's CELL_SIZE_IN_BLOCKS), so the pattern tiles every 256 * 12 = 3072
// blocks in both axes. The mod's wind-scrolled sample anchor already wraps to a whole multiple of
// 3072, so the lookup below wraps with a mask — exactly periodic by construction, with no anchor-wrap
// hazard at all. The CPU packs one byte per cell (mirroring CloudRenderer.packCellData) plus a second
// byte per cell for the coverage-filtered "shown" flag; see RtCloudCells.
public static const float CLOUD_CELL_BLOCKS = 12.0; // vanilla's cloud cell size
public static const int   CLOUD_CELLS_DIM = 256;
public static const int   CLOUD_CELLS_MASK = CLOUD_CELLS_DIM - 1;
public static const int   CLOUD_CELLS_TOTAL = CLOUD_CELLS_DIM * CLOUD_CELLS_DIM;
// Byte layout of the cell map behind cloudCellsAddr: 8-byte header (u32 magic "CLDC", u32 version),
// then CLOUD_CELLS_TOTAL occupancy/neighbour bytes, then CLOUD_CELLS_TOTAL "shown" bytes.
public static const uint  CLOUD_CELLS_HEADER_BYTES = 8u;
public static const uint  CLOUD_CELL_BIT_OCCUPIED = 1u;        // alpha >= 10 (vanilla isCellEmpty)
public static const uint  CLOUD_CELL_BIT_NORTH_EMPTY = 2u;     // neighbour-empty bits mirror vanilla's
public static const uint  CLOUD_CELL_BIT_EAST_EMPTY = 4u;      // packCellData (bit set = neighbour is
public static const uint  CLOUD_CELL_BIT_SOUTH_EMPTY = 8u;     // empty), kept for parity and for the
public static const uint  CLOUD_CELL_BIT_WEST_EMPTY = 16u;     // tower rule below.
public static const uint  CLOUD_CELL_BIT_SURROUNDED = 32u;     // all 4 neighbours occupied -> tower
public static const float CLOUD_MIN_BOX_HEIGHT = 4.0; // vanilla's extrusion height, in blocks

// Width of the coverage ramp no longer exists: the authored map is binary, so coverage is the CPU-side
// component filter (RtCloudCells), and "where is there cloud" is a byte test.

public static const float CLOUD_INV_PI = 0.31830988618;

// ---- Noise detail period (volumetric interior only). The warp/billow octaves sample the hash below;
// it repeats every CLOUD_PERIOD_CELLS cells in each sampled space, and the Java-side anchor wrap
// (CLOUD_FIELD_PERIOD_BLOCKS) is a whole multiple of every one of those periods, so the anchor wrap is
// seamless. Power of two so the mask is exact.
public static const int   CLOUD_PERIOD_CELLS = 512;
public static const int   CLOUD_CELL_MASK = CLOUD_PERIOD_CELLS - 1;

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
public static const float CLOUD_EXTINCTION = 0.115; // per block, at density 1
// Optical depth is normalised against this thickness, so making the deck taller adds VOLUME without
// making it more opaque. Without it, tau = density * sigma * pathLength grows with the slab depth and
// the thickness slider silently doubles as a second opacity slider.
public static const float CLOUD_REFERENCE_THICKNESS = 40.0;
// Longest in-slab path a single ray may integrate, in slab depths. Bounds the grazing/horizon case
// (see cloudMarch); a few crossings already saturate a real cloud.
public static const float CLOUD_MAX_SLAB_CROSSINGS = 3.5;
// Horizontal scales of the volumetric interior detail, relative to the 12-block cell grid. These are
// the ONLY remaining noise spaces, and every one of them MUST be a power of two: the anchor wrap has to
// land on a whole hash period in each sampled space (the hash repeats every 512 cells). Non-power-of-two
// divisors desync the detail at every wrap — visible as a one-frame pop while walking. (The old base
// field carried the same constraint; it is gone now — the shape comes from the cell map, which wraps
// with a mask and has no scale constraint at all.)
public static const float CLOUD_WARP_DIV = 2.0;
public static const float CLOUD_BILLOW_DIV_COARSE = 1.0;
public static const float CLOUD_BILLOW_DIV_FINE = 0.25;
public static const float CLOUD_HG_G = 0.72;        // forward-scattering anisotropy of cloud droplets
public static const float CLOUD_HG_BACK = -0.28;    // weak backward lobe (see cloudPhase)
public static const float CLOUD_POWDER_STRENGTH = 0.7; // dark-edge / multiple-scattering approximation

// Longest classic grid walk per ray, in cells. The walk is bounded by the slab crossing cap anyway
// (CLOUD_MAX_SLAB_CROSSINGS * height / 12 cells); this guard catches degenerate geometries.
public static const int   CLOUD_BOX_WALK_MAX = 160;

/**
 * Whether this frame draws clouds at all. Coverage or opacity at zero answers false, so the player
 * sliders bottoming out costs one comparison rather than a wasted intersection, and every consumer
 * short-circuits to the exact pre-cloud result (bit-identical output when the feature is off).
 * A missing cell map or a zero vanilla cloud-colour alpha (Nether/End resolve it to 0) also answer
 * false — the same gate vanilla's own renderer uses (ARGB.alpha(cloudColor) > 0).
 */
public bool cloudsEnabled(WorldPush push) {
    return push.dimension == DIMENSION_OVERWORLD
        && worldFeature(push, FEATURE_CLOUDS)
        && push.clouds.x > 0.0
        && push.clouds.y > 0.0
        && push.cloudColor.w > 0.0
        && cloudCellMapPresent(push);
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

/**
 * Weather amount that should push clouds toward a dark storm colour. Uses the raw rain/thunder lanes
 * (weather.x + weather.y * 0.5) — the same combination the sky darkening uses, so a storm's dark sky,
 * its grey clouds and its dimmed discs are one reading of one state and cannot drift apart.
 */
public float cloudStormAmount(WorldPush push) {
    return worldFeature(push, FEATURE_WEATHER_LIGHTING)
            ? clamp(push.weather.x + push.weather.y * 0.5, 0.0, 1.0) : 0.0;
}

/**
 * Vanilla's weather-resolved cloud tint. Pushed straight from LevelRenderState.cloudColor
 * (EnvironmentAttributes.CLOUD_COLOR resolved by LevelExtractor): clear weather is near-white, rain
 * greys it, thunder darkens it. The value is deliberately NOT linearised: vanilla applies it in its
 * own gamma-space pipeline, and reproducing that keeps the relative rain darkening identical to
 * vanilla's (~0.62 in rain) instead of a physically-correct-but-darker linear interpretation.
 */
public float3 cloudTint(WorldPush push) {
    return push.cloudColor.xyz;
}

// ---- Authored cell map lookups --------------------------------------------------

/** True when the ring slot carries a valid cell map ("CLDC" magic, RtCloudCells). */
public bool cloudCellMapPresent(WorldPush push) {
    return push.cloudCellsAddr != 0
            && ConstPtr<uint>(push.cloudCellsAddr)[0] == 0x434C4443u; // "CLDC"
}

/**
 * The raw cell byte (occupancy + neighbour-empty bits + surrounded flag). `cell` is in cell units;
 * both axes wrap with a mask, which is exactly periodic for any integer coordinate (two's complement
 * makes `& 255` equivalent to floorMod for negative cells too).
 */
public int cloudCellBits(WorldPush push, int2 cell) {
    uint i = uint((cell.y & CLOUD_CELLS_MASK) * CLOUD_CELLS_DIM + (cell.x & CLOUD_CELLS_MASK));
    ConstPtr<uint> map = ConstPtr<uint>(push.cloudCellsAddr + CLOUD_CELLS_HEADER_BYTES);
    return int((map[i >> 2u] >> ((i & 3u) << 3u)) & 0xFFu);
}

/**
 * The coverage-filtered "shown" flag (RtCloudCells rebuilds it on the CPU when the coverage slider or
 * the weather changes): the cell is part of a component included by the size-ranked coverage filter.
 */
public bool cloudCellShown(WorldPush push, int2 cell) {
    uint i = uint((cell.y & CLOUD_CELLS_MASK) * CLOUD_CELLS_DIM + (cell.x & CLOUD_CELLS_MASK));
    ConstPtr<uint> map = ConstPtr<uint>(push.cloudCellsAddr
            + CLOUD_CELLS_HEADER_BYTES + CLOUD_CELLS_TOTAL);
    return ((map[i >> 2u] >> ((i & 3u) << 3u)) & 0xFFu) != 0u;
}

/**
 * Coverage resolved into a 0..1 "how much cloud is here" at a sample position, for the shadow query.
 * The shown map is binary per cell, but the four-tap bilinear keeps the shadow edges soft: a 12-block
 * hard step between lit and shadowed terrain reads as an aliasing band, and vanilla's own silhouette
 * is quantised anyway — the smooth interpolation is free (4 byte lookups, no noise).
 */
public float cloudCoverage(WorldPush push, float2 samplePos) {
    if (!cloudCellMapPresent(push)) {
        return 0.0;
    }
    float2 cellF = samplePos / CLOUD_CELL_BLOCKS;
    int2 cell = int2(floor(cellF));
    float2 f = cellF - float2(cell);
    float a = cloudCellShown(push, cell) ? 1.0 : 0.0;
    float b = cloudCellShown(push, cell + int2(1, 0)) ? 1.0 : 0.0;
    float c = cloudCellShown(push, cell + int2(0, 1)) ? 1.0 : 0.0;
    float d = cloudCellShown(push, cell + int2(1, 1)) ? 1.0 : 0.0;
    return lerp(lerp(a, b, f.x), lerp(c, d, f.x), f.y);
}

/**
 * How much of the celestial (sun or moon) light survives the deck on its way to `pointRel`.
 *
 * This is the "Cloud Shadows" slider, and it is an analytic plane intersection plus one coverage
 * evaluation — no march, no extra ray, no added variance for the denoiser to chase, for either style.
 *
 * It samples the SHOWN cell map at the deck's mid-plane, not the eroded 3D density, so for the
 * volumetric style the shadow follows the cloud's overall footprint rather than its individual
 * billows. That is a deliberate trade: matching per-lobe would mean marching the slab for every
 * shading point of every path vertex, and the difference is a slightly softer shadow edge that is
 * indistinguishable in motion from the real thing.
 *
 * In a CLOSED storm ceiling (rain has driven the coverage slider to 1 — see cloudState), the overcast
 * is an atmospheric condition, not a geometric shadow: applying it only under occupied columns would
 * dapple the terrain with sun patches through the texture's 20 % of holes, which is exactly the old
 * "camera-following clear dome" bug. Once weather has closed the deck, the storm attenuation applies
 * to every receiver (globalStormAlpha) and the cell lookup only adds detail in patchy weather.
 *
 * This deliberately does NOT use the visible-cloud query (cloudSegment/cloudTraceBoxes): that path
 * applies camera-facing cross-fades and the finite view-distance fade stored in cloudAnchor.w. Using
 * it for sun visibility made the cloud-shadow multiplier depend on the observer (not just on the
 * receiver and the sun): when the camera crossed above a block shadow, the same terrain hit could
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

    float storm = cloudStormAmount(push);
    float opacity = clamp(push.clouds.y, 0.0, 1.0);
    // Closed-ceiling attenuation: rain has pushed the coverage slider to 1 (cloudState), so the storm
    // dims every receiver regardless of which cells sit over it.
    float globalStormAlpha = opacity * storm * smoothstep(0.80, 0.999, clamp(push.clouds.x, 0.0, 1.0));

    float deckRel = push.clouds.w - pointRel.y;
    float t = deckRel / lightDir.y;
    if (t <= 0.0) {
        return 1.0 - strength * globalStormAlpha;
    }

    float2 samplePos = push.cloudAnchor.xy + pointRel.xz + lightDir.xz * t;
    float alpha = clamp(cloudCoverage(push, samplePos) * opacity, 0.0, 1.0);
    alpha = max(alpha, globalStormAlpha);
    return 1.0 - strength * alpha;
}

// ---- Classic (vanilla boxes) ---------------------------------------------------------------------

/** Result of intersecting a ray with the extruded-cell deck (classic style). */
public struct CloudBoxHit {
    public bool hit;
    public float distance;   // along the ray to the entry face
    public uint face;        // 0 top, 1 bottom, 2 x-side (0.9), 3 z-side (0.8) — vanilla face tones
    public float fade;       // horizon/view-limit fade
};

/**
 * Exact box intersection against the authored cell map. The deck is a 12-block grid of columns and
 * every shown column is a box from deckBase to deckBase + height (cloudAnchor.z, never thinner than
 * vanilla's 4 blocks). A 2D grid traversal enumerates the cells the ray crosses inside the slab, and
 * the first shown cell is slab-tested EXACTLY — no march, no light loop, no noise. This is what makes
 * the classic style cheap enough to run per segment: one byte lookup per cell step, and the geometry
 * is axis-aligned by construction, so the intersection is analytic.
 *
 * When the ray starts INSIDE a shown box (flying through a cloud), the slab test returns the far face
 * — the same interior view vanilla's renderer produces with its camera-adjacent interior faces.
 */
public CloudBoxHit cloudTraceBoxes(WorldPush push, float3 originRel, float3 dir, float maxDistance) {
    CloudBoxHit h;
    h.hit = false;
    h.distance = 0.0;
    h.face = 0;
    h.fade = 0.0;

    float thickness = max(push.cloudAnchor.z, CLOUD_MIN_BOX_HEIGHT);
    float slabBottom = push.clouds.w - thickness * 0.5 - originRel.y;
    float slabTop = push.clouds.w + thickness * 0.5 - originRel.y;

    // Slab entry/exit along the ray, bounded by the view limit like every other ray.
    float t0, t1;
    if (abs(dir.y) < 1.0e-4) {
        if (slabBottom > 0.0 || slabTop < 0.0) {
            return h; // parallel and outside the slab
        }
        t0 = 0.0;
        t1 = push.cloudAnchor.w;
    } else {
        float ta = slabBottom / dir.y;
        float tb = slabTop / dir.y;
        t0 = max(min(ta, tb), 0.0);
        t1 = min(max(ta, tb), min(maxDistance, push.cloudAnchor.w));
    }
    // Cap how far a single ray may travel INSIDE the deck (same bound as the volumetric march): a
    // grazing ray would otherwise walk the whole view limit through the grid.
    t1 = min(t1, t0 + thickness * CLOUD_MAX_SLAB_CROSSINGS);
    if (t1 <= t0) {
        return h;
    }
    // Distance fade, matched to the march and the old flat deck: cloud ends before the view limit.
    float horizon = length(dir.xz) * t0;
    float fade = 1.0 - smoothstep(push.cloudAnchor.w * 0.55, push.cloudAnchor.w, horizon);
    if (fade <= 0.0) {
        return h;
    }
    h.fade = fade;

    // 2D grid traversal in the world-anchored sample space. `s0` is the camera-relative origin folded
    // onto the wind-scrolled anchor, so the cells are pinned to the world and the texture tiles.
    float2 s0 = push.cloudAnchor.xy + originRel.xz;
    float2 d = dir.xz;
    int2 cell = int2(floor(s0 / CLOUD_CELL_BLOCKS));
    float2 cellMin = float2(cell) * CLOUD_CELL_BLOCKS;
    float2 tNext; // t at which the ray crosses the next cell boundary in each axis
    int2 step;
    float2 tDelta;
    for (int axis = 0; axis < 2; axis++) {
        float dv = d[axis];
        if (abs(dv) < 1.0e-6) {
            step[axis] = 0;
            tDelta[axis] = 1.0e30;
            tNext[axis] = 1.0e30;
        } else {
            float boundary = dv > 0.0 ? cellMin[axis] + CLOUD_CELL_BLOCKS : cellMin[axis];
            tNext[axis] = (boundary - s0[axis]) / dv;
            step[axis] = dv > 0.0 ? 1 : -1;
            tDelta[axis] = CLOUD_CELL_BLOCKS / abs(dv);
        }
    }

    float tEntry = t0;
    for (int guard = 0; guard < CLOUD_BOX_WALK_MAX; guard++) {
        if (cloudCellShown(push, cell)) {
            // Exact slab test for this cell's box, in camera-relative space (the anchor is subtracted
            // back out of the cell corners). The box's Y range must live in the SAME space as the XZ
            // corners — push.clouds.w is already camera-relative, so the box spans it directly. Using
            // the origin-relative slabBottom/slabTop here would subtract originRel.y twice and shift
            // the whole deck's vertical position for every non-camera segment (a water reflection
            // would hit its clouds 2x too low). The direction is clamped off zero so a ray parallel to
            // an axis cannot produce inf*0 NaNs in the slab arithmetic; the walk never reaches a cell
            // whose entry would require that axis anyway (tNext stays 1e30).
            float2 boxMin = cellMin - push.cloudAnchor.xy;
            float3 bmin = float3(boxMin.x, push.clouds.w - thickness * 0.5, boxMin.y);
            float3 bmax = float3(boxMin.x + CLOUD_CELL_BLOCKS, push.clouds.w + thickness * 0.5,
                    boxMin.y + CLOUD_CELL_BLOCKS);
            float3 dSafe = dir;
            if (abs(dSafe.x) < 1.0e-6) dSafe.x = 1.0e-6;
            if (abs(dSafe.y) < 1.0e-6) dSafe.y = 1.0e-6;
            if (abs(dSafe.z) < 1.0e-6) dSafe.z = 1.0e-6;
            float3 invD = 1.0 / dSafe;
            float3 tA = (bmin - originRel) * invD;
            float3 tB = (bmax - originRel) * invD;
            float3 tmin3 = min(tA, tB);
            float3 tmax3 = max(tA, tB);
            float boxTmin = max(max(tmin3.x, tmin3.y), tmin3.z);
            float boxTmax = min(min(tmax3.x, tmax3.y), tmax3.z);
            if (boxTmax > 0.0 && boxTmin <= boxTmax) {
                if (boxTmin > 0.0) {
                    // Entry face: the axis whose entry slab is hit last. The face tone only needs the
                    // axis class (vanilla shades x-sides 0.9, z-sides 0.8, top/bottom 1.0/0.7).
                    h.hit = true;
                    h.distance = boxTmin;
                    if (tmin3.y >= tmin3.x && tmin3.y >= tmin3.z) {
                        h.face = dSafe.y < 0.0 ? 0u : 1u; // entering downward = top, upward = bottom
                    } else if (tmin3.x >= tmin3.z) {
                        h.face = 2u; // x-side
                    } else {
                        h.face = 3u; // z-side
                    }
                } else {
                    // Origin inside the box: the ray exits through the far face.
                    h.hit = true;
                    h.distance = boxTmax;
                    if (tmax3.y <= tmax3.x && tmax3.y <= tmax3.z) {
                        h.face = dSafe.y < 0.0 ? 1u : 0u; // leaving downward = bottom, upward = top
                    } else if (tmax3.x <= tmax3.z) {
                        h.face = 2u;
                    } else {
                        h.face = 3u;
                    }
                }
                return h;
            }
        }
        // Advance to the next cell along the ray. The cell corners travel with the cell index — the box
        // test above reads cellMin, so it must be updated here or every later cell would be slab-tested
        // against the FIRST cell's corners.
        if (tNext.x <= tNext.y) {
            tEntry = tNext.x;
            if (tEntry >= t1) {
                break;
            }
            cell.x += step.x;
            cellMin.x += step.x * CLOUD_CELL_BLOCKS;
            tNext.x += tDelta.x;
        } else {
            tEntry = tNext.y;
            if (tEntry >= t1) {
                break;
            }
            cell.y += step.y;
            cellMin.y += step.y * CLOUD_CELL_BLOCKS;
            tNext.y += tDelta.y;
        }
    }
    return h;
}

/**
 * Flat face radiance for a box hit, shaded like vanilla's cloud quads: distinctly brighter top,
 * darker underside, mid-tones for the sides — the exact faceColors table from rendertype_clouds.vsh
 * (top 1.0, bottom 0.7, x-sides 0.9, z-sides 0.8), multiplied by the weather-resolved vanilla tint.
 *
 * Lit from worldPush.lightRadiance — the SAME value the ground's NEE uses — so the clouds ride every
 * curve the rest of the frame already follows: they redden through sunset on the atmosphere's own
 * transmittance, dim under the weather attenuation, and grey in rain through cloudTint. Hand-picking
 * a cloud colour is what makes cloud layers look pasted on.
 */
float3 cloudBoxRadiance(WorldPush push, CloudBoxHit h, float3 dir, float3 skyBehind) {
    float3 sunRadiance = push.lightRadiance.xyz;
    float face = h.face == 0u ? 1.0 : (h.face == 1u ? 0.7 : (h.face == 2u ? 0.9 : 0.8));
    float3 lit = cloudTint(push) * CLOUD_INV_PI * sunRadiance * face;
    // The classic deck is opaque, so it admits only a little sky fill — enough to keep it from going
    // black at night, when sunRadiance is near zero.
    return lit + skyBehind * 0.45;
}

/**
 * Classic style: the deck as opaque boxes, composited as premultiplied scatter + transmittance so
 * callers use the identical two lines they already use for fog and the volumetric march.
 */
CloudVolume cloudSegmentClassic(WorldPush push, float3 originRel, float3 dir, float maxDistance,
                                float3 skyBehind) {
    CloudVolume result;
    result.scatter = float3(0.0, 0.0, 0.0);
    result.transmittance = 1.0;
    if (!cloudsEnabled(push)) {
        return result;
    }
    CloudBoxHit h = cloudTraceBoxes(push, originRel, dir, maxDistance);
    if (!h.hit) {
        return result;
    }
    // The box itself is opaque; alpha is the player's opacity slider × vanilla's weather-resolved
    // base opacity (cloudColor.w) × the view-limit fade, applied to the finished result so a 20 %
    // opacity cloud is exactly "20 % of this box", never a translucent-looking volume.
    float alpha = clamp(push.clouds.y * push.cloudColor.w * h.fade, 0.0, 1.0);
    result.scatter = cloudBoxRadiance(push, h, dir, skyBehind) * alpha;
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

// Integer cell hash for the interior-detail noise. Integer mixing rather than the sky's float hash13:
// the sample coordinate here is a world position that can be thousands of blocks from the anchor, where
// a float hash starts losing mantissa bits and the pattern degenerates into stripes. The mask is what
// makes the detail periodic in every octave's sampled space (see CLOUD_WARP_DIV).
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

/**
 * 3D density inside the slab, per style.
 *
 * CLASSIC no longer routes here: the analytic box path (cloudTraceBoxes) is exact and needs no
 * density. The VOLUMETRIC style is the only marcher.
 *
 * VOLUMETRIC is cumulus built on the authored cell map:
 *   * the SHAPE is the cell (binary, one byte lookup) — an empty cell costs exactly one lookup and
 *     returns immediately, which is ~80 % of all samples;
 *   * VERTICAL DEVELOPMENT is reserved: cells whose whole 4-neighbourhood is occupied (the cores of
 *     the big systems) grow towers through the full slab, while cells with any empty neighbour stay
 *     low and flat. That is the "a few thick clouds, not everything uniform" rule — authored shape
 *     decides where the deck is tall, not a global constant;
 *   * DOMAIN WARPING displaces the sample before the detail octaves are read, which turns straight,
 *     gridded edges into curling, rounded lobes;
 *   * BILLOW detail (inverted noise) erodes the crown into a cauliflower profile and frays the base.
 */
float cloudVolumeDensity(WorldPush push, float3 posRel, float heightFrac) {
    float2 samplePos = push.cloudAnchor.xy + posRel.xz;
    float hf = clamp(heightFrac, 0.0, 1.0);

    int2 cell = int2(floor(samplePos / CLOUD_CELL_BLOCKS));
    if (!cloudCellShown(push, cell)) {
        return 0.0; // the authored shape decides; ~80 % of samples leave here
    }
    int bits = cloudCellBits(push, cell);
    int emptyNeighbours = ((bits & CLOUD_CELL_BIT_NORTH_EMPTY) != 0 ? 1 : 0)
            + ((bits & CLOUD_CELL_BIT_EAST_EMPTY) != 0 ? 1 : 0)
            + ((bits & CLOUD_CELL_BIT_SOUTH_EMPTY) != 0 ? 1 : 0)
            + ((bits & CLOUD_CELL_BIT_WEST_EMPTY) != 0 ? 1 : 0);
    // Vertical development. A cumulus has a hard flat base (condensation level), a tall body that stays
    // dense, and a rounded crown; the crown reaches towerTop up the slab. Surrounded cells (the dense
    // cores of large systems) billow through the whole slab; the more empty neighbours a cell has, the
    // flatter it stays — isolated puffs are thin sheets, big masses grow towers.
    float towerTop = (bits & CLOUD_CELL_BIT_SURROUNDED) != 0
            ? 1.0 : lerp(0.30, 0.55, float(4 - emptyNeighbours) * 0.25);
    float bottom = smoothstep(0.0, 0.10, hf);
    float top = 1.0 - smoothstep(towerTop * 0.62, towerTop, hf);
    float profile = clamp(bottom * top, 0.0, 1.0);

    // Domain warp, amplitude growing with height: bases stay flat, crowns curl into rounded lobes.
    float2 warpUv = samplePos / (CLOUD_CELL_BLOCKS * CLOUD_WARP_DIV);
    float2 warp = float2(cloudNoise(warpUv), cloudNoise(warpUv + float2(41.0, 17.0))) - 0.5;
    float2 warped = samplePos + warp * CLOUD_CELL_BLOCKS * (1.0 + 3.0 * hf);

    // Billow detail: inverted noise (1 - |2n-1|) gives rounded cellular lobes rather than a cloudy blur,
    // which is what reads as cauliflower. Scales chosen so the lobes are a fraction of a cloud's width,
    // not a fraction of a cell — small lobes on a big cloud is exactly the cumulus look.
    float d1 = cloudNoise(warped / (CLOUD_CELL_BLOCKS * CLOUD_BILLOW_DIV_COARSE));
    float d2 = cloudNoise(warped / (CLOUD_CELL_BLOCKS * CLOUD_BILLOW_DIV_FINE) + float2(19.0, 7.0));
    float billow = (1.0 - abs(d1 * 2.0 - 1.0)) * 0.7 + (1.0 - abs(d2 * 2.0 - 1.0)) * 0.3;

    // Erosion concentrated at the extremes: the crown breaks into lobes and the base frays, but the
    // middle of the cloud stays solid. Uniform erosion is what makes procedural clouds look like fog.
    float extremes = smoothstep(0.55, 1.0, hf) * 0.85 + smoothstep(0.18, 0.0, hf) * 0.5;
    float erosion = billow * (0.55 + extremes * 0.45);

    // Dense core: cumulus interiors are optically thick, and an authored cell is fully cloud — the
    // interior must reach well above 1.0 pre-clamp or the deck reads as haze no matter how deep it is.
    float density = 1.6 - erosion;
    return clamp(density, 0.0, 1.0) * profile;
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
    int marchSteps = highQuality ? CLOUD_MARCH_STEPS : CLOUD_MARCH_STEPS_CHEAP;
    int lightSteps = highQuality ? CLOUD_LIGHT_STEPS : CLOUD_LIGHT_STEPS_CHEAP;
    CloudVolume result;
    result.scatter = float3(0.0, 0.0, 0.0);
    result.transmittance = 1.0;

    // ---- Crossing-region exclusion (the camera-following horizontal band).
    // When the camera sits near the deck's mid-plane, near-horizontal rays stay inside the slab for
    // up to CLOUD_MAX_SLAB_CROSSINGS slab depths and saturate: a bright band at the deck altitude that
    // follows the camera wherever it flies. The old flat deck dissolved within this band via a
    // coverage fade; the march had NO equivalent, and fading coverage never touched the accumulated
    // in-scatter. The fix is to EXCLUDE the slab within the crossing region: a ray whose origin is
    // inside the band integrates nothing, and rays outside the band have their result scaled by the
    // same crossFade, so the deck dissolves smoothly at the band edge instead of popping.
    float deckRel = push.clouds.w - originRel.y; // deck mid-plane height relative to this ray's origin
    float halfThickness = max(push.cloudAnchor.z, 0.5) * 0.5;
    float crossFade = smoothstep(halfThickness * 0.5, halfThickness * 1.5, abs(deckRel));
    if (crossFade <= 0.0) {
        return result;
    }

    float thickness = max(push.cloudAnchor.z, 1.0);
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

    // Distance fade, matched to the classic boxes' fade so the two styles agree about where cloud ends.
    float horizon = length(dir.xz) * t0;
    float fade = 1.0 - smoothstep(push.cloudAnchor.w * 0.55, push.cloudAnchor.w, horizon);
    if (fade <= 0.0) {
        return result;
    }

    float3 sunRadiance = push.lightRadiance.xyz;
    float3 dropletAlbedo = cloudTint(push);
    float cosT = dot(dir, push.lightDir.xyz);
    float phase = cloudPhase(cosT);
    float opacity = clamp(push.clouds.y, 0.0, 1.0);
    // Scale the step count to the distance actually being marched, so a thick deck is sampled as finely
    // as a thin one instead of just taking longer strides. Clamped both ways: never coarser than the
    // base count, never more expensive than the cap.
    int stepCap = highQuality ? CLOUD_MARCH_STEPS_MAX : CLOUD_MARCH_STEPS_CHEAP_MAX;
    marchSteps = clamp(int((t1 - t0) / CLOUD_TARGET_STEP_BLOCKS), marchSteps, stepCap);
    float stepLen = (t1 - t0) / float(marchSteps);
    // Extinction is normalised by the slab depth: a 100-block bank and a 4-block sheet reach the same
    // optical depth straight down, so THICKNESS controls shape and OPACITY controls see-through, with
    // no cross-talk. opacity is deliberately NOT folded in here — see the cap after the march.
    float sigma = CLOUD_EXTINCTION * (CLOUD_REFERENCE_THICKNESS / max(thickness, 1.0)) * fade;

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
        // Direct sun scattering + an ambient sky term so the shadowed interior is grey rather than
        // black. Powder brightens dense interiors (multiple-scattering approximation).
        float powder = lerp(1.0, cloudPowder(density), CLOUD_POWDER_STRENGTH);
        float3 inScatter = dropletAlbedo
                * (sunRadiance * lightT * phase * powder * 4.0 + skyBehind * 0.35);
        // Energy-conserving accumulation: integrate in-scatter over the step's absorbed fraction.
        result.scatter += result.transmittance * inScatter * (1.0 - sampleTransmittance);
        result.transmittance *= sampleTransmittance;
        if (result.transmittance < 0.01) {
            result.transmittance = 0.0;
            break; // fully saturated; further steps cannot contribute
        }
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
    // `background * transmittance + scatter` energy-correct. The crossing crossFade rides the same cap,
    // so the deck's dissolve at the band edge scales scatter and transmittance together.
    result.scatter *= opacity * crossFade;
    result.transmittance = 1.0 - (1.0 - result.transmittance) * opacity * crossFade;
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
    if (cloudStyle(push) == CLOUD_STYLE_CLASSIC) {
        return cloudSegmentClassic(push, originRel, dir, maxDistance, ambient);
    }
    return cloudMarch(push, originRel, dir, maxDistance, ambient, highQuality);
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
