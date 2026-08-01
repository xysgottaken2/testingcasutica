// Indirect pass (pass B of the wavefront split — see docs/WAVEFRONT_PLAN.md).
//
// Resumes the continuations the primary pass queued and runs the bounce loop: NEE toward the sun, RIS
// emitter lighting, thin-surface SSS, BSDF continuation and Russian roulette. It captures no guides and
// owns no motion vectors — guides and primary are deliberately absent from the include list
// below, so guide state cannot leak into this pass by accident.
//
// Lighting is iterative here rather than recursive from closest-hit, so maxRayRecursionDepth stays 1.
// At each surface vertex:
//   * NEE toward the sun — a single analytic directional light, gated by one hit-object visibility
//     query (TerminateOnFirstHit | SkipClosestHit). Lambertian BRDF = albedo/PI.
//   * a cosine-weighted Lambertian continuation ray (throughput *= albedo; the PI and cos cancel).
// Sky / ambient light needs no separate AO pass: continuation rays that escape land in world.rmiss,
// which returns sky radiance — so soft sky fill and contact AO both fall out of the path integral.
//
// Each frame emits a single SPP-averaged (still noisy) estimate; temporal convergence is the denoiser's
// job. With RR disabled the output is the raw noisy path trace — a reference view, not a converged
// image. Output is HDR (R16G16B16A16_SFLOAT); the HDR -> LDR tonemap happens at the display.comp seam.
//
// The build emits an ordinary TraceRay fallback and an optional EXT SER variant from this source.
import world_common;
import world_core;
import math;
import medium;
import segment;
import water;
import trace;
#ifdef CAUSTICA_ENABLE_EXT_SER
import trace_ser;
#endif
import lighting;
import clouds;

