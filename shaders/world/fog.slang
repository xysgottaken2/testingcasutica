// World-space volumetric fog + god rays.
//
// THE MENTAL MODEL: the fog itself is only air holding a medium — what the eye sees is LIGHT
// SCATTERING inside it. Every source in the scene lights the medium with its own colour and
// strength, which is why this is integrated per light source and never faked with a constant veil:
//
//   * SUN / MOON — the dominant term. One shadow ray per sample toward the celestial light, phased
//     by a forward-scattering lobe: that is where the god rays come from. Light that terrain, a
//     canopy or a roof blocks simply does not reach the fog, so haze behind a mountain ridge or
//     inside a cave stays dark, and the gaps the light does get through become visible shafts.
//     Translucent occluders tint the shaft through the shadow ray's own transmittance (stained
//     glass paints the beam), and the analytic cloud shadow dims fog under a cloud bank exactly
//     like the terrain below it.
//   * BLOCK EMITTERS — torches, lava, glowstone, lanterns... gathered per segment from the SAME
//     light grid the ReSTIR emitter sampling uses, shaded with each emitter's own radiance (a soul
//     torch glows cyan, lava deep orange) and gated by a real shadow ray. A torch is not the sun:
//     its in-scatter falls off as 1/r^2 around it, so it paints a small local halo in the fog and
//     nothing else.
//   * HELD-ITEM LIGHT — the torch in the player's hand puts its own small halo in the air, with the
//     same intensity/tint lanes the surface hand-light NEE uses.
//   * SKY AMBIENT — the hemisphere fill that keeps outdoor haze faintly visible at all. It is
//     gated by a per-segment sky-visibility probe (one shadow ray along a jittered upward
//     direction), so it collapses to zero under an opaque ceiling: A DARK CAVE HAS NO FOG, because
//     unlit fog is invisible — exactly the physics. The ambient contribution is deliberately small
//     and cool-tinted; it is a floor, not a fill light.
//
// THE MEDIUM: a height band anchored to world Y (density falls off exponentially above the pushed
// base and is clamped at it below), integrated inside the path integral with the same two-line
// composite the cloud deck uses ({@code L += T * scatter; T *= transmittance;}) — so the fog is
// correct in water reflections, through glass, and over indirect bounce light for free.
//
// THE BLOCK-OCCLUSION CONTRACT (the point of doing this in world space):
//   * the march is bounded by the distance to the nearest scene hit — fog exists only in the open
//     air along a segment, never "through" a mountain or a wall the ray actually hit;
//   * every lighting term above is gated by a real visibility ray toward its source.
//
// STABILITY CHOICES (each guards a known artefact class):
//   * fog integrates ONLY while the path travels through AIR. Water/glass segments already
//     attenuate through their own Beer–Lambert extinction; stacking air fog on top would
//     double-dim the underwater world (see the medium gate in world.rgen);
//   * the sun direction is jittered ONCE per segment (not per sample), so a segment's shadow rays
//     stay coherent, shaft edges stay crisp within a frame, and penumbra softness arrives through
//     temporal accumulation the denoiser already performs;
//   * emitter gathering and the sky probe run once per SEGMENT (the local light field varies slowly
//     along a segment), so their cost is a handful of rays regardless of the step count;
//   * sample spacing is geometric and stratified (fine near the camera, coarse far away), so
//     banding dithers into noise instead of freezing into stripes;
//   * per-step in-scatter is clamped against the light field that produced it, so no single sample
//     can out-firefly its own light and poison the temporal history.
//
// Like clouds.slang, entry points take the WorldPush explicitly — EXCEPT the shadow rays, which
// need the raygen bindings: this module is imported by world.rgen only (a miss shader cannot trace).

import world_common;
import math;
import clouds;
import trace;
import lighting;

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
// Tint of the SUN/MOON in-scatter. The celestial radiance already carries the time-of-day colour
// (sunset reds, weather dimming), so this stays almost neutral — a faint cool bias is what makes
// shafts read as atmosphere rather than milk.
public static const float3 FOG_TINT = float3(0.94, 0.97, 1.0);
// The sky-ambient in-scatter gets its own, deliberately DIM and cool tint: this term is only the
// floor that keeps outdoor haze faintly visible, and it is sky-visibility gated on top (see the
// probe in fogSegment). Bright + neutral here was exactly the flat white veil that read as
// "Silent Hill" — unlit air must stay dark, and what little it adds should be sky-coloured.
public static const float3 FOG_AMBIENT_TINT = float3(0.50, 0.65, 0.90);
public static const float FOG_AMBIENT_WEIGHT = 0.12;
// Isotropic phase value 1/(4*pi): the g=0 limit of Henyey–Greenstein, used for the local-emitter
// and sky-ambient terms (a torch lights the air in every direction) and the floor the sun's forward
// lobe is blended over, so god-ray strength 0 degenerates to uniform fog exactly.
public static const float FOG_INV_4PI = 0.0795774715;
// Per-sample in-scatter luminance ceiling, as a multiple of the light field that produced it
// (sun + gated ambient + the strongest local emitter + the held light). Keeps a grazing
// forward-lobe sample or a voxel right on top of a torch from spiking far past what that light
// could physically put in the air, which the temporal filters would smear.
public static const float FOG_INSCATTER_LIGHT_MULTIPLE = 8.0;

