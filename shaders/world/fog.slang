// Volumetric aerial fog: the existing distance haze re-authored as a real participating medium that is
// integrated along each path segment instead of being composited once in screen space. Because it lives
// in the path integral (exactly like the cloud deck), it is correct in reflections, refractions and
// indirect bounces, and a forward-scatter sun term gives the haze a soft glow toward the light.
//
// The density and in-scatter colour come from WorldPush.ambientFog — the same per-state haze the
// screen-space composite used (Overworld day/night/rain colours + a per-block sigma calibrated against
// the render distance). So switching the renderer over to this path-integrated form keeps the calibrated
// look while making it physical. The extra WorldPush.fogParams lane carries the march/fade distance, the
// overall strength (also an opacity ceiling), the sun-glow strength, and the density scale multiplier.
//
// Culling is done by the caller with a per-point sky-exposure factor (`exposure`, 0..1) passed into
// fogSegment: enclosed caves, rooms and overhangs read ~0, so the medium is scaled toward nothing there
// instead of fogging every enclosed air column. There is no screen-space depth mask or composite — the
// volumetric fog lives entirely in the path integral.
//
// Only world_common is imported. Like clouds.slang, this module must stay usable from passes that cannot
// pull in world_core (world.rmiss must not), so every entry point takes the WorldPush explicitly and no
// raygen bindings are declared here.

import world_common;

// Henyey-Greenstein phase anisotropy of the haze droplets. Forward scattering brightens the air toward
// the sun (a cheap "volumetric light" read); g closer to 1 would be a sharper, more Mie-like glow.
public static const float FOG_HG_G = 0.6;

// March budget. Fog is low frequency (the denoiser absorbs whatever the SPP leaves), so it is split into
// two tiers exactly like the clouds: FULL for the camera and specular/mirror bounces (what the player
// sees directly), CHEAP for diffuse indirect bounces, which get averaged over the hemisphere and denoised
// — resolving sample-level detail there is invisible in the result but multiplies the cost by bounce count.
public static const int   FOG_MARCH_STEPS = 16;
public static const int   FOG_MARCH_STEPS_CHEAP = 4;
// Upper bounds used when the step count is scaled to the path length (see fogSegment). A fixed step
// COUNT means a deep fog column silently gets coarser steps, which bands a smooth gradient; these cap the
// cost of scaling the count up to keep the sample spacing near FOG_TARGET_STEP_BLOCKS.
public static const int   FOG_MARCH_STEPS_MAX = 32;
public static const int   FOG_MARCH_STEPS_CHEAP_MAX = 8;
// Target distance between samples. Comfortably fine for a haze gradient while keeping the march short.
public static const float FOG_TARGET_STEP_BLOCKS = 24.0;

/** Result of a path-integrated fog march: premultiplied in-scatter and the surviving transmittance. */
public struct FogVolume {
    public float3 scatter;
    public float transmittance;
};

/** Single Henyey-Greenstein lobe, with 4*pi normalisation (integrates to 1 over the sphere). */
float fogPhase(float cosT) {
    float g = FOG_HG_G;
    float g2 = g * g;
    float d = 1.0 + g2 - 2.0 * g * cosT;
    return (1.0 - g2) / (4.0 * 3.14159265359 * max(d * sqrt(max(d, 1.0e-6)), 1.0e-4));
}

/**
 * Whether this frame draws volumetric fog on path segments. Gated on the feature bit and the Overworld
 * (the Nether and End have no fog — the old screen-space composite was removed), plus a non-zero density
 * source — so a mismatched push short-circuits to the exact pre-fog result (bit-identical output when the
 * feature is off).
 */
public bool fogVolumetricEnabled(WorldPush push) {
    // Strength (fogParams.y) and density (fogParams.w) are deliberately NOT gates: when either is 0 the
    // finished march is identity (scatter 0, transmittance 1), so "Volumetric Fog" on + Strength 0 = no
    // fog at all. Gating on them would be a second, separate enable path and contradict the toggle.
    return worldFeature(push, FEATURE_FOG_VOLUMETRIC)
        && push.dimension == DIMENSION_OVERWORLD
        && push.ambientFog.w > 0.0;
}

