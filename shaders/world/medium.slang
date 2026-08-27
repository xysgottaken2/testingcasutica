// Participating media: the tint-to-extinction mappings, the atmospheric haze's directional shaping,
// and the depth-2 medium stack the dielectric interface pushes and pops. Depends on core + math only.

// Per-channel Beer–Lambert extinction from a water body's biome tint (carried in payload.albedo for
// water hits, or worldPush.waterParams.xyz for the camera's own biome when starting submerged). A blue ocean
// tint (low red) absorbs red fastest → bluer with depth; swamp green-brown shifts the hue. The floor
// keeps even a white-tinted body very slightly absorbing so deep water never reads as clear vacuum.

import world_common;
import world_core;
import math;

public static const float WATER_DENSITY = 0.1;
public static const float3 WATER_ABSORB_FLOOR = float3(0.015, 0.010, 0.008);
// Extra per-block extinction the water-opacity option adds at its maximum (slider 1). At 4.0 one
// block of water transmits exp(-4) ~= 1.8% - effectively an opaque dark mirror; the low end of the
// slider gives gentle per-block dimming (exp(-0.4) ~= 67% at 0.1).
public static const float WATER_OPACITY_EXTINCTION_MAX = 4.0;
public float3 waterExtinctionBase(float3 tint) {
    return WATER_ABSORB_FLOOR + WATER_DENSITY * (float3(1.0, 1.0, 1.0) - clamp(tint, 0.0, 1.0));
}

public float3 waterExtinction(float3 tint) {
    float3 base = waterExtinctionBase(tint);
    // When the eye is inside water, keep the medium's own extinction at its natural
    // clarity. The opacity slider is meant to dim the transmitted lobe seen THROUGH
    // water from the outside (fixing the DLSS-RR halo), not to make the water you
    // are swimming in opaque black. At 100% the extra is 4.0 per block -> exp(-40)
    // over 10 blocks would be ~4e-18, i.e. a black fog when submerged.
    if (cameraSubmerged()) {
        return base;
    }
    float extra = worldPush.waterOpacity.x * WATER_OPACITY_EXTINCTION_MAX;
    return base + float3(extra, extra, extra);
}

// A non-water dielectric's tint is a filter over one block of travel rather than a biome water colour, so
// it maps to extinction by inverting Beer-Lambert over that reference distance: transmittance t after one
// block means sigma = -ln(t). `transmission` scales that transmittance, so it keeps the sense the
// material's authored factor has everywhere else — 1 passes the tint through unchanged, 0 is opaque.
// Clamped away from zero so a fully saturated texel stays finite instead of producing an infinite sigma.
public static const float VOLUME_TINT_REFERENCE_DISTANCE = 1.0; // blocks
public float3 volumeExtinction(float3 tint, float transmission) {
    float3 blockTransmittance = clamp(clamp(tint, 0.0, 1.0) * clamp(transmission, 0.0, 1.0),
            1.0e-3, 1.0);
    return -log(blockTransmittance) / VOLUME_TINT_REFERENCE_DISTANCE;
}

// ---- Masked atmospheric fog (worldPush.ambientFog).
//
// The parameters still describe a homogeneous emissive medium: over effective depth d, radiance keeps
// exp(-sigma*d) and picks up the fog colour over the part it lost. The caller supplies d from the
// per-pixel primary-depth/sky-exposure texture, rather than integrating this at every stochastic path
// segment. That makes the medium selective (covered caves/interiors have d=0), preserves far-field
// skyboxes, and keeps fog stable around split water/glass branches.
//
// Density (w) is per block. A zero density or masked depth is the exact identity operation.
public struct AmbientFog {
    public float3 inScatter;   // radiance added over the segment
    public float3 transmittance; // what survives of the radiance coming from beyond it
};

// ---- Directional shaping of that medium (the part the cloud march had and this did not).
//
// WHY THIS IS NOT A MARCH. It is tempting to "just use the cloud fog here", but marching a
// HOMOGENEOUS medium is provably the same computation that is already closed-form below. cloudMarch
// accumulates `scatter += transmittance * S * (1 - exp(-sigma*stepLen)); transmittance *= ...`, which
// for a constant S telescopes to exactly `S * (1 - exp(-sigma*total))` — the two lines in
// evalAmbientFog. So a haze march would cost CLOUD_MARCH_STEPS x CLOUD_LIGHT_STEPS per pixel per
// bounce and return the number we already have.
//
// What the cloud march buys that the flat haze lacked is not the integration, it is that each sample
// is SHADED: a Henyey-Greenstein phase against the light, and a tint from the light's own colour. For
// a homogeneous medium both of those are constant along the ray, so they factor straight out of the
// integral. Evaluating them once per pixel here gives the whole angular response for the price of two
// matrix multiplies and one phase evaluation.
//
// The shape multiplies the AUTHORED ambientFog.xyz rather than replacing it, so:
//   * the Java side still owns how much haze each dimension has and what its base colour is;
//   * a dimension with no light (Nether/End push a zero lightRadiance — see RtComposite.skyPush)
//     returns exactly 1.0 and keeps its authored flat haze bit-for-bit;
//   * the phase is mean-1 over the sphere, so this redistributes brightness and cannot quietly add
//     energy the exposure pass then has to absorb.