// ---- Local emitters (torches, lava, glowstone, held item) -----------------------------------------

// Kept emitters per segment. Four is enough to halo a cluster (a torch on a wall, a lava pocket)
// without turning the gather into a second RIS pass; anything past the strongest four contributes
// an imperceptible amount to a low-frequency effect.
public static const int FOG_MAX_LOCAL_LIGHTS = 4;
// Hard cap on Light records scanned per gather. Bounds the dependent-load chain (span -> record)
// the RIS cost profile warned about; the strongest emitters surface early anyway.
public static const int FOG_MAX_LIGHT_CANDIDATES = 16;
// A local emitter's in-scatter is cut beyond this radius: torch light itself barely reaches past
// ~14 blocks in Minecraft, and 1/r^2 has already done the rest by 24.
public static const float FOG_LIGHT_RADIUS = 24.0;
public static const float FOG_LIGHT_RADIUS_SQ = FOG_LIGHT_RADIUS * FOG_LIGHT_RADIUS;
// The held-item halo is smaller still — it is a hand-held flame.
public static const float FOG_HAND_LIGHT_RADIUS = 12.0;
public static const float FOG_HAND_LIGHT_RADIUS_SQ = FOG_HAND_LIGHT_RADIUS * FOG_HAND_LIGHT_RADIUS;

/** One kept block emitter, as the point-light approximation the fog in-scatter uses. */
public struct FogLight {
    public float3 pos;   // rebased emitter centre
    public float3 flux;  // runtime-scaled radiance * emitting area (the torch's "power")
    public float3 vis;   // shadow transmittance from the segment midpoint toward the emitter
    public float score;  // irradiance estimate at the gather point; drives the strongest-4 keep
};

/** Per-segment local light set, gathered once from the emitter grid at the segment midpoint. */
public struct FogLightSet {
    public FogLight lights[FOG_MAX_LOCAL_LIGHTS];
    public int count;
    public float peakLuminance; // strongest local irradiance estimate; feeds the firefly bound
};

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
 * The DENSITY says where the medium is — whether the player can SEE it is entirely the lights'
 * business (a dark cave holds the same invisible air).
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
 * source.
 */
float fogPhase(WorldPush push, float cosT) {
    float strength = clamp(push.fog.w, 0.0, 1.0);
    float g = strength * 0.85;
    float lobeWeight = 0.30 + 0.55 * strength;
    return lerp(FOG_INV_4PI, hg(cosT, g), lobeWeight);
}

/**
 * Gather the strongest nearby block emitters for one segment, from the SAME light grid the ReSTIR
 * emitter sampling uses (16-block cells of section light ranges). Deterministic top-N by the
 * irradiance each emitter puts at the segment midpoint — no reservoirs, no per-sample roulette:
 * the local light field varies slowly along a segment, so one gather shades the whole march.
 *
 * Each kept emitter then gets ONE shadow ray from the segment midpoint (stopping just short of the
 * emitting surface, the same convention the hand-light NEE uses): a torch behind a wall does not
 * halo the fog on the other side of it, and a stained-glass tint passes through the shadow ray's
 * own transmittance. Emitter radiance is scaled by the runtime block-emitter intensity lane, so
 * the "Block Light" slider dims torch fog with the same knob that dims the torch itself.
 *
 * Degrades to an empty set whenever the grid is not published (no emitters this frame, or the
 * global-only fallback) — the fog then simply carries no local glow, exactly like the surface
 * lighting degrading to global RIS proposals.
 */
