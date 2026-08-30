// Volumetric fog plus sun shafts ("god rays") in world space.
//
// Unlike a screen-space fog or a distance-based atmosphere attached to the sky shader, this is a real
// participating medium integrated along every radiance segment. It therefore behaves correctly in
// reflections, refractions and indirect bounces, it is occluded by the first world hit exactly like
// clouds (fog behind a mountain or a cave wall never reaches the eye), and it stays inside the path
// integral instead of being painted at a display seam.
//
// The density is a world-stable 3D value noise. The XZ lattice is made exactly periodic over
// FOG_PERIOD_CELLS * FOG_CELL_BLOCKS blocks (16384), and RtComposite publishes the terrain rebase
// origin in fogAnchor reduced to that same period, so walking and terrain rebases never slide the fog
// pattern. Height is used directly (not wrapped) so altitude fall-off and the cave/surface cutoff stay
// world-coherent.
//
// God rays are a single-scattering term along the same march: at a sparse subset of steps we cast the
// existing light-ray visibility query toward the active celestial light, so shafts are blocked by
// buildings, terrain and clouds exactly like the direct light they came from. The sparse cadence keeps
// the cost sane; the denoiser smooths the remaining stepiness over frames.
//
// The fog only exists in air. Rays travelling through a dielectric volume (water, glass, ice) keep the
// volume's own extinction and never add this atmospheric medium, which is what keeps the water surface
// stable: fog is neither baked into the surface nor re-added inside the medium.

import world_common;
import world_core;
import trace;
import math;

public static const float FOG_CELL_BLOCKS = 32.0;
public static const uint  FOG_CELL_MASK = 511u;

// Optical density at density 1, per block, before the height/noise field. 0.045 * realistic
// daylight haze over a few hundred blocks; the slider scales it directly.
public static const float FOG_EXTINCTION = 0.045;
// Cloud-style marching budget. The full tier is used by the camera ray and specular bounces (what the
// player actually sees); the cheap tier is what diffuse indirect rays pay, where fog detail is
// invisible after the hemisphere average anyway.
public static const int   FOG_MARCH_STEPS = 24;
public static const int   FOG_MARCH_STEPS_CHEAP = 6;
public static const int   FOG_MARCH_STEPS_MAX = 40;
public static const int   FOG_MARCH_STEPS_CHEAP_MAX = 12;
public static const float FOG_TARGET_STEP_BLOCKS = 12.0;
// God-ray shadow-ray cadence. Four checks per full march keeps the shafts readable without turning
// every fog sample into an extra trace. The cheap tier traces one.
public static const int   FOG_SUN_CHECKS = 4;
public static const float FOG_PHASE_SCALE = 5.0;
public static const float FOG_SUN_SCALE = 1.0;
public static const float FOG_GOD_RAY_MIN_VISIBILITY = 1.0e-4;
public static const float FOG_HEIGHT_CUTOFF_WIDTH = 20.0;

bool fogEnabled() {
    return worldFeature(worldPush, FEATURE_FOG) && worldPush.fogParams.x > 0.0;
}

bool fogGodRaysEnabled() {
    return worldFeature(worldPush, FEATURE_GOD_RAYS) && worldPush.fogParams.y > 0.0;
}

float3 fogSkyAmbient() {
    float3 sun = worldPush.lightRadiance.xyz;
    // Same day/night/weather curve as cloud ambient, keeping fog readable at night without going
    // black. fogParams2.z is the player's sky-fill scale.
    float3 ambient = sun * 0.08 + float3(0.012, 0.017, 0.028);
    return ambient * clamp(worldPush.fogParams2.z, 0.0, 2.0);
}

// Integer 3D cell hash. X/Z are masked to the exact 16384-block period; Y is not, so the vertical
// profile stays a genuine altitude field rather than wrapping. Integer mixing keeps thousands of
// blocks of world coordinate stable in float.
float fogHash(int3 cell) {
    uint x = uint(cell.x) & FOG_CELL_MASK;
    uint y = uint(cell.y);
    uint z = uint(cell.z) & FOG_CELL_MASK;
    uint h = x * 374761393u + y * 668265263u + z * 1274126177u;
    h = (h ^ (h >> 13u)) * 1274126177u;
    h = h ^ (h >> 16u);
    return float(h & 0x00ffffffu) * (1.0 / 16777216.0);
}

