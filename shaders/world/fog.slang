// World-space volumetric fog — a Frostbite-style exponential height fog integrated ANALYTICALLY
// along every radiance segment. Depends on common only (world.rgen imports it next to clouds).
//
// WORLD SPACE, NOT SCREEN SPACE. The density is a function of the ray's world position, not of
// its screen distance: a constant bank below the base height and an exponential falloff above it
// (WorldPush.fogParams). Every segment integral is BOUNDED by the distance to the nearest scene
// hit (or the sky), exactly like the cloud deck, so the fog cannot pass through blocks — a segment
// stops at the first surface it meets, and the fog beyond that surface is never integrated. A
// mountain shows only the fog in front of it, the valley behind it shows straight through, and a
// cave only ever carries the thin layer of air between the eye and its nearest wall.
//
// The one-sided density profile is
//     sigma(h) = A * exp(-k * max(0, h))        h = height above the base (blocks)
// so the fog accumulates toward the base and thins with altitude — physically, fog settles low and
// disperses upward. fogParams lanes: x = A, y = base height (camera-relative), z = k, w =
// in-scatter strength.

import world_common;

// Below this |dir.y| a segment is treated as horizontal (its density is then constant along it).
static const float FOG_HORIZONTAL_EPS = 1.0e-4;
// Optical depth past which the transmittance is zero in any usable precision (exp(-60) ~= 8.7e-27).
static const float FOG_TAU_CAP = 60.0;
// Analytic range for rays that escape to the sky. The height-fog integral saturates along any ray
// (the density is constant or decaying, never growing without bound), so a large finite distance
// is exact enough: past it the missing transmittance is below exp(-FOG_TAU_CAP).
public static const float FOG_SKY_DISTANCE = 4096.0;
// Slightly cool white: the in-scatter is scattered skylight, and this scene's skylight is cool.
static const float3 FOG_TINT = float3(0.96, 0.99, 1.05);
// In-scatter brightness relative to the same ambient field the cloud deck shades with (see
// cloudSkyAmbient). The fog scatters the sky, which is what makes it blend into the horizon
// instead of floating as an independent white veil.
static const float FOG_SCATTER_SCALE = 1.4;

/**
 * The fog only exists where the player can stand in it: Overworld (the other dimensions draw
 * closed skyboxes with no air to fog), never while the eye is inside a water medium (water owns
 * its own Beer–Lambert extinction), and never at zero density (the whole path is then free).
 */
public bool fogEnabled(WorldPush push) {
    return worldFeature(push, FEATURE_FOG)
            && push.dimension == DIMENSION_OVERWORLD
            && !worldFlag(push, WORLD_FLAG_SUBMERGED)
            && push.fogParams.x > 0.0;
}

// Height above the fog base at a camera-relative world position.
static float fogHeightAboveBase(WorldPush push, float3 posRel) {
    return posRel.y - push.fogParams.y;
}

/**
 * Exact integral of the density along o + d*t for t in [0, tMax]. All three ray orientations
 * (rising, falling, horizontal) have closed forms for the one-sided profile, so the fog costs a
 * handful of ALU ops and no march regardless of distance. The exponent is capped so a
 * pathological push value can only saturate to full fog, never overflow to NaN.
 */