FogLightSet fogGatherLights(float3 midAbs, float3 midRel) {
    FogLightSet set;
    set.count = 0;
    set.peakLuminance = 0.0;
    if (pc.lightBufAddr == 0u || pc.lightGridCellAddr == 0u || pc.lightGridSpanAddr == 0u
            || worldPush.lightCount == 0u) {
        return set;
    }
    LightGridCell cell;
    int3 cellCoord;
    if (!findLightGridCell(midRel, cell, cellCoord)) {
        return set;
    }
    ConstPtr<Light> lightBuf = ConstPtr<Light>(pc.lightBufAddr);
    ConstPtr<LightGridSpan> spans = ConstPtr<LightGridSpan>(pc.lightGridSpanAddr);
    float emitterScale = max(worldPush.lightScales.x, 0.0);
    int scanned = 0;
    for (uint s = 0u; s < cell.spanCount && scanned < FOG_MAX_LIGHT_CANDIDATES; ++s) {
        LightGridSpan span = spans[cell.spanOffset + s];
        uint spanLights = span.packedLightCounts & 0xffffu; // this span's own section range
        for (uint i = 0u; i < spanLights && scanned < FOG_MAX_LIGHT_CANDIDATES; ++i, ++scanned) {
            Light light = lightBuf[span.firstLight + i];
            float3 flux = lightRadiance(light) * (emitterScale * lightArea(light));
            float fluxLum = luminance(flux);
            if (fluxLum <= 0.0) {
                continue;
            }
            float3 delta = light.pos - midAbs;
            float r2 = dot(delta, delta);
            if (r2 > FOG_LIGHT_RADIUS_SQ) {
                continue;
            }
            float score = fluxLum / max(r2, 1.0); // irradiance estimate at the midpoint
            set.peakLuminance = max(set.peakLuminance, score);
            // Keep the strongest FOG_MAX_LOCAL_LIGHTS by score: fill an empty slot, or evict the
            // weakest kept emitter when the newcomer beats it.
            int slot = -1;
            if (set.count < FOG_MAX_LOCAL_LIGHTS) {
                slot = set.count;
                set.count += 1;
            } else {
                int weakest = 0;
                for (int k = 1; k < FOG_MAX_LOCAL_LIGHTS; ++k) {
                    if (set.lights[k].score < set.lights[weakest].score) {
                        weakest = k;
                    }
                }
                if (score > set.lights[weakest].score) {
                    slot = weakest;
                }
            }
            if (slot >= 0) {
                set.lights[slot].pos = light.pos;
                set.lights[slot].flux = flux;
                set.lights[slot].vis = float3(0.0, 0.0, 0.0);
                set.lights[slot].score = score;
            }
        }
    }
    // One visibility ray per KEPT emitter (midpoint -> emitter, stopping short of the surface).
    // Per-light, per-segment — never per-sample: this is what keeps a wall between the torch and
    // the fog as dark as the block-occlusion contract demands, at a fixed ray cost.
    for (int k = 0; k < set.count; ++k) {
        float3 delta = set.lights[k].pos - midAbs;
        float dist = length(delta);
        float3 ldir = dist > 1.0e-3 ? delta / dist : float3(0.0, 1.0, 0.0);
        set.lights[k].vis = visibility(midAbs, ldir, max(dist - 0.25, 2.0 * RAY_TMIN)).transmittance;
    }
    return set;
}