// Aerosol anisotropy. Clouds use 0.72 for water droplets; a dry haze is a broad Mie scatterer, so the
// lobe is deliberately wider. A tight one puts a hard bright disc around the sun instead of the soft
// sky-wide glow that reads as atmosphere.
public static const float HAZE_HG_G = 0.35;
public static const float HAZE_HG_BACK = -0.25;      // weak backward lobe, so the anti-sun side is not flat
public static const float HAZE_FORWARD_WEIGHT = 0.8; // forward/back lobe mix
// Blend between the authored flat haze (0, the exact old behaviour) and the fully directional one (1).
public static const float HAZE_PHASE_STRENGTH = 0.85;
// How strongly the light's own hue tints the haze. At noon lightRadiance is near-white so this does
// almost nothing; at sunset it is deep orange, which is what turns the horizon gold.
public static const float HAZE_TINT_STRENGTH = 0.6;
// lightRadiance magnitude treated as "the sun is fully up". The Overworld sun peaks around 21
// (RtComposite.skyPush sunPeak) and the moon around 0.2, so this saturates on any real daylight while
// moonlight stays near the flat haze — a moonlit night should not get a sun glow.
public static const float HAZE_SUN_FULL_RADIANCE = 1.5;
// Floor on the scalar shape, so looking directly away from the sun dims the haze but can never punch a
// hole in the distance or hand a negative in-scatter to the composite.
public static const float HAZE_MIN_SHAPE = 0.05;

/**
 * Per-pixel multiplier on the authored in-scatter, from the direction this pixel looks in.
 *
 * @param push     the frame's world data (light direction and radiance).
 * @param viewDir  the camera ray direction of the pixel whose fog depth was captured.
 */
public float3 hazeScatterShape(WorldPush push, float3 viewDir) {
    float3 flat = float3(1.0, 1.0, 1.0);
    float sunStrength = clamp(luminance(push.lightRadiance.xyz) / HAZE_SUN_FULL_RADIANCE, 0.0, 1.0);
    if (sunStrength <= 0.0) {
        return flat; // no directional light: authored flat haze, unchanged
    }
    float3 lightDir = push.lightDir.xyz;
    float lightLen = length(lightDir);
    if (lightLen < 1.0e-4) {
        return flat;
    }
    float cosT = dot(viewDir, lightDir / lightLen);
    // hg() is 4*pi-normalised (it integrates to 1 over the sphere), so scaling by 4*pi makes this term
    // mean-1 over all directions: the authored brightness is redistributed, not amplified on average.
    float phase = lerp(hg(cosT, HAZE_HG_BACK), hg(cosT, HAZE_HG_G), HAZE_FORWARD_WEIGHT) * (4.0 * PI);
    float amount = HAZE_PHASE_STRENGTH * sunStrength;
    float shape = max(1.0 + amount * (phase - 1.0), HAZE_MIN_SHAPE);
    // Normalising the light by its brightest channel gives its HUE with no hand-authored sunset ramp:
    // lightRadiance already carries the atmosphere's own Rayleigh+Mie transmittance curve.
    float maxChannel = max(push.lightRadiance.r, max(push.lightRadiance.g, push.lightRadiance.b));
    float3 tint = push.lightRadiance.xyz / max(maxChannel, 1.0e-5);
    return shape * lerp(flat, tint, HAZE_TINT_STRENGTH * sunStrength);
}

public AmbientFog evalAmbientFog(float4 ambientFog, float distance, float3 scatterShape) {
    AmbientFog result;
    result.inScatter = float3(0.0, 0.0, 0.0);
    result.transmittance = float3(1.0, 1.0, 1.0);
    float density = ambientFog.w;
    if (density <= 0.0 || distance <= 0.0) {
        return result;
    }
    // Clamp the optical depth. exp(-huge) is zero either way, but bounding the exponent keeps the
    // result out of the denormal range on a very long segment (a far shadow/guide ray can report
    // thousands of blocks), which some drivers handle at a large penalty.
    float t = exp(-min(density * distance, 32.0));
    result.transmittance = float3(t, t, t);
    result.inScatter = ambientFog.xyz * scatterShape * (1.0 - t);
    return result;
}

// ---- Participating medium the path is currently inside.
//
// Refraction needs the RELATIVE index across an interface, so the renderer has to know what it is
// travelling through, not just what it is hitting. `ior` drives Snell/Fresnel; `extinction` drives the
// per-segment Beer-Lambert attenuation.
//
// The stack is depth 2 (current + the one it will return to) held in named fields, NOT an array. A
// dynamically indexed local array lands in scratch memory, and this raygen is already register-bound —
// paying an occupancy hit for nesting that Minecraft does not produce would be a bad trade. Depth 2
// covers air->water->glass and air->glass->water, which is the realistic worst case; anything deeper
// degrades to air on the way out, and because `entering` is re-derived per face from geometry rather
// than toggled, the path re-synchronises at the next crossing instead of staying corrupted.
public struct Medium {
    public float ior;
    public float3 extinction;
    public bool water; // drives the wave-refraction caustic on submerged receivers; nothing else is water-specific
};

public struct MediumStack {
    public Medium current;
    public Medium outer;
};

public Medium airMedium() {
    Medium m;
    m.ior = 1.0;
    m.extinction = float3(0.0, 0.0, 0.0);
    m.water = false;
    return m;
}

public MediumStack makeMediumStack(Medium start) {
    MediumStack s;
    s.current = start;
    s.outer = airMedium();
    return s;
}

public void mediumPush(inout MediumStack stack, Medium entered) {
    stack.outer = stack.current;
    stack.current = entered;
}

public void mediumPop(inout MediumStack stack) {
    stack.current = stack.outer;
    stack.outer = airMedium();
}

// Water's tint is a biome colour whose absorption is calibrated per block of depth; any other volume
// dielectric's tint is a filter over a reference block of travel. Both end up as per-channel extinction.
public Medium makeDielectricMedium(bool isWater, float ior, float3 tint, float transmission) {
    Medium m;
    m.ior = ior;
    m.extinction = isWater ? waterExtinction(tint) : volumeExtinction(tint, transmission);
    m.water = isWater;
    return m;
}
