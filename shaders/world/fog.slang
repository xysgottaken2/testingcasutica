// World-space volumetric fog + god rays.
//
// This is a REAL participating medium living in the world, not a screen-space depth fade. The fog
// occupies a height band anchored to world Y, and every radiance ray the tracer walks — the camera
// ray, specular reflections, refractions, diffuse bounces — integrates through it with the same
// two-line composite the cloud deck uses ({@code L += T * scatter; T *= transmittance;}). Because the
// integration lives inside the path integral rather than at a display seam, the fog is automatically
// correct in water reflections, through glass, and over indirect bounce light.
//
// THE BLOCK-OCCLUSION CONTRACT (the whole point of doing this in world space):
//   * the march is bounded by the distance to the nearest scene hit, so fog only exists in the open
//     air along a segment — it can never be painted "through" a mountain or a wall that the ray
//     actually hit;
//   * every in-scatter sample fires a real shadow ray toward the sun/moon. A fog voxel that terrain,
//     a tree canopy or a building roof shields from the light receives NO direct in-scatter — so the
//     haze behind a mountain ridge or inside a cave stays dark instead of glowing through the
//     occluder, and the gaps where the light does get through become visible god rays. Translucent
//     occluders tint the shaft through the shadow ray's own transmittance (stained glass paints the
//     beam), and the analytic cloud shadow is applied on top exactly like it is on the ground, so
//     fog under a cloud bank dims with the same curve the terrain below it does.
//
// STABILITY CHOICES (each one guards a reported class of artefact):
//   * fog is only integrated while the path travels through AIR. The medium stack already models
//     water/glass extinction physically (Beer–Lambert per segment); stacking air fog on top of an
//     underwater segment would double-attenuate it. Segments inside any non-air medium are skipped,
//     which is what keeps the water surface and everything under it stable: looking down at a lake
//     from outside, the camera→surface hop still gets its aerial-perspective veil (that hop is in
//     air), while the refracted continuation underwater does not;
//   * the sun direction is jittered ONCE per segment (not per sample), so all of a segment's shadow
//     rays stay coherent, the shaft edges stay crisp within a frame, and penumbra softness comes from
//     temporal accumulation the denoiser already performs;
//   * the sample spacing is geometric (fine near the camera, coarse far away) with a stratified
//     per-frame jitter, so banding dithers into noise instead of freezing into stripes;
//   * per-step in-scatter is clamped against the light that produced it, so no single sample can
//     out-firefly the light's own radiance and poison the temporal history.
//
// Only world_common's struct plus math/clouds/trace helpers are used; like clouds.slang every entry
// point takes the WorldPush explicitly, EXCEPT the shadow rays, which need the raygen bindings —
// this module is therefore imported by world.rgen only (a miss shader cannot trace).

import world_common;
import math;
import clouds;
import trace;

// ---- Shape ---------------------------------------------------------------------------------------

// Base extinction at the slider's maximum (per block). The Java side maps the density slider 0..1
// linearly onto this; 0.05 gives roughly e^-0.05 ~= 95% transmission per block at full density —
// a heavy but not opaque valley haze at the default height falloff.
public static const float FOG_SIGMA_MAX = 0.05;
// Height falloff of the band: density falls as exp(-(y - baseY) / H). The band's effective ceiling
// is this many falloff scales above the base; beyond it the density is < 0.7% of the base value and
// the march stops tracking it.
public static const float FOG_BAND_CEILING_SCALES = 5.0;
// Longest distance a single segment marches. The geometric step distribution spends the sample
// budget near the camera, so the far field is covered by the analytic extinction tail below; this
// cap just bounds the loop for near-horizontal escape rays.
public static const float FOG_MAX_MARCH_BLOCKS = 1536.0;