public float3 tracePath(PathSegment seg, uint2 pix, uint sampleIndex,
                 bool restirEligiblePath, bool restirOwner, float restirSampleScale,
                 uint2 dimensions) {
    float3 L = float3(0.0, 0.0, 0.0);
    float3 ro = seg.ro;
    float3 rd = seg.rd;
    float3 throughput = seg.throughput;

    // ---- Cloud over the prefix Pass A already consumed.
    //
    // Pass A hands back a segment that starts AT THE CAMERA for an opaque hit, but for a dielectric
    // (water, glass, ice) it consumes the camera->surface hop itself and queues continuations that
    // start at the surface. Pass A has no radiance accumulator, so it cannot apply the cloud crossed on
    // the way there — and Pass B's loop only ever sees the post-surface segments. The result was the
    // reported bug: looking down at an ocean from above the clouds, the water was drawn at full
    // brightness with no cloud in front of it, while the terrain beside it was correctly dimmed.
    //
    // Recover it here by integrating the cloud over camera -> seg.ro for any segment that does not
    // start at the camera. Applying it to BOTH split branches is exact rather than a double count: the
    // two branches carry throughputs F and (1 - F), so their prefix contributions sum to exactly one
    // crossing (F*S + (1-F)*S = S), and each branch's own throughput picks up the same transmittance
    // the real prefix would have applied.
    if (seg.bounce > 0) {
        float3 toStart = ro - worldPush.camOffset;
        float prefixDist = length(toStart);
        if (prefixDist > 1.0e-4) {
            // Pass A consumes the camera -> first dielectric segment for water/glass, then queues the
            // post-interface branches. This pass owns a radiance accumulator, so it can now apply BOTH
            // halves of the rain/ambient fog over that skipped prefix before marching clouds. Without
            // this, water surfaces reflected/refracted the storm scene while their own camera-distance
            // segment stayed perfectly clear. Split branches are exact: their Fresnel throughputs sum to
            // one, so the prefix fog/scatter is not double-counted.
            AmbientFog preFog = evalAmbientFog(worldPush.ambientFog, prefixDist);
            L += throughput * preFog.inScatter;
            throughput *= preFog.transmittance;

            float closedStorm = closedStormCloudAmount(worldPush);
            if (closedStorm < 0.999) {
                CloudVolume pre = cloudSegment(worldPush, float3(0.0, 0.0, 0.0), toStart / prefixDist,
                                               prefixDist, cloudSkyAmbient(worldPush), seg.showCelestial);
                pre.scatter *= 1.0 - closedStorm;
                pre.transmittance = lerp(pre.transmittance, 1.0, closedStorm);
                L += throughput * pre.scatter;
                throughput *= pre.transmittance;
            }
        }
    }
    // Pass A is fixed at one sample per pixel. Decorrelate each Pass B resample here so configured SPP
    // produces independent lighting/BSDF paths from the shared terminal continuation.
    uint seed = seg.seed ^ sampleIndex * 2246822519u;
    seed = pcg(seed);
    float rayConeWidth = seg.rayConeWidth;
    float rayConeSpread = max(seg.rayConeSpread, RAY_CONE_MIN_SPREAD);
    int maxBounces = int(worldPush.maxBounces);
    int rrStart = maxBounces <= 3 ? 1 : 2;
    // RIS emitter NEE: direct lighting from block emitters is active when lights are published and the
    // candidate count is non-zero. Off => emitters are gathered only on path hits (legacy behaviour).
    bool risOn = worldPush.risCandidates > 0u && worldPush.lightCount > 0u && pc.lightBufAddr != 0;
    // The explicit pc.restirMode uniform chooses the final-color estimator. On the first stable receiver
    // of leaf 0, sample 0 shades the ReSTIR reservoir and is scaled by SPP; sibling SPP paths skip ONLY
    // that receiver. Consequently frame averaging contains one full ReSTIR estimate rather than one
    // ReSTIR estimate diluted by (SPP-1) legacy RIS estimates. Deeper/random paths remain ordinary RIS.
    bool restirPathOn = restirEligiblePath && restirEnabled() && risOn;
    bool restirReceiverPending = restirPathOn;
    // Independent light-proposal RNG. Screen-space coherent selection is intentionally deferred until
    // there is a real presampled RIS tile buffer; direct sharing made tile-shaped lighting noise visible.
    // Measured: making a 16x16 tile share this seed recovers at most 1.3ms, so a future pool should share
    // the POOL rather than the seed — the win is in removing dependent loads, not in coherence.
    uint proposalSeed = pix.x * 1973u + pix.y * 9277u + 26699u
            ^ worldPush.frameIndex * 2654435761u ^ sampleIndex * 2246822519u;
    proposalSeed = pcg(proposalSeed);
    // The medium the segment starts in. For the camera segment that is water when the eye is submerged
    // (so the first ray already carries the right relative index and absorption); for a segment split off
    // a dielectric it is whatever the parent was travelling through.
    MediumStack medium = seg.medium;
    bool waterWaves = waterWavesEnabled(); // animated wave-normal perturbation
    // Sky-disc gate (see world.rmiss): the sun/moon disc is shown to the primary ray and to rays spawned
    // by a specular/dielectric bounce (mirror reflections + refractions of the sun/moon), but hidden from
    // diffuse-sampled continuation rays — those are already covered by the sun NEE, so the tiny disc
    // would be a double-counted firefly. Reset true on every specular/water bounce, false on a diffuse one.
    bool showCelestial = seg.showCelestial;
    // Pass B treats every hit it sees as one indirect-depth step, regardless of material or selected
    // continuation lobe. Deliberately start at zero instead of seg.bounce: the first hit of either
    // queued split branch is still the primary-terminal shading point. Hits 0 and 1 retain SSS; RIS
    // remains active with its full configured candidate count at every hit. Pass A's primary/interface
    // prefix is outside this SSS quality budget.
    int indirectDepth = 0;
    for (int bounce = seg.bounce; bounce <= maxBounces; bounce++) {
        // Radiance SBT records run any-hit only for true alpha cutout. Translucent/water go straight to
        // closest-hit for dielectric handling. Geometry is double-sided; the chit flips the normal.
        // Primary (bounce 0) is the camera ray (CULL_PRIMARY): sees particles but not the first-person
        // player. Bounce rays are secondary (CULL_SECONDARY): exclude particles, include the player.
#ifdef CAUSTICA_ENABLE_EXT_SER
        // SER lifetime phase: keep paths that are not roulette-eligible, paths that may terminate via
        // roulette, and paths guaranteed to end at the bounce cap in separate coherence groups.
        uint pathPhaseHint = bounce >= maxBounces ? 2u : (bounce >= rrStart ? 1u : 0u);
        traceRadianceReordered(bounce == 0 ? CULL_PRIMARY : CULL_SECONDARY, ro, 0.0, rd, 10000.0,
                               showCelestial, rayConeWidth, rayConeSpread, pathPhaseHint);
#else
        traceRadiance(bounce == 0 ? CULL_PRIMARY : CULL_SECONDARY, ro, 0.0, rd, 10000.0,
                      showCelestial, rayConeWidth, rayConeSpread);
#endif

        if (payload.hitT < 0.0) {
            // world.rmiss writes sky radiance (gradient + sun/moon disc + stars) into payload.albedo. The
            // packed show-celestial flag decides whether this path segment may see the bright disc.
            float3 sky = payload.albedo;
            // No ambient fog on an escaping ray. The medium is what the path travels THROUGH to reach
            // something; the sky is not a surface at a distance, it is the far field itself, and each
            // dimension's skybox is already written as the appearance of that far field (the Nether's
            // haze dome, the End's void, the Overworld's own atmosphere march). Integrating the fog
            // over a nominal 10000-block escape on top of that would saturate — exp(-0.012 * 10000) is
            // zero — and replace every skybox with a flat fog colour, so the fog is deliberately scoped
            // to segments that actually end on geometry, where it is doing depth cueing.
            L += throughput * sky;
            break;
        }

        // Beer–Lambert: attenuate along the segment just travelled by the medium it lay inside. Applies
        // to every hit reached while inside a volume dielectric (its own exit face, or whatever content
        // lies within it), shifting the transmitted radiance with distance. Air's extinction is zero, so
        // the ordinary case costs one comparison.
        if (any(medium.current.extinction > 0.0)) {
            throughput *= exp(-medium.current.extinction * payload.hitT);
        }

        // Dimension-wide ambient fog over the same segment. Independent of the dielectric medium above:
        // that one describes what the path is submerged in (water, glass), this one the air of the
        // dimension itself, so a ray inside a Nether lava-lit cave picks up both. Added into L rather
        // than only attenuating, because the medium glows.
        {
            AmbientFog segFog = evalAmbientFog(worldPush.ambientFog, payload.hitT);
            L += throughput * segFog.inScatter;
            throughput *= segFog.transmittance;
        }

        // Cloud crossed on the way to this hit. The deck is a real volume in the world, so a ray that
        // ends on GEOMETRY can still pass through cloud before it gets there — looking down at the
        // ground from above the deck is exactly that case, and it is the one that was broken: clouds
        // were composited only in the miss shader, which a terrain hit never reaches, so the world
        // showed straight through them. Bounded by payload.hitT, so cloud in front of the surface is
        // drawn and cloud behind it is rejected.
        //
        // Written as the same in-scatter/transmittance pair as the fog directly above, because it is
        // the same kind of thing: a participating medium along this segment. Being in the path integral
        // rather than at a display seam is what makes it correct in reflections and refractions too.
        {
            // In a closed rain ceiling, do not composite the cloud slab over finite scene geometry. The
            // storm already darkens direct light and adds ambient rain fog; drawing the deck as a hard
            // volumetric wall where a camera ray first crosses cloud altitude creates the global
            // horizontal cut line reported in mountains and open terrain alike. Keep ordinary/patchy cloud
            // occlusion, and keep sky misses drawing the deck in world.rmiss.
            float closedStorm = closedStormCloudAmount(worldPush);
            if (closedStorm < 0.999) {
                // showCelestial marks the rays whose clouds are seen directly (camera + specular bounces),
                // so it selects the full march; diffuse continuations take the cheap one — see cloudSegment.
                CloudVolume segCloud = cloudSegment(worldPush, ro - worldPush.camOffset, rd,
                                                    payload.hitT, cloudSkyAmbient(worldPush),
                                                    showCelestial);
                segCloud.scatter *= 1.0 - closedStorm;
                segCloud.transmittance = lerp(segCloud.transmittance, 1.0, closedStorm);
                L += throughput * segCloud.scatter;
                throughput *= segCloud.transmittance;
            }
        }

        float3 n = payload.normal; // oriented toward the incoming ray by the closest-hit
        float3 hitPos = ro + rd * payload.hitT;
        rayConeWidth = max(rayConeWidth + rayConeSpread * max(payload.hitT, 0.0), RAY_CONE_MIN_WIDTH);
        uint material = payloadMaterial();
        int hitDepth = indirectDepth++;

        // ---- Dielectric interface: water, stained glass, ice. ONE handler and one behaviour — every
        // dielectric is a volume. Fresnel from the relative index across the face, then reflect or
        // refract; no diffuse response and no sun NEE, because the surface is specular. Transmission
        // pushes or pops a participating medium, and the segment travelled inside it is attenuated by
        // that medium's extinction rather than by a tint multiply at the interface.
        //
        // Water is the only material that adds anything: the animated wave normal, and a medium marked
        // for the caustic term. Which side of the face we are on comes from the geometry
        // (payloadDielectricEntering), so a stray or missing face cannot desync the medium for the rest
        // of the path.
        if (material == MATERIAL_WATER || material == MATERIAL_DIELECTRIC) {
            // A dielectric has no local shading term. At the path cap its continuation cannot be traced,
            // so avoid computing an unused Fresnel choice, medium update, and roulette step.
            if (bounce >= maxBounces) {
                break;
            }
            bool isWater = material == MATERIAL_WATER;
            bool entering = payloadDielectricEntering();
            float3 tint = payload.albedo;
            float transmission = clamp(payloadTransmission(), 0.0, 1.0);

            // Ripple the (near-flat) surface normal before any Fresnel/guide use → glints, broken
            // reflections, wobbling refraction. The wave domain is world-stable: rebased hit XZ plus the
            // pushed anchor (terrain origin mod 4096) survives the per-move terrain rebase.
            float3 geometricNormal = n; // unrippled; ray origins offset along this
            if (isWater && waterWaves) {
                float2 waterDomain = hitPos.xz + worldPush.waterAnchor.xy;
                float waterFootprint = rayConeWidth / max(abs(dot(-rd, geometricNormal)), 0.2);
                n = applyWaterWaves(geometricNormal, waterDomain,
                                    worldPush.waterParams.w, waterFootprint);
            }

            // The medium this face opens into, and the one it returns to on the way out — which is what
            // the stack remembers.
            Medium entered = makeDielectricMedium(isWater, max(payloadIor(), 1.0), tint, transmission);
            float etaI = medium.current.ior;
            float etaT = entering ? entered.ior : medium.outer.ior;

            float cosI = clamp(dot(-rd, n), 0.0, 1.0);
            float F = fresnelDielectric(cosI, etaI, etaT);
            float3 transmittedDir = refract(rd, n, etaI / etaT);
            // The translucent terrain layer is recessed by TRANSLUCENT_INSET (RtTerrainMesher), so a
            // glass/ice face touching a slab or stair sits a hair behind that neighbour's surface. A full
            // SURF_BIAS would restart the transmitted ray past the neighbour and see through it. Water
            // comes from the fluid mesher, which applies no inset, so it takes the ordinary bias.
            float transmitBias = isWater ? SURF_BIAS : INSET_TRANSMIT_BIAS;

            bool chooseReflection = rndf(seed) < F;
            if (chooseReflection) {
                rd = reflect(rd, n);
                ro = offsetSurfaceOrigin(hitPos, geometricNormal, rd, SURF_BIAS);
            } else {
                if (dot(transmittedDir, transmittedDir) <= 0.0) break; // TIR with F < 1 cannot happen
                rd = normalize(transmittedDir);
                ro = offsetSurfaceOrigin(hitPos, geometricNormal, rd, transmitBias);
                // Crossing into or out of the volume. Absorption is the medium's job from here, so the
                // tint is NOT also multiplied into the throughput — that would double-count it.
                if (entering) {
                    mediumPush(medium, entered);
                } else {
                    mediumPop(medium);
                }
            }
            showCelestial = true; // specular interface: the continuation ray may see the sun/moon disc
            if (bounce >= rrStart) {
                float q = clamp(max(throughput.r, max(throughput.g, throughput.b)), 0.02, 1.0);
                if (rndf(seed) > q) {
                    break;
                }
                throughput /= q;
            }
            continue;
        }

        // Particles (material == 2): camera-facing receiver billboard. The instance mask keeps particles
        // off secondary rays, so this only fires at bounce 0; they receive direct light and one diffuse
        // path continuation into the scene, but never appear in shadows/reflections/GI or emit radiance.
        if (material == MATERIAL_PARTICLE) {
            float3 albedo = payload.albedo;

            // Very thin rain/splash particles cannot rely solely on a nearly-extinguished storm sun;
            // give all particle billboards a modest sky/fog fill so falling rain remains visible while
            // still inheriting the overcast colour and per-segment fog already applied above.
            float particleStorm = worldFeature(worldPush, FEATURE_WEATHER_LIGHTING)
                    ? clamp(worldPush.weather.x + worldPush.weather.y * 0.5, 0.0, 1.0) : 0.0;
            float3 particleFill = cloudSkyAmbient(worldPush) * lerp(0.12, 0.36, particleStorm)
                    + worldPush.ambientFog.xyz * lerp(0.25, 0.85, particleStorm);
            L += throughput * albedo * particleFill;

            float3 lightDir = worldPush.lightDir.xyz;
            float lightHalfAngle = worldPush.lightDir.w;
            if (lightHalfAngle > 0.0) {
                lightDir = sampleSquare(lightDir, lightHalfAngle, seed);
            }
            // Billboards are effectively two-sided receivers. Bias from the side facing the light; shadow
            // rays exclude particles anyway, but this keeps the origin sane when the light is behind the
            // camera side. Same zero-radiance skip as the surface NEE below (Nether/End, or a fully
            // overcast sky with weather lighting on).
            bool particleCelestialLit = max(worldPush.lightRadiance.x,
                    max(worldPush.lightRadiance.y, worldPush.lightRadiance.z)) > 0.0;
            float signedNdl = dot(n, lightDir);
            float ndl = particleCelestialLit ? abs(signedNdl) : 0.0;
            if (ndl > 0.0) {
                float3 shadowOrigin = hitPos + (signedNdl >= 0.0 ? n : -n) * SURF_BIAS;
                float3 vis = visibility(shadowOrigin, lightDir, 10000.0).transmittance;
                if (max(vis.r, max(vis.g, vis.b)) > 0.0) {
                    // Particles are lit by the same sun as everything else, so they must dim under the
                    // same cloud. Do this only after scene visibility survives: an opaque house/wall has
                    // already removed the direct sun, and running the cloud attenuator on that fully
                    // blocked path is both wasted work and the overlap that made block shadows appear
                    // double-dark when ray-traced clouds were enabled.
                    vis *= cloudSunShadow(worldPush, hitPos - worldPush.camOffset, lightDir);
                    if (max(vis.r, max(vis.g, vis.b)) > 0.0) {
                        L += throughput * albedo * INV_PI * worldPush.lightRadiance.xyz * ndl * vis;
                    }
                }
            }

            float3 v = -rd;

            // RIS direct lighting from block emitters (lava, glowstone, torches, ...) — same reservoir
            // sampler as terrain/entities, but two-sided: a billboard has no back face, so light
            // striking either side of the quad should still land (matches the sun/moon NEE above).
            if (risOn) {
                bool shadeWithRestir = restirReceiverPending && restirOwner;
                bool skipSiblingRis = restirReceiverPending && !restirOwner;
                restirReceiverPending = false;
                if (!skipSiblingRis) {
                    uint freshCandidates = shadeWithRestir
                            ? min(worldPush.risCandidates, RESTIR_FRESH_CANDIDATES)
                            : worldPush.risCandidates;
                    Reservoir r = risInitial(hitPos, n, v, rd, albedo,
                            float3(0.0, 0.0, 0.0), 1.0, true, 0.0, freshCandidates,
                            seed, proposalSeed);
                    if (shadeWithRestir) {
                        r = restirSpatiotemporal(r, pix, dimensions, hitPos, payload.motionPrev,
                                n, v, rd, albedo, float3(0.0, 0.0, 0.0),
                                1.0, true, 0.0, seed);
                    }
                    float estimatorScale = shadeWithRestir ? restirSampleScale : 1.0;
                    L += throughput * shadeReservoir(r, hitPos, n, v, rd, albedo,
                            float3(0.0, 0.0, 0.0), 1.0, true, 0.0) * estimatorScale;
                }
            }

            if (bounce >= maxBounces) {
                break;
            }
            throughput *= albedo;
            ro = hitPos + n * SURF_BIAS;
            rd = cosineDir(n, seed);
            rayConeSpread = max(rayConeSpread, RAY_CONE_DIFFUSE_SPREAD);
            showCelestial = false; // diffuse receiver: direct sun/moon was handled by NEE above
            continue;
        }

        float3 albedo = payload.albedo;
        // Boat interior fix: detect dynamic entity (boat, minecart) early for two-sided lighting
        bool isDynamicEntityEarly = payloadDynamicEntity();
        // LabPBR SSS strength (0 when the material has none, or when the player turned SSS off:
        // payloadActiveSss returns a hard zero in that case, so every SSS term below — the RIS back
        // lobe and the explicit transmission pass — collapses without needing its own check).
        float sss = payloadActiveSss();
        float3 p = hitPos + n * SURF_BIAS;
        float3 v = -rd; // view direction (toward the camera / incoming ray)

        // Material split. Metals tint F0 by albedo and have no diffuse lobe; dielectrics use a fixed
        // 0.04 F0, sourced from the chit (LabPBR custom/metal F0, or the dielectric default it applies).
        float rough = clamp(payloadRoughness(), 0.0, 1.0);
        float metal = clamp(payloadMetalness(), 0.0, 1.0);
        // Unresolvably tight lobes become exact delta mirrors; everything else keeps its authored value.
        // Snapping to 0 also propagates into the guide buffers, which is what tells RR to hold the
        // reflection sharp instead of accumulating it as a glossy lobe.
        bool exactSpecular = isDeltaAlpha(rough);
        rough = exactSpecular ? 0.0 : rough;
        float3 diffAlb = albedo * (1.0 - metal);
        float3 F0 = payload.f0;

        // Emissive surfaces (lava, glowstone, torches, ...) add radiance directly, colored by albedo.
        // RIS emitter NEE: the direct-hit emission term is gated only for emitters RIS actually samples
        // (payload emitter-in-list bit) — and then only off diffuse continuation rays (showCelestial
        // false), which the previous vertex's RIS already accounted for; the primary ray and
        // specular/dielectric bounces (showCelestial true) still add it, since no emitter NEE happened
        // along those. Emitters NOT in the light buffer (sparse/sub-threshold footprints, entities) are
        // never NEE-sampled, so they always gather — bit-identical to the no-NEE path, no energy lost.
        // Emission is the material HDR baseline (EMISSIVE_STRENGTH * JSON override, baked in Java).
        // Apply the runtime global scale here so terrain blocks and dynamic entities can be adjusted
        // independently from the options menu.
        float emission = payloadEmission();
        // One gate drives both the RIS call below and the direct-hit emission suppression here. They must
        // agree: gateEmitter exists only because RIS already accounted for this emitter, so a bounce where
        // RIS is skipped must also gather emission directly or that light is lost outright.
        bool gateEmitter = risOn && payloadEmitterInList();
        if (emission > 0.0 && (!gateEmitter || showCelestial)) {
            float emissionScale = isDynamicEntityEarly ? worldPush.lightScales.y : worldPush.lightScales.x;
            L += throughput * albedo * emission * max(emissionScale, 0.0);
        }

        // NEE: direct light from the dominant celestial body (sun by day, moon by night) — Lambert
        // diffuse + GGX specular, one shadow ray. Jitter the light direction within its square angular
        // extent (worldPush.lightDir.w half-angle) so the shadow ray samples the light's quad — soft penumbrae
        // over accumulation. The same sampled direction drives ndl, the shadow ray, and the specular
        // half-vector.
        //
        // The radiance itself already carries the weather attenuation and the dimension's celestial
        // state: Java writes a zeroed lightRadiance in the Nether and the End (neither has a sun or a
        // moon) and a rain/thunder-scaled one in the Overworld. celestialLit therefore skips the whole
        // NEE block — including its shadow ray — wherever the celestial light cannot contribute, which
        // is every pixel of every Nether and End frame.
        bool celestialLit = max(worldPush.lightRadiance.x,
                max(worldPush.lightRadiance.y, worldPush.lightRadiance.z)) > 0.0;
        float3 lightDir = worldPush.lightDir.xyz;
        float lightHalfAngle = worldPush.lightDir.w;
        if (lightHalfAngle > 0.0) {
            lightDir = sampleSquare(lightDir, lightHalfAngle, seed);
        }
        // For dynamic entities (boat interior), use two-sided NDL so interior faces get sun/sky light
        float ndlRaw = dot(n, lightDir);
        float ndl = celestialLit ? (isDynamicEntityEarly ? abs(ndlRaw) : max(0.0, ndlRaw)) : 0.0;
        // Cloud occlusion of the celestial light at this shading point. It is shared lazily by the
        // front-face NEE below and the SSS transmission pass further down: both are the same sun arriving
        // at the same point, so a cloud that shades one must shade the other by exactly the same amount.
        // The important ordering is scene visibility FIRST, cloud visibility SECOND. If a house already
        // blocks the shadow ray, the direct-light path has zero throughput and the cloud query must not
        // stack another attenuation term on top of that fully blocked path. This keeps block/structure
        // shadows stable when the camera moves over them while ray-traced clouds are enabled.
        float cloudShadow = 1.0;
        bool cloudShadowReady = false;
        if (ndl > 0.0) {
            VisibilityResult shadow = visibility(p, lightDir, 10000.0);
            float3 vis = shadow.transmittance;
            if (max(vis.r, max(vis.g, vis.b)) > 0.0) {
                cloudShadow = cloudSunShadow(worldPush, hitPos - worldPush.camOffset, lightDir);
                cloudShadowReady = true;
                vis *= cloudShadow;
                // Underwater receiver whose shadow ray crossed a water surface: scale the direct light by
                // the wave-refraction caustic at the exit point. Focusing scales the incident irradiance,
                // so it applies to the whole NEE term (diffuse + specular).
                if (medium.current.water && waterWaves && shadow.waterHitT > 0.0) {
                    vis *= waterCaustic(p + lightDir * shadow.waterHitT, lightDir, shadow.waterHitT);
                }
                if (max(vis.r, max(vis.g, vis.b)) > 0.0) {
                    float3 brdf = diffAlb * INV_PI; // Lambertian diffuse (f = albedo/PI)
                    float3 h = normalize(lightDir + v);
                    float ndh = max(0.0, dot(n, h));
                    float ndv = max(1.0e-4, dot(n, v));
                    float vdh = max(0.0, dot(v, h));
                    float D = ggxD(ndh, rough);
                    float G = ggxG1(ndv, rough) * ggxG1(ndl, rough); // separable Smith masking
                    float3 F = fresnelSchlick(vdh, F0);
                    brdf += (D * G) * F / (4.0 * ndv * ndl); // Cook–Torrance specular
                    L += throughput * brdf * worldPush.lightRadiance.xyz * ndl * vis;
                }
            }
        }

        float activeSss = hitDepth <= MAX_SSS_INDIRECT_DEPTH ? sss : 0.0;

        // Boat interior fix: dynamic entities (boats, minecarts) have concave interior faces
        // where a single-sided NDL would be negative, causing black interior. Reuse early flag.
        bool twoSidedEmitter = isDynamicEntityEarly; // fix boat interior + minecart

        // Emitter direct lighting. In ReSTIR mode the owner sample shades the reused reservoir here and
        // sibling SPP samples omit this one receiver, so frame averaging contains the ReSTIR result rather
        // than silently blending it back toward RIS. OFF and deeper vertices execute the original RIS path.
        // Front lobe + SSS backlighting still share one shadow ray.
        if (risOn) {
            bool shadeWithRestir = restirReceiverPending && restirOwner;
            bool skipSiblingRis = restirReceiverPending && !restirOwner;
            restirReceiverPending = false;
            if (!skipSiblingRis) {
                uint freshCandidates = shadeWithRestir
                        ? min(worldPush.risCandidates, RESTIR_FRESH_CANDIDATES)
                        : worldPush.risCandidates;
                Reservoir r = risInitial(hitPos, n, v, rd, diffAlb, F0, rough, twoSidedEmitter,
                        activeSss, freshCandidates, seed, proposalSeed);
                if (shadeWithRestir) {
                    r = restirSpatiotemporal(r, pix, dimensions, hitPos, payload.motionPrev,
                            n, v, rd, diffAlb, F0, rough, twoSidedEmitter, activeSss, seed);
                }
                float estimatorScale = shadeWithRestir ? restirSampleScale : 1.0;
                L += throughput * shadeReservoir(r, hitPos, n, v, rd, diffAlb, F0, rough,
                        twoSidedEmitter, activeSss) * estimatorScale;
            }
        }

        // Thin-surface SSS transmission. Light entering from the back face scatters through toward the
        // viewer via a forward-biased HG phase (leaves/grass backlit by the sun glow when you look
        // through them toward the light source). Shadow ray fires from the back face to avoid
        // self-occlusion. cosT = dot(lightDir, rd): rd tracks the ray toward the sun when the sun is
        // behind the slab, giving cosT ≈ 1 → forward-scatter peak.
        if (sss > 0.0 && celestialLit && hitDepth <= MAX_SSS_INDIRECT_DEPTH) {
            float backNdl = max(0.0, dot(-n, lightDir));
            if (backNdl > 0.0) {
                VisibilityResult shadowBack = visibility(hitPos - n * SURF_BIAS, lightDir, 10000.0);
                float3 visB = shadowBack.transmittance;
                if (max(visB.r, max(visB.g, visB.b)) > 0.0) {
                    // Same cloud attenuation as the front-face NEE above — see cloudShadow. Compute it
                    // lazily if the front lobe was unlit or blocked, but only after this back-face scene
                    // visibility ray has proven that some direct light remains.
                    if (!cloudShadowReady) {
                        cloudShadow = cloudSunShadow(worldPush, hitPos - worldPush.camOffset, lightDir);
                        cloudShadowReady = true;
                    }
                    visB *= cloudShadow;
                    // Same caustic as the front-face NEE — underwater kelp/seagrass transmission should
                    // flicker with the same light bands as the floor around it.
                    if (medium.current.water && waterWaves && shadowBack.waterHitT > 0.0) {
                        visB *= waterCaustic(hitPos + lightDir * shadowBack.waterHitT,
                                             lightDir, shadowBack.waterHitT);
                    }
                    if (max(visB.r, max(visB.g, visB.b)) > 0.0) {
                        float cosT = dot(lightDir, rd);
                        L += throughput * diffAlb * sss * SSS_STRENGTH * hg(cosT, SSS_G) * backNdl * worldPush.lightRadiance.xyz * visB;
                    }
                }
            }
        }

        // Preserve all local lighting at the terminal hit, but do not sample a continuation that the
        // bounce loop cannot trace.
        if (bounce >= maxBounces) {
            break;
        }

        // Indirect continuation: importance-sample the diffuse OR the GGX specular lobe, chosen by their
        // relative reflectance.
        float ps = exactSpecular && luminance(diffAlb) <= 1.0e-6
                       ? 1.0
                       : clamp(luminance(F0) / (luminance(F0) + luminance(diffAlb) + 1.0e-4), 0.1, 0.9);
        if (rndf(seed) < ps) {
            float3 l;
            if (exactSpecular) {
                // Authored zero is a delta distribution, not a narrow finite GGX lobe. This avoids the
                // degenerate VNDF at alpha=0 and preserves a genuinely sharp reflection without a floor.
                l = reflect(rd, n);
                throughput *= fresnelSchlick(clamp(dot(n, v), 0.0, 1.0), F0) / ps;
            } else {
                float3 h = sampleGGXVNDF(n, v, rough, seed);
                l = reflect(rd, h); // rd = -v: reflect the incoming ray about the microfacet normal
                float ndl2 = dot(n, l);
                if (ndl2 <= 0.0) {
                    break; // microfacet reflects below the surface: terminate this path
                }
                // VNDF + separable Smith ⇒ weight = F · G2/G1(v) = F · G1(l); divide by the lobe pdf ps.
                float3 F = fresnelSchlick(max(0.0, dot(v, h)), F0);
                throughput *= F * ggxG1(ndl2, rough) / ps;
                rayConeSpread = max(rayConeSpread, rough * RAY_CONE_GLOSSY_SPREAD_SCALE);
            }
            ro = p;
            rd = l;
            showCelestial = true; // specular lobe: this ray is a (glossy) mirror — show the disc
        } else {
            throughput *= diffAlb / (1.0 - ps);
            ro = p;
            rd = cosineDir(n, seed);
            rayConeSpread = max(rayConeSpread, RAY_CONE_DIFFUSE_SPREAD);
            showCelestial = false; // diffuse lobe: disc covered by NEE, hide it (anti-firefly)
        }

        // Russian roulette on deeper bounces: survive with prob = max channel, rescale survivors.
        // Standard path tracing - no forced boost, let natural indirect do the work.
        if (bounce >= rrStart) {
            float q = clamp(max(throughput.r, max(throughput.g, throughput.b)), 0.02, 1.0);
            if (rndf(seed) > q) {
                break;
            }
            throughput /= q;
        }
    }
    return L;
}

