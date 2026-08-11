// Participating media: the tint-to-extinction mappings and the depth-2 medium stack the dielectric
// interface pushes and pops. Depends on core only.

// Per-channel Beer–Lambert extinction from a water body's biome tint (carried in payload.albedo for
// water hits, or worldPush.waterParams.xyz for the camera's own biome when starting submerged). A blue ocean
// tint (low red) absorbs red fastest → bluer with depth; swamp green-brown shifts the hue. The floor
// keeps even a white-tinted body very slightly absorbing so deep water never reads as clear vacuum.

import world_common;
import world_core;
import math;
import trace;

public static const float WATER_DENSITY = 0.1;
public static const float3 WATER_ABSORB_FLOOR = float3(0.015, 0.010, 0.008);
public float3 waterExtinction(float3 tint) {
    return WATER_ABSORB_FLOOR + WATER_DENSITY * (float3(1.0, 1.0, 1.0) - clamp(tint, 0.0, 1.0));
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

// ---- Global ambient fog (worldPush.ambientFog): a uniform, self-illuminated participating medium
// filling the whole dimension, on top of whatever volume dielectric the path happens to be inside.
//
// This is what gives the Nether its deep, enclosing haze and the End its faint void dust, and what
// makes distant terrain wash out in heavy rain. It is a single-scatter, homogeneous approximation:
// over a segment of length d the path keeps exp(-sigma*d) of its radiance and picks up the fog's own
// emission over the part it lost. That is exact for a uniform emissive medium, costs one exp per
// segment, and — unlike a screen-space depth fade — automatically applies to reflections, refractions
// and every indirect bounce, because it lives in the path integral rather than at the display seam.
//
// density (w) is per block and zero in the clear Overworld, where the whole thing compiles down to one
// comparison per segment.
public struct AmbientFog {
    public float3 inScatter;   // radiance added over the segment
    public float3 transmittance; // what survives of the radiance coming from beyond it
};

// `mask` (0..1) scales the DENSITY, not the result: see the masked-fog block below for why that is
// the one place it belongs. mask == 1 reproduces the unmasked integral exactly, bit for bit, so the
// masked path is a strict generalisation of the uniform one rather than a second fog model.
public AmbientFog evalAmbientFog(float4 ambientFog, float distance, float mask) {
    AmbientFog result;
    result.inScatter = float3(0.0, 0.0, 0.0);
    result.transmittance = float3(1.0, 1.0, 1.0);
    float density = ambientFog.w * clamp(mask, 0.0, 1.0);
    if (density <= 0.0 || distance <= 0.0) {
        return result;
    }
    // Clamp the optical depth. exp(-huge) is zero either way, but bounding the exponent keeps the
    // result out of the denormal range on a very long segment (a far shadow/guide ray can report
    // thousands of blocks), which some drivers handle at a large penalty.
    float t = exp(-min(density * distance, 32.0));
    result.transmittance = float3(t, t, t);
    result.inScatter = ambientFog.xyz * (1.0 - t);
    return result;
}

public AmbientFog evalAmbientFog(float4 ambientFog, float distance) {
    return evalAmbientFog(ambientFog, distance, 1.0);
}

// ---- Masked fog (FEATURE_MASKED_FOG).
//
// The fog above is uniform: every segment of every path picks up the same haze, whether it crossed
// open air or the inside of a mountain. Outdoors that is what the haze is for. Underground it is the
// bug: a ray crossing sixty blocks of pitch-black cave corridor collects sixty blocks' worth of
// daylight-coloured in-scatter, so caves fill with a flat luminous wash that has no source in the
// scene. It reads worst exactly where it was reported — deep caves and other low-exposure areas,
// where auto-exposure then opens up on that wash and lifts the whole shot. Outside, where the air
// really is open to the sky, nothing about it looks wrong, which is why it went unnoticed.
//
// The physical statement is short: this medium's in-scatter is the SKY reflected off the air. Air
// the sky cannot reach does not glow. So the fog is masked by an estimate of how open to the sky the
// segment's air is, and the mask multiplies the DENSITY rather than the colour:
//
//   * masking the colour alone would leave the extinction behind — enclosed space would stop glowing
//     but keep dimming with distance, which is a different artefact, not a fix;
//   * masking the density scales in-scatter and extinction together and coherently, and mask == 1
//     leaves the open-air look untouched to the last bit.
//
// The estimate is one occlusion probe toward the sky, from a point sampled ALONG the segment by the
// in-scatter distribution itself (see fogSkyAccess), and it is computed at most once per path — so
// the whole feature costs at most one shadow-class ray per sample, on top of the several the path
// already traces. It reuses `visibility`, so a glass roof or a leaf canopy passes its own partial
// transmittance through and lets the air under it stay partly lit, instead of being a binary lid.
//
// SCOPE: the Overworld only, gated by maskedFogEnabled() in world_core. The Nether's haze and the
// End's void dust are not sky-driven — they are self-illuminated dimension media (a Nether cavern is
// enclosed by definition, and its haze is most of the ambient light in there), so masking them by
// sky access would delete the look on purpose. Only the Overworld's distance haze claims to be the
// sky, and only it is masked.

// How far the probe looks for a lid. Bounded on purpose: the question is "is something directly
// overhead", not "where does this ray end", and a bounded probe is what keeps the cost flat. Past
// this the air counts as open, which is the right answer for anything but a very tall shaft.
public static const float FOG_MASK_PROBE_DISTANCE = 48.0;
// Half-extent of the probe cone about +Y, as a tangent (~20°). Straight up alone would give a hard
// binary silhouette of the ceiling; a narrow cone turns cave mouths and overhang edges into a soft
// gradient the temporal filter integrates, while staying tight enough that a wall standing beside
// open air never darkens the haze in front of it.
public static const float FOG_MASK_CONE_TANGENT = 0.36;
// Below this optical depth the segment's fog is worth less than the ray it would cost to mask it
// (2% of the fog colour at most), so it keeps the uniform value and spends nothing.
public static const float FOG_MASK_MIN_OPTICAL_DEPTH = 0.02;

// Openness of the air along one segment, in 0..1.
//
// The in-scatter is distributed along the segment as exp(-sigma*t)*sigma*dt, so the probe point is
// drawn from exactly that density by inverting its CDF rather than from the midpoint or the end.
// That is the textbook single-scatter distance sample, and it has the property this needs: the
// sample lands where the fog actually contributes, so averaging over SPP and frames converges to the
// segment's true mean openness instead of to whatever one fixed point happened to see. Looking out
// of a cave mouth therefore cross-fades over the segment instead of snapping.
public float fogSkyAccess(float3 origin, float3 direction, float distance, float density,
                          inout uint seed) {
    float safeDensity = max(density, 1.0e-6);
    float opticalDepth = min(safeDensity * distance, 32.0);
    // t = -ln(1 - u * (1 - e^-tau)) / sigma, clamped into the segment for the u -> 1 tail.
    float u = rndf(seed);
    float t = -log(max(1.0 - u * (1.0 - exp(-opticalDepth)), 1.0e-6)) / safeDensity;
    // Keep the probe point strictly INSIDE the segment. The far end is the surface this segment just
    // hit, and a sample landing on it would have the probe re-hit that same triangle and report the
    // air as sealed — darkening the haze in front of every lit surface, which is the opposite of the
    // artefact being fixed. The near end is already offset off the previous surface by the caller.
    float3 probeOrigin = origin + direction * clamp(t, 0.0, max(distance - SURF_BIAS, 0.0));

    // Uniform disc in the cone's tangent plane -> a direction cone about +Y.
    float radius = FOG_MASK_CONE_TANGENT * sqrt(rndf(seed));
    float phi = 6.2831853 * rndf(seed);
    float3 probeDir = normalize(float3(radius * cos(phi), 1.0, radius * sin(phi)));

    // Shadow-class traversal (first hit ends the search, no closest-hit): the cheapest ray the
    // pipeline can issue, and the one that already knows how to let cutout and tinted glass through.
    float3 transmittance = visibility(probeOrigin, probeDir, FOG_MASK_PROBE_DISTANCE).transmittance;
    return clamp(max(transmittance.r, max(transmittance.g, transmittance.b)), 0.0, 1.0);
}

// Per-path cached sky-access mask. The first segment whose fog is worth masking pays for the probe
// and every later segment of that path reuses the answer: openness is a low-frequency property of a
// neighbourhood, while the segments after the first carry a fraction of the throughput, so a second
// probe would buy a correction nobody can see at the price of the feature's entire ray budget.
//
// Segments that are not worth masking return 1 WITHOUT filling the cache, so a negligible first
// segment cannot pin a whole path to the unmasked value.
public float ambientFogMask(float4 ambientFog, float3 origin, float3 direction, float distance,
                            inout float cachedMask, inout bool cachedValid, inout uint seed) {
    if (cachedValid) {
        return cachedMask;
    }
    float density = ambientFog.w;
    if (density <= 0.0 || distance <= 0.0 || density * distance < FOG_MASK_MIN_OPTICAL_DEPTH) {
        return 1.0;
    }
    float mask = fogSkyAccess(origin, direction, distance, density, seed);
    cachedMask = mask;
    cachedValid = true;
    return mask;
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
