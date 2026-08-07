// Cloud deck — two selectable styles over one shared field.
//
// Caustica cancels vanilla's LevelRenderer outright (see LevelRendererMixin), and vanilla's cloud pass
// lives inside it — so under the ray-traced renderer there were simply no clouds in the world at all.
// The sky shader modelled an atmosphere, a sun, a moon and a starfield, and the weather code even
// hid the celestial discs "behind the cloud deck" during rain, but nothing ever drew that deck. This
// module is that deck.
//
// TWO STYLES, ONE FIELD. cloudCoverageField is the single source of truth for WHERE clouds are; both
// styles, and the shadow query, are built on that same 2D map, so a cloud and the shadow it casts are
// always in the same place. (The volumetric style then erodes that map into 3D detail, so its shadow is
// a coverage-accurate approximation rather than a per-lobe match — see cloudSunShadow.)
//   * CLOUD_STYLE_CLASSIC — vanilla's blocky clouds. Coverage is quantised to the 12-block cell grid,
//     so the silhouette is genuinely square-edged, and the slab is marched as a BOX: real 3D cuboids
//     with lit tops, shaded undersides and visibly darker vertical sides, exactly like vanilla's cloud
//     geometry. At zero thickness it collapses to the old flat sheet.
//   * CLOUD_STYLE_VOLUMETRIC — billowy, photoreal cumulus. The same coverage map drives a domain-warped
//     fBm density with a cauliflower erosion profile, marched with light-marched self-shadowing,
//     Beer-Lambert extinction, a dual-lobe Henyey-Greenstein phase and a powder (dark-edge) term.
//
// BOTH styles are marched volumes now, and both are driven by the same thickness slider, so "3D" is not
// a property of one style — it is a property of the deck, and the style only decides its shape language.
//
// DEPTH-CORRECT AGAINST THE WORLD. Every entry point that produces visible cloud takes the distance to
// the nearest scene hit and stops there, so terrain in front of a cloud occludes it. Getting this wrong
// is exactly the bug where the world appeared to punch through the deck from above (see cloudLayer).
//
// Only world_common is imported: world.rmiss must NOT pull in world_core (that module declares the
// raygen bindings), so every entry point here takes the WorldPush explicitly, exactly like
// world_common's own worldFeature/worldFlag accessors.

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
// Octave divisors for the warp and the two billow layers. ALL must be powers of two, for the same
// reason CLOUD_VOLUMETRIC_SCALE must be: each is another space the periodic hash is sampled in, and the
// anchor wrap has to be a whole hash period in every one of them simultaneously. The largest divisor is
// the binding constraint on CLOUD_FIELD_PERIOD_BLOCKS (Java): period >= 512 * CELL * maxDiv / SCALE.
// These were 2.0 / 0.9 / 0.35, and the two non-power-of-two ones desynced the detail layers at every
// wrap even after the base field was fixed — the same pop, just from the erosion instead of the shape.
public static const float CLOUD_WARP_DIV = 2.0;
public static const float CLOUD_BILLOW_DIV_COARSE = 1.0;
public static const float CLOUD_BILLOW_DIV_FINE = 0.25;
// How much wider a cloud gets around its belly than at its base/crown. Turns a straight-sided extrusion
// into a rounded, bulging mass — see the note in cloudVolumeDensity.
public static const float CLOUD_BULGE = 0.30;
public static const float CLOUD_HG_G = 0.72;        // forward-scattering anisotropy of cloud droplets
public static const float CLOUD_HG_BACK = -0.28;    // weak backward lobe (see cloudPhase)
public static const float CLOUD_POWDER_STRENGTH = 0.7; // dark-edge / multiple-scattering approximation
// Classic clouds are opaque boxes; this scales their extinction so a box saturates within its own
// thickness rather than looking like translucent haze.
public static const float CLOUD_CLASSIC_EXTINCTION_SCALE = 6.0;

/**
 * Whether this frame draws clouds at all. Coverage or opacity at zero answers false, so the player
 * sliders bottoming out costs one comparison rather than a wasted intersection, and every consumer
 * short-circuits to the exact pre-cloud result (bit-identical output when the feature is off).
 */