// Trilinear value noise on the cell lattice, smooth-step interpolated.
float fogNoise(float3 p) {
    int3 i = int3(floor(p));
    float3 f = frac(p);
    float3 u = f * f * (3.0 - 2.0 * f);
    float a = fogHash(i);
    float b = fogHash(i + int3(1, 0, 0));
    float c = fogHash(i + int3(0, 1, 0));
    float d = fogHash(i + int3(1, 1, 0));
    float e = fogHash(i + int3(0, 0, 1));
    float g = fogHash(i + int3(1, 0, 1));
    float h = fogHash(i + int3(0, 1, 1));
    float k = fogHash(i + int3(1, 1, 1));
    float x00 = lerp(a, b, u.x);
    float x10 = lerp(c, d, u.x);
    float x01 = lerp(e, g, u.x);
    float x11 = lerp(h, k, u.x);
    float y0 = lerp(x00, x10, u.y);
    float y1 = lerp(x01, x11, u.y);
    return lerp(y0, y1, u.z);
}

// World-stable sample coordinate: camera-relative position + camera offset (rebased terrain space) +
// terrain rebase origin. The camera-relative and rebase terms move in opposite directions when the
// terrain re-anchors, so the sum stays pinned to the world (mod 16384 for XZ).
float3 fogWorldPos(float3 originRel) {
    return originRel + worldPush.camOffset + worldPush.fogAnchor.xyz;
}

/**
 * 0..1 fog density at a world-space point. The two shaping terms are deliberately separated:
 *
 *   * CAVE KILL: smoothstep around fogParams2.x (the reference surface height, default sea level).
 *     Below it the air is essentially clear, so caves do not fill with fog even when the player has a
 *     long view down a shaft; at and above the surface it ramps in.
 *   * ALTITUDE FALLOFF: above the reference height the density decays with fogParams2.y, so mountain
 *     tops and high terrain stay clearer than the valley air.
 *
 * The horizontal noise then modulates the fog into soft moving banks instead of a flat wall.
 */
float fogDensity(float3 originRel) {
    float3 wp = fogWorldPos(originRel);
    float caveCut = smoothstep(worldPush.fogParams2.x - FOG_HEIGHT_CUTOFF_WIDTH,
                               worldPush.fogParams2.x + FOG_HEIGHT_CUTOFF_WIDTH * 0.35,
                               wp.y);
    float altitude = exp(-max(wp.y - worldPush.fogParams2.x, 0.0) / max(worldPush.fogParams2.y, 1.0));
    float3 p = wp / FOG_CELL_BLOCKS;
    float noise = fogNoise(p) * 0.65
                + fogNoise(p * 2.0 + float3(11.0, 7.0, 19.0)) * 0.25
                + fogNoise(p * 4.0 + float3(29.0, 31.0, 23.0)) * 0.10;
    // Weather: rain and storms thicken haze by up to ~2x, matching the cloud/weather lighting story
    // already resolved in worldPush.weather.
    float weather = 1.0 + clamp(worldPush.weather.x, 0.0, 1.0) * 1.0;
    float density = caveCut * altitude * (0.35 + 0.65 * noise) * weather;
    return clamp(density, 0.0, 1.0) * clamp(worldPush.fogParams.x, 0.0, 1.0);
}

// Single-lobe Henyey-Greenstein (4-pi normalised), centred on fogParams2.w.
float fogPhase(float cosT) {
    float g = clamp(worldPush.fogParams2.w, 0.0, 0.9);
    float g2 = g * g;
    float d = 1.0 + g2 - 2.0 * g * cosT;
    return (1.0 - g2) / (4.0 * 3.14159265359 * max(d * sqrt(max(d, 1.0e-6)), 1.0e-4));
}

float fogSunTransmittance(float3 originRel) {
    float3 sun = worldPush.lightDir.xyz;
    if (max(worldPush.lightRadiance.x, max(worldPush.lightRadiance.y, worldPush.lightRadiance.z)) <= 0.0
            || sun.y <= 1.0e-4) {
        return 1.0;
    }
    // The visibility query lives in rebased terrain space, the same space the path tracer's rays use.
    VisibilityResult shadow = visibility(originRel + worldPush.camOffset,
                                         sun, worldPush.fogParams.z * 4.0);
    return clamp(luminance(shadow.transmittance) * FOG_SUN_SCALE, 0.0, 1.0);
}