public float fogOpticalDepth(WorldPush push, float3 originRel, float3 dir, float tMax) {
    float A = push.fogParams.x;
    if (A <= 0.0 || tMax <= 0.0) {
        return 0.0;
    }
    float k = max(push.fogParams.z, 1.0e-5);
    float y0 = fogHeightAboveBase(push, originRel);
    float dy = dir.y;
    float tau;
    if (dy > FOG_HORIZONTAL_EPS) {
        // Rising.
        if (y0 >= 0.0) {
            // Above the base for the whole segment: sigma decays from A e^{-k y0}.
            tau = (A / (k * dy)) * exp(-k * y0) * (1.0 - exp(-k * dy * tMax));
        } else {
            // Below the base (constant A) until the ray crosses the base height.
            float tCross = -y0 / dy;
            if (tCross >= tMax) {
                tau = A * tMax;
            } else {
                tau = A * tCross + (A / (k * dy)) * (1.0 - exp(-k * dy * (tMax - tCross)));
            }
        }
    } else if (dy < -FOG_HORIZONTAL_EPS) {
        // Falling.
        if (y0 <= 0.0) {
            // Below the base for the whole segment.
            tau = A * tMax;
        } else {
            float tCross = -y0 / dy; // > 0: where the ray descends through the base height
            if (tCross >= tMax) {
                // Above the base for the whole segment: sigma GROWS from A e^{-k y0} toward A.
                float range = k * (-dy) * tMax;
                if (range > 25.0) {
                    tau = FOG_TAU_CAP;
                } else {
                    tau = (A / (k * (-dy))) * exp(-k * y0) * (exp(range) - 1.0);
                }
            } else {
                // Above the base until tCross, then constant A. sigma(t) = A e^{-k y0} e^{k|dy| t}
                // there, and e^{k|dy| tCross} == e^{k y0}, so the crossing integral collapses to
                // (A/(k|dy|)) (1 - e^{-k y0}) — bounded by A/(k|dy|), no overflow.
                float e = min(k * y0, 25.0);
                tau = (A / (k * (-dy))) * (1.0 - exp(-e)) + A * (tMax - tCross);
            }
        }
    } else {
        // Horizontal: the density is constant along the segment.
        tau = A * exp(-k * max(y0, 0.0)) * tMax;
    }
    return min(tau, FOG_TAU_CAP);
}

/**
 * Direct-light (NEE) attenuation for the celestial body: the analytic depth over the sky range
 * from the shading point toward the light, exponentiated. 1.0 whenever the fog is off, so the
 * call site costs one flag test in the common case.
 */
public float fogSunAttenuation(WorldPush push, float3 originRel, float3 dir) {
    if (!fogEnabled(push)) {
        return 1.0;
    }
    return exp(-fogOpticalDepth(push, originRel, dir, FOG_SKY_DISTANCE));
}

public struct FogVolume {
    public float3 scatter;       // premultiplied in-scatter radiance
    public float transmittance;  // what the scene radiance keeps
};

// The in-scatter colour: the ambient skylight the droplets scatter — the same ambient field the
// cloud deck shades with (sun * 0.10 + the dark ambient floor), tinted cool and scaled by the
// pushed strength lane. At night the sun term is tiny, so the fog dims with the sky.
public float3 fogInScatterColor(WorldPush push) {
    float3 ambient = push.lightRadiance.xyz * 0.10 + float3(0.012, 0.017, 0.028);
    return FOG_TINT * ambient * FOG_SCATTER_SCALE * push.fogParams.w;
}

/**
 * Fog crossed along ONE ray segment, as premultiplied scattered radiance plus the transmittance
 * the background keeps — the same shape and the same two-line composite as CloudVolume
 * ({@code L += throughput * scatter; throughput *= transmittance;}), so the fog stays inside the
 * path integral and is correct over reflections, refractions and indirect bounces for free.
 *
 * `maxDistance` is the distance to the nearest scene hit along the ray (or a large value when the
 * ray escapes to the sky). Bounding the integral by it is what keeps the fog from passing through
 * blocks: geometry in front of the fog stops the segment, so no fog behind it is ever integrated.
 */
public FogVolume fogSegment(WorldPush push, float3 originRel, float3 dir, float maxDistance) {
    FogVolume result;
    result.scatter = float3(0.0, 0.0, 0.0);
    result.transmittance = 1.0;
    if (!fogEnabled(push)) {
        return result;
    }
    float tau = fogOpticalDepth(push, originRel, dir, max(0.0, maxDistance));
    if (tau <= 1.0e-5) {
        return result;
    }
    float t = exp(-tau);
    result.transmittance = t;
    // In-scatter at a single colour: S * (1 - T) is EXACT for any density profile — the profile
    // changes where the light is lost, the in-scatter colour is constant by construction.
    result.scatter = fogInScatterColor(push) * (1.0 - t);
    return result;
}