public bool cloudsEnabled(WorldPush push) {
    return push.dimension == DIMENSION_OVERWORLD
        && worldFeature(push, FEATURE_CLOUDS)
        && push.clouds.x > 0.0
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

bool classicTextureReady(WorldPush push) { return push.cloudCellsAddr != 0 && push.cloudCellsWidth > 0 && push.cloudCellsHeight > 0; }
bool isClassicCellOccupied(WorldPush push, int2 cell) {
    if (push.clouds.x >= 0.999) {
        return true;
    }
    if (!classicTextureReady(push)) {
        float2 centre = (float2(cell) + 0.5) * CLOUD_CELL_BLOCKS;
        float thr = 1.0 - clamp(push.clouds.x, 0.0, 1.0);
        return cloudCoverageField(centre) > thr + CLOUD_EDGE_SOFTNESS * 0.5;
    }
    int w = int(push.cloudCellsWidth);
    int h = int(push.cloudCellsHeight);
    int ix = cell.x % w; if (ix < 0) ix += w;
    int iz = cell.y % h; if (iz < 0) iz += h;
    uint idx = uint(ix + iz * w);
    ConstPtr<uint> cells = ConstPtr<uint>(push.cloudCellsAddr);
    return cells[idx] != 0;
}
float classicCoverageAt(WorldPush push, float2 samplePos) {
    if (push.clouds.x >= 0.999) return 1.0;
    int2 cell = int2(floor(samplePos / CLOUD_CELL_BLOCKS));
    return isClassicCellOccupied(push, cell) ? 1.0 : 0.0;
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
 * Coverage resolved into a 0..1 "how much cloud is here" for the current style.
 *
 * Classic QUANTISES to the cell grid: vanilla's clouds are axis-aligned quads on a 12-block lattice, so
 * a cell is either cloud or it is not. Sampling the field at the cell centre (rather than smoothstepping
 * the interpolated value) is what produces genuinely square edges instead of a soft blob that merely
 * looks low-resolution.
 */
public float cloudCoverage(WorldPush push, float2 samplePos) {
    float cov = clamp(push.clouds.x, 0.0, 1.0);
    if (cov >= 0.999) return 1.0;
    if (cloudStyle(push) == CLOUD_STYLE_CLASSIC) {
        return classicCoverageAt(push, samplePos);
    }
    float threshold = 1.0 - cov;
    return smoothstep(threshold, threshold + CLOUD_EDGE_SOFTNESS, cloudCoverageField(samplePos));
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

// ---- Classic analytic (authored texture) ----------------------------------------------

CloudVolume cloudClassicAnalytic(WorldPush push, float3 originRel, float3 dir, float maxDistance, float3 skyBehind, bool highQuality) {
    CloudVolume result;
    result.scatter = float3(0.0, 0.0, 0.0);
    result.transmittance = 1.0;
    if (!cloudsEnabled(push)) {
        return result;
    }
    float thickness = max(push.cloudAnchor.z, 4.0);
    float deckCentre = push.clouds.w;
    float slabBottom = deckCentre - thickness * 0.5 - originRel.y;
    float slabTop = deckCentre + thickness * 0.5 - originRel.y;
    float t0, t1;
    if (abs(dir.y) < 1.0e-4) {
        if (slabBottom > 0.0 || slabTop < 0.0) {
            return result;
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
    t1 = min(t1, t0 + thickness * CLOUD_MAX_SLAB_CROSSINGS);
    if (t1 <= t0) {
        return result;
    }
    float horizon = length(dir.xz) * t0;
    float fade = 1.0 - smoothstep(push.cloudAnchor.w * 0.55, push.cloudAnchor.w, horizon);
    if (fade <= 0.0) {
        return result;
    }
    float halfThickness = max(thickness, 0.5) * 0.5;
    float deckRel = deckCentre - originRel.y;
    float crossFade = smoothstep(halfThickness * 0.5, halfThickness * 1.5, abs(deckRel));
    if (crossFade <= 0.0) {
        return result;
    }
    fade *= crossFade;
    float opacity = clamp(push.clouds.y, 0.0, 1.0);
    float2 anchor = push.cloudAnchor.xy;
    float2 startPos = anchor + originRel.xz + dir.xz * t0;
    int2 startCell = int2(floor(startPos / CLOUD_CELL_BLOCKS));
    if (isClassicCellOccupied(push, startCell)) {
        CloudHit h;
        h.hit = true;
        h.samplePos = startPos;
        h.distance = t0;
        h.fade = fade;
        h.fromBelow = deckRel > 0.0;
        float alpha = clamp(opacity * fade, 0.0, 1.0);
        result.scatter = cloudRadianceClassic(push, h, dir, skyBehind) * alpha;
        result.transmittance = 1.0 - alpha;
        return result;
    }
    float2 invDir = float2(dir.x != 0.0 ? 1.0 / dir.x : 1.0e9, dir.z != 0.0 ? 1.0 / dir.z : 1.0e9);
    int2 step = int2(dir.x > 0.0 ? 1 : -1, dir.z > 0.0 ? 1 : -1);
    float2 cellOrigin = float2(startCell) * CLOUD_CELL_BLOCKS;
    float2 nextBoundary = cellOrigin + float2(step.x > 0 ? CLOUD_CELL_BLOCKS : 0.0, step.y > 0 ? CLOUD_CELL_BLOCKS : 0.0);
    float2 tMax = (nextBoundary - (anchor + originRel.xz)) / dir.xz;
    float2 tDelta = float2(12.0 / max(abs(dir.x), 1.0e-6), 12.0 / max(abs(dir.z), 1.0e-6));
    int2 curCell = startCell;
    float curT = t0;
    for (int i = 0; i < 256; i++) {
        if (tMax.x < tMax.y) {
            curT = tMax.x;
            tMax.x += tDelta.x;
            curCell.x += step.x;
        } else {
            curT = tMax.y;
            tMax.y += tDelta.y;
            curCell.y += step.y;
        }
        if (curT > t1) {
            break;
        }
        if (isClassicCellOccupied(push, curCell)) {
            CloudHit h;
            h.hit = true;
            h.samplePos = anchor + originRel.xz + dir.xz * curT;
            h.distance = curT;
            h.fade = fade;
            h.fromBelow = deckRel > 0.0;
            float alpha = clamp(opacity * fade, 0.0, 1.0);
            result.scatter = cloudRadianceClassic(push, h, dir, skyBehind) * alpha;
            result.transmittance = 1.0 - alpha;
            return result;
        }
    }
    return result;
}

// ---- Classic (vanilla-style) shading -------------------------------------------------------------

/**
 * Flat deck radiance, shaded like vanilla's cloud quads: a distinctly brighter top, a darker underside,
 * and a mid-tone for grazing/side views, so the deck reads as a solid box of cloud rather than a decal.
 *
 * Lit from worldPush.lightRadiance — the SAME value the ground's NEE uses — so the clouds ride every
 * curve the rest of the frame already follows: they redden through sunset on the atmosphere's own
 * transmittance, dim under the weather attenuation, and go to a dark sky-lit grey at night when the
 * moon takes over. Hand-picking a cloud colour is what makes cloud layers look pasted on.
 */
float3 cloudRadianceClassic(WorldPush push, CloudHit h, float3 dir, float3 skyBehind) {
    float3 sunRadiance = push.lightRadiance.xyz;
    // Vanilla shades cloud faces by orientation, not by a lighting model. Reproduce that: the face we
    // are looking at is the top when the ray travels downward onto it, the bottom when it travels up.
    float grazing = 1.0 - abs(dir.y);            // 1 looking along the deck, 0 straight up/down
    float faceLight = h.fromBelow ? 0.52 : 1.0;  // vanilla's bottom face is markedly darker
    faceLight = lerp(faceLight, 0.78, grazing);  // side faces sit between the two
    float3 albedo = push.cloudColor.xyz;
    if (dot(albedo, albedo) < 1.0e-6) albedo = CLOUD_ALBEDO;
    float3 lit = albedo * CLOUD_INV_PI * sunRadiance * faceLight;
    // The classic deck is opaque, so it admits only a little sky fill — enough to keep it from going
    // black at night, when sunRadiance is near zero.
    return lit + skyBehind * 0.45;
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

/**
 * 3D density inside the slab, per style.
 *
 * CLASSIC is a box: the density is the quantised cell coverage, constant through the whole thickness
 * with only a hair of taper at the very top and bottom faces. That is deliberately NOT billowy — it is
 * what makes the marched result read as vanilla's solid cuboid clouds rather than a soft blob, and it
 * is why the classic style still looks like Minecraft once it has real height.
 *
 * VOLUMETRIC is cumulus. Three things do the work, and the previous version had none of them, which is
 * why it looked like a thin sheet:
 *   * a CAULIFLOWER height profile — the cloud bulges outward toward its middle and rounds off at the
 *     top, instead of tapering symmetrically like a lens. Real cumulus has a flat-ish base and a
 *     billowing crown, so the profile is asymmetric on purpose;
 *   * DOMAIN WARPING — the sample position is displaced by a low-frequency noise before the detail
 *     octaves are read, which turns straight, gridded edges into curling, rounded lobes. This is the
 *     single biggest contributor to a cloud reading as "puffy" rather than "noisy";
 *   * a coverage BOOST toward the core, so the middle of a cloud is genuinely opaque. A field that only
 *     ever reaches ~0.5 density can never look thick no matter how deep the slab is.
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

    // ---- Volumetric cumulus.
    //
    // The goal here is HEAPED cloud — thick, wide, vertically developed, the way real cumulus and
    // Photon-style shader clouds look. The previous version was flat for a measurable reason: its lobes
    // were ~24 blocks across but only ~14 blocks of real density tall (a 1.7:1 layer), because the
    // profile faded out over the top 65% of the slab. Real cumulus is roughly 1:1 to 1:2 width:height.
    // Three changes fix that, and they are all about the aspect ratio rather than about adding detail:
    //   * the body now holds full density across most of the slab and only rounds off at the very top,
    //     so the cloud actually USES the height the thickness slider gives it;
    //   * the horizontal field is sampled at a larger scale, making lobes broader and puffier instead
    //     of small and busy — width and height grow together, so it reads as heaped, not stretched;
    //   * erosion is concentrated at the extreme top and bottom, leaving the middle solid, which is
    //     what gives a cloud a dense core with a cauliflower crown rather than uniform fluff.
    float base = cloudCoverageField(samplePos * CLOUD_VOLUMETRIC_SCALE);
    float threshold = 1.0 - clamp(push.clouds.x, 0.0, 1.0);
    float coverage = smoothstep(threshold, threshold + CLOUD_EDGE_SOFTNESS, base);
    if (coverage <= 0.0) {
        return 0.0;
    }

    // Vertical development. A cumulus has a hard flat base (condensation level), a tall body that stays
    // dense, and a rounded crown. The top fade starts high (0.62) so the body occupies most of the slab
    // instead of tapering away from the middle — this is the single change that makes the cloud thick.
    // Taller clouds also get to be taller: coverage scales how far up the crown reaches, so dense
    // regions billow upward into towers while thin edges stay low and flat, exactly like the real sky.
    float towerTop = lerp(0.35, 1.0, coverage);
    float bottom = smoothstep(0.0, 0.10, hf);
    float top = 1.0 - smoothstep(towerTop * 0.62, towerTop, hf);
    float profile = clamp(bottom * top, 0.0, 1.0);

    // BULGE. Without this the cloud is a vertical extrusion with straight sides — tall, but reading as a
    // wall rather than as heaped cloud. Real cumulus is widest around its lower-middle and narrows
    // toward both the base and the crown, so the coverage THRESHOLD is relaxed there and tightened at
    // the extremes: the same cloud grows sideways in its belly and pulls in at top and bottom. That
    // rounded silhouette is most of what makes the Photon-style clouds look voluminous.
    float belly = 1.0 - abs(hf - 0.42) * 2.0;
    coverage = clamp(coverage + smoothstep(0.0, 1.0, max(belly, 0.0)) * CLOUD_BULGE - CLOUD_BULGE * 0.35,
                     0.0, 1.0);
    if (coverage <= 0.0) {
        return 0.0;
    }

    // Domain warp, amplitude growing with height: bases stay flat, crowns curl into rounded lobes.
    float2 warpUv = samplePos * CLOUD_VOLUMETRIC_SCALE / (CLOUD_CELL_BLOCKS * CLOUD_WARP_DIV);
    float2 warp = float2(cloudNoise(warpUv), cloudNoise(warpUv + float2(41.0, 17.0))) - 0.5;
    float2 warped = samplePos * CLOUD_VOLUMETRIC_SCALE
            + warp * CLOUD_CELL_BLOCKS * (1.0 + 3.0 * hf);

    // Billow detail: inverted noise (1 - |2n-1|) gives rounded cellular lobes rather than a cloudy blur,
    // which is what reads as cauliflower. Scales chosen so the lobes are a fraction of a cloud's width,
    // not a fraction of a cell — small lobes on a big cloud is exactly the cumulus look.
    float d1 = cloudNoise(warped / (CLOUD_CELL_BLOCKS * CLOUD_BILLOW_DIV_COARSE));
    float d2 = cloudNoise(warped / (CLOUD_CELL_BLOCKS * CLOUD_BILLOW_DIV_FINE) + float2(19.0, 7.0));
    float billow = (1.0 - abs(d1 * 2.0 - 1.0)) * 0.7 + (1.0 - abs(d2 * 2.0 - 1.0)) * 0.3;

    // Erosion concentrated at the extremes: the crown breaks into lobes and the base frays, but the
    // middle of the cloud stays solid. Uniform erosion is what makes procedural clouds look like fog.
    float extremes = smoothstep(0.55, 1.0, hf) * 0.85 + smoothstep(0.18, 0.0, hf) * 0.5;
    float edge = 1.0 - coverage;
    float erosion = billow * (edge * 0.55 + extremes * 0.45);

    // Dense core: cumulus interiors are optically thick, and a field that peaks at ~0.5 can never look
    // like anything but haze no matter how deep the slab is.
    float density = coverage * (0.85 + 0.75 * coverage) - erosion;
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

    float thickness = max(push.cloudAnchor.z, 1.0);
    float slabBottom = push.clouds.w - thickness * 0.5 - originRel.y;
    float slabTop = push.clouds.w + thickness * 0.5 - originRel.y;
    // Bug 1: the old code only faded the flat plane (cloudTrace); the march kept accumulating
    // in-scatter even when the deck was at the near plane, producing the bright ~12-block
    // horizontal band that followed the camera.
    {
        float halfThick = max(thickness, 0.5) * 0.5;
        float deckRel = push.clouds.w - originRel.y;
        float cross = smoothstep(halfThick * 0.5, halfThick * 1.5, abs(deckRel));
        if (cross <= 0.0) {
            return result;
        }
    }

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
    float cosT = dot(dir, push.lightDir.xyz);
    float phase = cloudPhase(cosT);
    float opacity = clamp(push.clouds.y, 0.0, 1.0);
    // Scale the step count to the distance actually being marched, so a thick deck is sampled as finely
    // as a thin one instead of just taking longer strides. Clamped both ways: never coarser than the
    // base count, never more expensive than the cap.
    int stepCap = highQuality ? CLOUD_MARCH_STEPS_MAX : CLOUD_MARCH_STEPS_CHEAP_MAX;
    marchSteps = clamp(int((t1 - t0) / CLOUD_TARGET_STEP_BLOCKS), marchSteps, stepCap);
    float stepLen = (t1 - t0) / float(marchSteps);
    bool classic = cloudStyle(push) == CLOUD_STYLE_CLASSIC;
    // Classic clouds are opaque boxes, not haze: they need a much higher extinction so a box saturates
    // within its own thickness instead of reading as translucent fog. Vanilla's clouds you cannot see
    // through, and that is the property being reproduced.
    // Extinction is normalised by the slab depth: a 100-block bank and a 10-block sheet reach the same
    // optical depth straight down, so THICKNESS controls shape and OPACITY controls see-through, with
    // no cross-talk. opacity is deliberately NOT folded in here — see the cap after the march.
    float sigma = CLOUD_EXTINCTION * (classic ? CLOUD_CLASSIC_EXTINCTION_SCALE : 1.0)
            * (CLOUD_REFERENCE_THICKNESS / max(thickness, 1.0)) * fade;
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
            inScatter = CLOUD_ALBEDO * CLOUD_INV_PI
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
        return cloudClassicAnalytic(push, originRel, dir, maxDistance, ambient, highQuality);
    }
    // A deck with real thickness is a VOLUME for both styles — that is what makes the classic clouds
    // actual boxes you can fly between rather than a decal. Only a thickness of (near) zero still takes
    // the flat plane path, which is what the thickness slider at 0% asks for.
    if (push.cloudAnchor.z > CLOUD_FLAT_EPSILON) {
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
    // Premultiplied, so `background * transmittance + scatter` reproduces the lerp exactly.
    result.scatter = cloudRadianceClassic(push, h, dir, ambient) * alpha;
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