// ---- March budget ---------------------------------------------------------------------------------
//
// Two tiers, exactly like the cloud march: the camera ray and specular/dielectric bounces (what the
// player actually looks at) get the full march; diffuse continuation rays get a short one — their
// contribution is a broad, low-frequency fill that the denoiser averages over the hemisphere, where
// extra detail is invisible but extra shadow rays are not free.
public static const int FOG_MARCH_STEPS = 16;
public static const int FOG_MARCH_STEPS_CHEAP = 4;
// March stops early once this little background transmittance remains — a saturated fog column
// cannot contribute more in-scatter worth sampling.
public static const float FOG_SATURATION_TRANSMITTANCE = 0.012;

// ---- Shading --------------------------------------------------------------------------------------

// Single-scattering albedo of the medium: how much of the extinguished light re-radiates. Slightly
// below 1 so a deep column absorbs a little and the far field settles darker than the near field.
public static const float FOG_SCATTER_ALBEDO = 0.92;
// Neutral-cool tint for the in-scattered light. The sun/moon radiance already carries the
// time-of-day colour (sunset reds, weather dimming), so the tint stays almost neutral — a faint
// blue bias is what makes distance haze read as atmosphere rather than milk.
public static const float3 FOG_TINT = float3(0.94, 0.97, 1.0);
// Weight of the sky-ambient in-scatter (the term that keeps fully shadowed fog faintly visible
// rather than black). Deliberately modest: fog deep in a cave or under a dense canopy should read
// dark, per the occlusion contract above — this is a floor, not a fill light.
public static const float FOG_AMBIENT_WEIGHT = 0.45;
// Isotropic phase value 1/(4*pi): the g=0 limit of Henyey–Greenstein and the floor the forward
// lobe is blended over, so god-ray strength 0 degenerates to uniform fog exactly.
public static const float FOG_INV_4PI = 0.0795774715;
// Per-sample in-scatter luminance ceiling, as a multiple of the light field that produced it
// (sun + ambient). Keeps a grazing forward-lobe sample aligned with the sun disc from spiking far
// past the glare the fog could physically glow with, which the temporal filters would smear.
public static const float FOG_INSCATTER_LIGHT_MULTIPLE = 8.0;

/** Result of integrating fog along one segment, in the same premultiplied form as CloudVolume. */
public struct FogVolume {
    public float3 scatter;      // in-scattered radiance, premultiplied by the leading transmittance
    public float transmittance; // scalar: the fog's extinction is deliberately neutral
};

/** Fog is armed this frame: the feature bit is set and the host pushed a non-zero base density. */
public bool fogEnabled(WorldPush push) {
    return worldFeature(push, FEATURE_FOG) && push.fog.x > 0.0;
}

/**
 * Fog extinction density at a camera-relative height.
 *
 * exp falls off above the pushed base height and is CLAMPED at the base value below it: a valley
 * floor or a cave under the base line gets the base density, not an exponentially thickening soup.
 * (Caves are additionally protected by the occlusion contract — their in-scatter samples cannot see
 * the sun — and their segments are short, so the veil over nearby walls stays negligible.)
 */
float fogDensityAt(WorldPush push, float relY) {
    float above = max(relY - push.fog.z, 0.0);
    return push.fog.x * exp(-above / max(push.fog.y, 1.0));
}

/**
 * Effective phase for the sun/moon in-scatter, from the god-ray strength lane.
 *
 * {@code push.fog.w} blends between the isotropic 1/(4*pi) and a Henyey–Greenstein forward lobe
 * whose anisotropy grows with the same slider. At strength 0 the blend is exactly isotropic (pure
 * distance haze, no shafts); at 1 the lobe is tight (g = 0.85) and dominates, which is what makes
 * the light that DOES reach a fog voxel through the gaps flare into visible rays around the light
 * source. One phase serves both terms' directionality; only the sun term uses it at full weight.
 */
float fogPhase(WorldPush push, float cosT) {
    float strength = clamp(push.fog.w, 0.0, 1.0);
    float g = strength * 0.85;
    float lobeWeight = 0.30 + 0.55 * strength;
    return lerp(FOG_INV_4PI, hg(cosT, g), lobeWeight);
}

