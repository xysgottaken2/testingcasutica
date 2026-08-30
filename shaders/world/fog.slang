// World-space volumetric fog — an analytic exponential height fog integrated in closed form
// along every radiance segment. Depends on common only (world.rgen imports it next to clouds).
//
// WORLD SPACE, NOT SCREEN SPACE. The density is a function of the ray's world position, not of
// its screen distance (WorldPush.fogParams): the fog is a BANK that sits at the base height —
// densest there, thinning exponentially with altitude above it (fogParams.z), and dissipating
// fast BELOW it, which is what keeps caves and mine shafts (underground air) fog-free while a
// valley at bank level keeps its haze:
//
//     sigma(h) = A * exp(-k_up * h)   h >= 0      (above the base; k_up = fogParams.z)
//     sigma(h) = A * exp( k_dn * h)   h <  0      (below the base; k_dn = FOG_UNDERBASE_FALLOFF)
//
// with h = height above the base (blocks). Every segment integral is BOUNDED by the distance
// to the nearest scene hit (or the sky), exactly like the cloud deck, so the fog cannot pass
// through blocks — a segment stops at the first surface it meets, and the fog beyond that
// surface is never integrated. A mountain shows only the fog in front of it, the valley behind
// it shows straight through, and a cave only ever carries the thin layer of air between the
// eye and its nearest wall.
//
// The fog only exists in AIR: a segment travelling through water or any other dielectric
// volume is not crossing the fog bank (water owns its own Beer–Lambert extinction). Call sites
// gate on the segment medium's index of refraction (FOG_AIR_IOR_MAX) before applying it.
//
// fogParams lanes: x = A, y = base height (camera-relative), z = k_up, w = in-scatter strength.
// fogParams2 lanes: x = god-ray scale (multiplier on lightRadiance * HG phase), rest reserved.

import world_common;

// Below this |dir.y| a segment is treated as horizontal (its density is then constant along it).
static const float FOG_HORIZONTAL_EPS = 1.0e-4;
// Optical depth past which the transmittance is zero in any usable precision (exp(-60) ~= 8.7e-27).
static const float FOG_TAU_CAP = 60.0;
// Analytic range for rays that escape to the sky. The height-fog integral saturates along any ray
// (the density is constant or decaying, never growing without bound), so a large finite distance
// is exact enough: past it the missing transmittance is below exp(-FOG_TAU_CAP).
public static const float FOG_SKY_DISTANCE = 4096.0;
// The fog bank dissipates below the base much faster than it thins above it: a few blocks under
// the base level the density is already a small fraction of A, so caves and deep valleys stay
// essentially clear while the bank hugs the base. Fixed (not a slider): "no fog in caves" is a
// behaviour, not a taste.
static const float FOG_UNDERBASE_FALLOFF = 0.3;
// Medium index of refraction that counts as AIR: airMedium() is exactly 1.0; water is 1.333 and
// glass/ice above that. A segment in any denser medium is not inside the fog bank.
public static const float FOG_AIR_IOR_MAX = 1.001;
// Slightly cool white: the in-scatter is scattered skylight, and this scene's skylight is cool.
static const float3 FOG_TINT = float3(0.96, 0.99, 1.05);
// In-scatter brightness relative to the same ambient field the cloud deck shades with (see
// cloudSkyAmbient). The fog scatters the sky, which is what makes it blend into the horizon
// instead of floating as an independent white veil.
static const float FOG_SCATTER_SCALE = 1.4;
// God rays: forward-scattering anisotropy of fog droplets (Henyey–Greenstein g). 0.75 keeps a
// tight sun/moon-centred lobe, so the bright shafts only appear when looking TOWARD the light.
static const float FOG_HG_G = 0.75;
static const float FOG_PI = 3.14159265359;

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
 * (rising, falling, horizontal) have closed forms for the two-sided profile, so the fog costs a
 * handful of ALU ops and no march regardless of distance. Every exponential is bounded by its
 * argument staying <= 1 or being capped, so a pathological push value can only saturate to full
 * fog, never overflow to NaN.
 */