/**
 * Integrate the atmospheric medium along one ray segment, returning premultiplied in-scatter plus the
 * transmittance the background keeps. Callers composite with {@code col * transmittance + scatter}, the
 * identical two lines they already use for clouds, so fog inherits the correct behaviour over
 * reflections, refractions and indirect bounces for free.
 *
 * `maxDistance` is the distance to the nearest scene hit along the ray (or a large value when the ray
 * escapes to the sky). Fog is bounded by it and by {@code fogParams.x} (the fade distance), so a grazing
 * ray cannot integrate an unbounded air column and turn the whole horizon white — the same cap the cloud
 * deck uses for its slab crossings.
 *
 * `exposure` is the sky-exposure cull (0..1) the caller computes for this segment's air: 0 means the air
 * is enclosed (cave/room/overhang) and the fog is scaled to identity; 1 means fully open to the sky. It
 * multiplies the strength, so it is a clean blend rather than a hard toggle.
 *
 * The medium is homogeneous for now — sigma = ambientFog.w per block, the value the aerial haze was
 * calibrated against. That keeps the look familiar while the path placement supplies the physical
 * correctness. A height-falloff field could replace the single sigma sample below, but is intentionally
 * left out of this first iteration so the effect stays easy to reason about and debug.
 */
public FogVolume fogSegment(WorldPush push, float3 dir, float maxDistance, bool highQuality,
                            float exposure) {
    FogVolume result;
    result.scatter = float3(0.0, 0.0, 0.0);
    result.transmittance = 1.0;
    if (!fogVolumetricEnabled(push)) {
        return result;
    }
    // Density is the calibrated per-block sigma (ambientFog.w) scaled by the player's density multiplier
    // (fogParams.w). That multiplier is what the "Fog Density" slider drives, so the haze can be thinned
    // toward nothing or thickened beyond the calibrated day/night/rain value without touching the colour.
    float density = push.ambientFog.w * push.fogParams.w;
    // Sky-exposure cull and the strength ceiling both scale the finished march. exposure 0 = enclosed
    // air, so the fog collapses to identity without touching the march below.
    float strength = clamp(push.fogParams.y, 0.0, 1.0) * clamp(exposure, 0.0, 1.0);
    float fullDist = max(push.fogParams.x, 16.0);
    // Clip the segment to the far plane / full-saturation distance. A short segment keeps its fog; an
    // escaping ray is capped so fog never over-integrates toward an infinite horizon.
    float t1 = min(maxDistance, fullDist);
    if (t1 <= 0.0) {
        return result;
    }

    // Scale the step count to the distance actually marched so a short column is sampled as finely as a
    // long one, clamped both ways (never coarser than the base count, never more expensive than the cap).
    int marchSteps = highQuality ? FOG_MARCH_STEPS : FOG_MARCH_STEPS_CHEAP;
    int stepCap = highQuality ? FOG_MARCH_STEPS_MAX : FOG_MARCH_STEPS_CHEAP_MAX;
    marchSteps = clamp(int(t1 / FOG_TARGET_STEP_BLOCKS), marchSteps, stepCap);
    float stepLen = t1 / float(marchSteps);

    float sigma = density;
    float3 haze = push.ambientFog.xyz;
    float sunGlow = clamp(push.fogParams.z, 0.0, 1.0);
    float3 sunRadiance = push.lightRadiance.xyz;
    float phase = fogPhase(clamp(dot(dir, push.lightDir.xyz), -1.0, 1.0));

    for (int i = 0; i < marchSteps; i++) {
        // Single density evaluation point for now (homogeneous). A height-falloff or noise field would
        // replace `sigma` with a function of the marcher's position (dir * t here).
        float optical = sigma * stepLen;
        float sampleTransmittance = exp(-optical);
        // In-scatter: the haze's own colour (emissive, the calibrated day/night/rain fill), plus a
        // forward-scatter sun glow that brightens the air toward the light for a cheap volumetric read.
        // strength is NOT applied here; it is applied exactly once to the finished march below, so the
        // strength slider stays a single clean blend (no strength² on the sun glow).
        float3 inScatter = haze + sunGlow * phase * sunRadiance;
        result.scatter += result.transmittance * inScatter * (1.0 - sampleTransmittance);
        result.transmittance *= sampleTransmittance;
        if (result.transmittance < 0.01) {
            result.transmittance = 0.0;
            break; // fully saturated; further steps cannot contribute
        }
    }

    // Strength as a genuine upper bound on the fog's opacity, applied ONCE to the finished march. This
    // makes it exactly a blend between "no fog" and "this fog" at any distance and any view angle —
    // not a per-unit-length extinction that grew with path length (the same fix the cloud opacity uses).
    result.scatter *= strength;
    result.transmittance = 1.0 - (1.0 - result.transmittance) * strength;
    return result;
}