[shader("raygeneration")]
void main() {
    worldPush = ConstPtr<WorldPush>(pc.worldPushAddr)[0];
    uint2 dispatchIndex = DispatchRaysIndex().xy;
    uint2 dimensions = DispatchRaysDimensions().xy;
    uint pixelIndex = dispatchIndex.y * dimensions.x + dispatchIndex.x;
    if (restirEnabled()) {
        // Every pixel owns exactly one record. Invalidate first so sky, a terminal dielectric, a debug
        // frame, or a frame with no emitters cannot leave stale current-buffer history behind.
        restirInvalidate(pixelIndex);
    }
    if (pc.debugView != 0u) {
        return; // pass A owns guide visualization output
    }
    int2 pix = int2(dispatchIndex);
    uint spp = max(worldPush.spp, 1u);
    ConstPtr<PackedPathSegment> queue = ConstPtr<PackedPathSegment>(pc.pathQueueAddr);
    float3 frameRadiance = float3(0.0, 0.0, 0.0);
    uint recordIndex = pixelIndex;
    for (uint leaf = 0u; leaf < MAX_PATH_SEGMENTS; ++leaf) {
        PackedPathSegment packed = queue[recordIndex];
        PathSegment segment = unpackPathSegment(packed);
        for (uint s = 0u; s < spp; ++s) {
            frameRadiance += tracePath(segment, uint2(pix), s + leaf * spp,
                    leaf == 0u, leaf == 0u && s == 0u, float(spp), dimensions);
        }
        if (packed.nextRecord == PATH_NO_NEXT) {
            break;
        }
        recordIndex = packed.nextRecord;
    }
    float3 radiance = frameRadiance / float(spp);
    // Firefly clamp for the raw (undenoised) view only — see UNDENOISED_FIREFLY_MAX_LUMINANCE. Scaling
    // the whole colour by the luminance ratio preserves hue and saturation, so a clamped highlight
    // desaturates toward nothing rather than shifting colour.
    if (!denoiserEnabled()) {
        float lum = luminance(radiance);
        if (lum > UNDENOISED_FIREFLY_MAX_LUMINANCE) {
            radiance *= UNDENOISED_FIREFLY_MAX_LUMINANCE / lum;
        }
    }
    outImage[pix] = float4(radiance, 1.0);
}