public float fogOpticalDepth(WorldPush push, float3 originRel, float3 dir, float tMax) {
    float A = push.fogParams.x;
    if (A <= 0.0 || tMax <= 0.0) {
        return 0.0;
    }
    float kUp = max(push.fogParams.z, 1.0e-5);
    float kDn = FOG_UNDERBASE_FALLOFF;
    float y0 = fogHeightAboveBase(push, originRel);
    float dy = dir.y;
    float tau;
    if (dy > FOG_HORIZONTAL_EPS) {
        // Rising.
        if (y0 >= 0.0) {
            // Above the base for the whole segment: sigma decays from A e^{-kUp y0}.
            tau = (A / (kUp * dy)) * exp(-kUp * y0) * (1.0 - exp(-kUp * dy * tMax));
        } else {
            // Below the base until the ray crosses the base height.
            float tCross = -y0 / dy;
            if (tCross >= tMax) {
                // Below the base the whole way: sigma GROWS from A e^{kDn y0} toward A.
                // (Both exponent arguments stay <= 0, so nothing overflows.)
                tau = (A / (kDn * dy)) * (exp(kDn * (y0 + dy * tMax)) - exp(kDn * y0));
            } else {
                // Below until tCross, above after. e^{kDn h} at the crossing is 1.
                tau = (A / (kDn * dy)) * (1.0 - exp(kDn * y0))
                     + (A / (kUp * dy)) * (1.0 - exp(-kUp * dy * (tMax - tCross)));
            }
        }
    } else if (dy < -FOG_HORIZONTAL_EPS) {
        // Falling.
        if (y0 <= 0.0) {
            // Below the base for the whole segment: sigma decays from A e^{kDn y0}.
            tau = (A / (kDn * (-dy))) * (exp(kDn * y0) - exp(kDn * (y0 + dy * tMax)));
        } else {
            float tCross = -y0 / dy; // > 0: where the ray descends through the base height
            if (tCross >= tMax) {
                // Above the base for the whole segment: sigma GROWS from A e^{-kUp y0} toward A.
                float range = kUp * (-dy) * tMax;
                if (range > 25.0) {
                    tau = FOG_TAU_CAP;
                } else {
                    tau = (A / (kUp * (-dy))) * exp(-kUp * y0) * (exp(range) - 1.0);
                }
            } else {
                // Above until tCross, below after. e^{-kUp h} at the crossing is 1.
                tau = (A / (kUp * (-dy))) * (1.0 - exp(-kUp * y0))
                     + (A / (kDn * (-dy))) * (1.0 - exp(kDn * (y0 + dy * tMax)));
            }
        }
    } else {
        // Horizontal: the density is constant along the segment.
        tau = A * exp(-(y0 >= 0.0 ? kUp : kDn) * abs(y0)) * tMax;
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

// Single-lobe Henyey–Greenstein phase: the forward-scattering lobe that makes god rays.
static float fogHGPhase(float cosTheta) {
    float g = FOG_HG_G;
    float g2 = g * g;
    float denom = 1.0 + g2 - 2.0 * g * clamp(cosTheta, -1.0, 1.0);
    return (1.0 - g2) / (4.0 * FOG_PI * sqrt(denom) * denom);
}

/**
 * The in-scatter colour for a given view direction: the ambient skylight the droplets scatter —
 * the same ambient field the cloud deck shades with (sun * 0.10 + the dark ambient floor),
 * tinted cool and scaled by the pushed strength lane — plus the god-ray term: the celestial
 * body's own radiance forward-scattered into the eye through the fog (Henyey–Greenstein phase).
 *
 * <p>Because the phase depends on the view direction only (not on position), this colour is
 * CONSTANT along a ray segment, so the S * (1 - T) composite below stays exact. At night the
 * sun term is tiny, so the fog dims with the sky; with fogParams2.x at zero the god-ray term is
 * skipped entirely.
 */
public float3 fogInScatterColor(WorldPush push, float3 viewDir) {
    float3 ambient = push.lightRadiance.xyz * 0.10 + float3(0.012, 0.017, 0.028);
    float3 col = FOG_TINT * ambient * FOG_SCATTER_SCALE * push.fogParams.w;
    float godRay = max(push.fogParams2.x, 0.0);
    float3 lightDir = push.lightDir.xyz;
    float lightLen2 = dot(lightDir, lightDir);
    if (godRay > 0.0 && lightLen2 > 1.0e-12) {
        lightDir = lightDir * rsqrt(lightLen2);
        float phase = fogHGPhase(dot(viewDir, lightDir));
        col += push.lightRadiance.xyz * phase * godRay;
    }
    return col;
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
 *
 * NOTE: this function does NOT know the medium the segment is travelling through — call sites
 * gate it on FOG_AIR_IOR_MAX (the fog only exists in air, not inside water or glass volumes).
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
    // In-scatter at a single (view-dependent) colour: S * (1 - T) is EXACT for any density
    // profile — the profile changes where the light is lost, the colour is constant along the
    // segment by construction.
    result.scatter = fogInScatterColor(push, dir) * (1.0 - t);
    return result;
}