/**
 * Integrate the fog band along ONE segment, as premultiplied in-scatter plus the transmittance the
 * background keeps — the same contract as {@code clouds.cloudSegment}.
 *
 * {@code origin} is in the terrain's rebased coordinates (what TraceRay consumes, so the shadow
 * rays below need no translation); the height query subtracts camOffset internally. {@code dir} is
 * normalized. {@code maxDistance} is the distance to the nearest scene hit (or a large value for a
 * sky escape): the march NEVER reads past it, which is half of the block-occlusion contract. The
 * other half is the per-source visibility gating inside the march (see the module header).
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
    float span = t1 - t0;

    // ---- Per-segment light-field setup (everything that is constant along a straight line) ----
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
    // Phase is constant along a straight segment (view and light directions are fixed), so the
    // direction-dependent part of the sun term resolves once, not per sample.
    float phase = fogPhase(push, dot(-dir, lightDir));

    // Sky-visibility probe: ONE shadow ray along a jittered upward direction, gating the ambient
    // term below. Under an opaque ceiling (a cave, a vaulted roof, deep canopy) it reads zero and
    // the unlit medium stays invisible — the physical reason a dark cave holds no fog. Cosine
    // weighting concentrates the probe where the sky actually is (up), and the per-segment jitter
    // turns a hard occlusion edge into soft noise the denoiser already averages.
    float3 midAbs = origin + dir * (t0 + span * 0.5);
    float3 midRel = midAbs - push.camOffset;
    float3 skyDir = cosineDir(float3(0.0, 1.0, 0.0), seed);
    float skyVis = clamp(luminance(visibility(midAbs, skyDir, 1.0e4).transmittance), 0.0, 1.0);

    // Local emitters (torches, lava, glowstone): gathered and visibility-resolved once per segment
    // at the same midpoint — see fogGatherLights. The held-item light is analytic: same intensity
    // and tint lanes the surface hand-light NEE reads, no ray (its occluder would be the player's
    // own viewmodel, which the surface path explicitly excludes too).
    FogLightSet local = fogGatherLights(midAbs, midRel);
    float handIntensity = push.handLight.w * max(push.lightScales.y, 0.0);
    float3 handColor = push.handLightColor.xyz;

    // Firefly bound: a sample may not out-glow the lights that produced it. Every source's
    // peak contribution to THIS segment is accounted for, so a voxel sitting right on a torch
    // cannot spike past what the torch could physically put in the air.
    float3 ambient = cloudSkyAmbient(push);
    float handPeak = handIntensity > 0.0 ? luminance(handColor) * handIntensity : 0.0;
    float inScatterMax = (luminance(sunRadiance)
            + luminance(ambient) * FOG_AMBIENT_WEIGHT * skyVis
            + local.peakLuminance * FOG_INV_4PI
            + handPeak * FOG_INV_4PI + 1.0e-4) * FOG_INSCATTER_LIGHT_MULTIPLE;

    // ---- March ------------------------------------------------------------------------------
    int steps = highQuality ? FOG_MARCH_STEPS : FOG_MARCH_STEPS_CHEAP;
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

        float3 sampleAbs = origin + dir * tm;
        float3 sampleRel = originRel + dir * tm;
        float density = fogDensityAt(push, sampleRel.y);
        lastDensity = density;
        if (density <= 0.0) {
            continue; // above the band's usable ceiling (can only happen on the clamped tail)
        }

        // ---- Sun / moon in-scatter: the god-ray term.
        //
        // Gated by REAL occlusion: a scene shadow ray from the fog voxel toward the light, plus
        // the analytic cloud shadow the ground under the same voxel would get. Scene visibility is
        // queried FIRST — a voxel already blocked by terrain must not stack the cloud term on top
        // of a fully darkened path (the same ordering rule the surface NEE follows).
        float3 sunTerm = float3(0.0, 0.0, 0.0);
        if (sunActive) {
            float3 vis = visibility(sampleAbs, lightDir, 10000.0).transmittance;
            if (max(vis.r, max(vis.g, vis.b)) > 0.0) {
                vis *= cloudSunShadow(push, sampleRel, lightDir);
                sunTerm = sunRadiance * phase * vis;
            }
        }

        // ---- Local emitter in-scatter: the torch/lava/glowstone halos.
        //
        // Point-light form: flux (radiance x emitting area) over the squared distance, phased
        // isotropically — a flame lights the air in every direction. The 1/r^2 falloff IS the
        // "a torch is not the sun" scaling: double the distance, a quarter of the glow. The
        // near-distance clamp keeps a voxel practically inside the emitter finite (the same
        // convention handLightIrradiance uses). Visibility is the per-emitter segment ray resolved
        // in fogGatherLights — constant along the segment, never per sample.
        float3 localTerm = float3(0.0, 0.0, 0.0);
        for (int li = 0; li < local.count; ++li) {
            float3 delta = local.lights[li].pos - sampleAbs;
            float r2 = dot(delta, delta);
            if (r2 < FOG_LIGHT_RADIUS_SQ) {
                localTerm += local.lights[li].flux * local.lights[li].vis
                        * (FOG_INV_4PI / max(r2, 0.25));
            }
        }
        // Held-item halo: same lanes as the surface hand-light NEE (intensity x dynamic scale,
        // per-item tint), isotropic, radius-bounded.
        if (handIntensity > 0.0) {
            float3 delta = push.handLight.xyz - sampleAbs;
            float r2 = dot(delta, delta);
            if (r2 < FOG_HAND_LIGHT_RADIUS_SQ) {
                localTerm += handColor * (handIntensity * FOG_INV_4PI / max(r2, 0.25));
            }
        }

        // ---- Sky ambient in-scatter: the sky-lit haze floor.
        //
        // Needs no further ray (the sky-visibility probe above already gated it): for an
        // isotropic phase over an average upper-hemisphere radiance the integral collapses to
        // half the ambient value (1/(4pi) * 2pi). Small, cool-tinted, and ZERO under a ceiling —
        // unlit fog is invisible, which is why a cave stays clear.
        float3 ambientTerm = FOG_AMBIENT_TINT * ambient * (FOG_AMBIENT_WEIGHT * 0.5 * skyVis);

        float3 inScatter = FOG_TINT * sunTerm + localTerm + ambientTerm;
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