/** Result of a fog march: premultiplied scattered radiance and surviving transmittance. */
public struct FogVolume {
    public float3 scatter;
    public float transmittance;
};

/**
 * March fog along one segment. `maxDistance` is the distance to the nearest opaque hit (or a large
 * number on a sky miss), so the march can never integrate fog behind solid geometry. The fog beyond
 * `fogParams.z` is simply not marched — the configured distance also serves as the visibility fade of
 * the cheap world fog, which keeps the default cost and the horizon both stable.
 */
public FogVolume fogSegment(float3 originRel, float3 dir, float maxDistance, bool highQuality) {
    FogVolume result;
    result.scatter = float3(0.0, 0.0, 0.0);
    result.transmittance = 1.0;
    if (!fogEnabled() || maxDistance <= 1.0e-4) {
        return result;
    }

    float fogMax = clamp(worldPush.fogParams.z, 16.0, 1024.0);
    float d = min(maxDistance, fogMax);
    if (d <= 1.0e-4) {
        return result;
    }

    int marchSteps = highQuality ? FOG_MARCH_STEPS : FOG_MARCH_STEPS_CHEAP;
    int stepCap = highQuality ? FOG_MARCH_STEPS_MAX : FOG_MARCH_STEPS_CHEAP_MAX;
    marchSteps = clamp(int(d / FOG_TARGET_STEP_BLOCKS), marchSteps, stepCap);
    float stepLen = d / float(marchSteps);
    bool godRays = fogGodRaysEnabled();
    bool sunLit = godRays && max(worldPush.lightRadiance.x,
            max(worldPush.lightRadiance.y, worldPush.lightRadiance.z)) > 0.0;
    // Diffuse indirect rays are averaged over the hemisphere and never show shaft detail, so they
    // spend at most one light-visibility ray instead of paying the full cadence per sample.
    int sunChecks = highQuality ? FOG_SUN_CHECKS : 1;
    int sunInterval = godRays ? max(1, marchSteps / sunChecks) : 0;
    float sunVis = 1.0;
    float cosT = dot(dir, worldPush.lightDir.xyz);
    float phase = fogPhase(cosT);
    float3 albedo = lerp(float3(0.64, 0.68, 0.74), float3(0.54, 0.57, 0.63),
                         clamp(worldPush.weather.x, 0.0, 1.0));
    float3 ambient = fogSkyAmbient();

    for (int i = 0; i < marchSteps; i++) {
        float3 pos = originRel + dir * (stepLen * (float(i) + 0.5));
        float density = fogDensity(pos);
        if (density <= 0.0) {
            continue;
        }
        float extinction = density * FOG_EXTINCTION * stepLen;
        if (extinction <= 0.0) {
            continue;
        }
        if (godRays && sunLit && (i % sunInterval == 0)) {
            sunVis = fogSunTransmittance(pos);
        }
        float sampleTransmittance = exp(-extinction);
        float3 inScatter;
        if (sunLit && sunVis > FOG_GOD_RAY_MIN_VISIBILITY) {
            float3 sunScatter = worldPush.lightRadiance.xyz * sunVis * phase
                    * FOG_PHASE_SCALE * clamp(worldPush.fogParams.y, 0.0, 2.0);
            inScatter = albedo * (sunScatter + ambient);
        } else {
            inScatter = albedo * ambient;
        }
        result.scatter += result.transmittance * inScatter * (1.0 - sampleTransmittance);
        result.transmittance *= sampleTransmittance;
        if (result.transmittance < 0.01) {
            result.transmittance = 0.0;
            break;
        }
    }
    return result;
}

/** Convenience composite for callers that already hold a finished background colour. */
public float3 fogLayer(float3 originRel, float3 dir, float maxDistance, float3 background,
                       bool highQuality) {
    FogVolume v = fogSegment(originRel, dir, maxDistance, highQuality);
    return background * v.transmittance + v.scatter;
}