/**
 * Integrate the fog band along ONE segment, as premultiplied in-scatter plus the transmittance the
 * background keeps — the same contract as {@code clouds.cloudSegment}.
 *
 * {@code origin} is in the terrain's rebased coordinates (what TraceRay consumes, so the shadow
 * rays below need no translation); the height query subtracts camOffset internally. {@code dir} is
 * normalized. {@code maxDistance} is the distance to the nearest scene hit (or a large value for a
 * sky escape): the march NEVER reads past it, which is half of the block-occlusion contract. The
 * other half is the per-sample shadow visibility toward the celestial light inside the march.
 *
 * Sample spacing is geometric and stratified: each step owns one cell of [0,1), the cell's position
 * is squared into distance (fine near the camera where parallax moves the band fastest, coarse far
 * away where the field is near-constant), and a jitter inside the cell dithers the residual banding
 * into noise the denoiser already averages. If the budget runs out while still inside the band, the
 * remaining extinction is added analytically from the last sample's density, so distant surfaces
 * never pop out of the fog when the step count is finite.
 */
public FogVolume fogSegment(WorldPush push, float3 origin, float3 dir, float maxDistance,
                            inout uint seed, bool highQuality) {
    FogVolume result;
    result.scatter = float3(0.0, 0.0, 0.0);
    result.transmittance = 1.0;
    if (!fogEnabled(push) || maxDistance <= 1.0e-3) {
        return result;
    }

    // ---- Interval of the segment that lies inside the band -------------------------------
    //
    // The band is every height at or below base + ceiling. A rising ray leaves it at tExit; a
    // falling ray from above the ceiling enters at tEnter; anything else is inside from the start.
    // When the interval is empty the fog costs nothing — looking up at a clear sky above the band
    // never marches.
    float3 originRel = origin - push.camOffset;
    float topRel = push.fog.z + max(push.fog.y, 1.0) * FOG_BAND_CEILING_SCALES;
    float t0 = 0.0;
    float t1 = min(maxDistance, FOG_MAX_MARCH_BLOCKS);
    if (dir.y > 1.0e-6) {
        float tExit = (topRel - originRel.y) / dir.y;
        if (tExit <= 0.0) {
            return result; // already above the band and rising: no fog on this segment
        }
        t1 = min(t1, tExit);
    } else if (dir.y < -1.0e-6) {
        float tEnter = (topRel - originRel.y) / dir.y; // positive while the origin is above the band
        if (tEnter > 0.0) {
            t0 = min(tEnter, t1);
        }
    } else if (originRel.y > topRel) {
        return result; // level ray above the ceiling
    }
    if (t1 - t0 < 1.0e-3) {
        return result;
    }

    // ---- Light field -----------------------------------------------------------------------
    //
    // The sun direction is jittered within its authored angular extent ONCE per segment (matching
    // the surface NEE's sampling), then reused by every sample's shadow ray: coherent traversal,
    // stable shaft edges within a frame, and penumbra softness arriving through frame-to-frame
    // accumulation instead of per-sample smearing.
    float3 sunRadiance = push.lightRadiance.xyz;
    bool sunActive = max(sunRadiance.x, max(sunRadiance.y, sunRadiance.z)) > 0.0;
    float3 lightDir = push.lightDir.xyz;
    if (sunActive && push.lightDir.w > 0.0) {
        lightDir = sampleSquare(lightDir, push.lightDir.w, seed);
    }
    float3 ambient = cloudSkyAmbient(push);
    float3 lightField = sunRadiance + ambient;
    float inScatterMax = (luminance(lightField) + 1.0e-4) * FOG_INSCATTER_LIGHT_MULTIPLE;
    // Phase is constant along a straight segment (view and light directions are fixed), so the
    // direction-dependent part of the sun term resolves once, not per sample.
    float phase = fogPhase(push, dot(-dir, lightDir));

    // ---- March ------------------------------------------------------------------------------
    int steps = highQuality ? FOG_MARCH_STEPS : FOG_MARCH_STEPS_CHEAP;
    float span = t1 - t0;
    float tPrev = t0;
    float lastDensity = 0.0;
    for (int i = 0; i < steps; ++i) {
        // Stratified geometric partition: each step owns one cell of [0,1), the cell's position is
        // squared into distance (fine near the camera, coarse far away), and a per-step jitter
        // inside the cell dithers the residual banding into noise the denoiser already averages.
        // fi is strictly increasing across cells, so dt can approach zero only at a cell boundary
        // and never goes negative.
        float fi = (float(i) + rndf(seed)) / float(steps);
        float tNext = t0 + span * fi * fi;
        float dt = tNext - tPrev;
        tPrev = tNext;
        if (dt <= 1.0e-4) {
            continue;
        }
        float tm = tPrev - dt * 0.5;

        float3 sampleRel = originRel + dir * tm;
        float density = fogDensityAt(push, sampleRel.y);
        lastDensity = density;
        if (density <= 0.0) {
            continue; // above the band's usable ceiling (can only happen on the clamped tail)
        }

        // Direct in-scatter from the celestial light, gated by REAL occlusion: a scene shadow ray
        // from the fog voxel toward the sun, plus the analytic cloud shadow the ground under the
        // same voxel would get. Scene visibility is queried FIRST — a voxel already blocked by
        // terrain must not stack the cloud term on top of a fully darkened path (the same ordering
        // rule the surface NEE follows for the same stability reason).
        float3 sunTerm = float3(0.0, 0.0, 0.0);
        if (sunActive) {
            float3 vis = visibility(origin + dir * tm, lightDir, 10000.0).transmittance;
            if (max(vis.r, max(vis.g, vis.b)) > 0.0) {
                vis *= cloudSunShadow(push, sampleRel, lightDir);
                sunTerm = sunRadiance * phase * vis;
            }
        }

        // Sky-ambient in-scatter needs no ray: it is the omnidirectional floor that keeps fully
        // occluded fog dimly visible. For an isotropic phase over an average upper-hemisphere
        // radiance the integral collapses to half the ambient value (1/(4pi) * 2pi).
        float3 inScatter = FOG_TINT * (sunTerm + ambient * FOG_AMBIENT_WEIGHT * 0.5);
        // Firefly guard: a sample may not out-glow the light field that produced it.
        float inLum = luminance(inScatter);
        if (inLum > inScatterMax) {
            inScatter *= inScatterMax / inLum;
        }

        // Energy-conserving accumulation over the step's own absorbed fraction (weights the scatter
        // by the leading transmittance, exactly like the cloud march).
        float stepTransmittance = exp(-density * dt);
        result.scatter += result.transmittance * FOG_SCATTER_ALBEDO * inScatter
                * (1.0 - stepTransmittance);
        result.transmittance *= stepTransmittance;
        if (result.transmittance < FOG_SATURATION_TRANSMITTANCE) {
            result.transmittance = 0.0;
            return result; // saturated: nothing behind this point is visible through the fog
        }
    }

    // Analytic extinction tail: the geometric budget may run out while still inside the band
    // (near-horizontal rays). Density varies slowly out there, so the last sample's value times the
    // remaining distance is the standard far-field approximation — distant surfaces keep sinking
    // into the fog instead of popping out of it.
    if (tPrev < t1 && lastDensity > 0.0) {
        result.transmittance *= exp(-lastDensity * (t1 - tPrev));
    }
    return result;
}

/**
 * Composite fog over a finished background in one call, for callers that hold a complete colour
 * rather than a path throughput (mirrors {@code clouds.cloudLayer}).
 */
public float3 fogLayer(WorldPush push, float3 origin, float3 dir, float maxDistance,
                       float3 background, inout uint seed, bool highQuality) {
    FogVolume v = fogSegment(push, origin, dir, maxDistance, seed, highQuality);
    return background * v.transmittance + v.scatter;
}
