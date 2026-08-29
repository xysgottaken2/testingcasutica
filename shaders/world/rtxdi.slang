// NVIDIA RTX Direct Illumination (RTXDI) integration — the application bridge.
//
// This module is Caustica's "RAB" bridge over the vendored RTXDI SDK core (shaders/rtxdi/Rtxdi,
// from https://github.com/NVIDIA-RTX/RTXDI). The SDK ships as a shader library that the application
// specializes through the RAB_* (Rtxdi Application Bridge) functions below plus a few resource
// macros, so this file is where Caustica's emitter model (the packed 32-byte rect Light records),
// its receiver surfaces and its camera reprojection meet NVIDIA's ReSTIR DI implementation:
//
//   initial sampling  RTXDI_SampleLightsForSurface     uniform light selection + uniform rect UV
//   reuse             RTXDI_DISpatioTemporalResampling fused pairwise-MIS spatio-temporal pass
//   storage           RTXDI_PackedDIReservoir          the SDK's own 24-byte block-linear layout
//   shading           one shadow ray + W               same estimator as lighting.shadeReservoir
//
// The RTXDI path is selected by pc.restirMode == 2 (the RTXDI toggle in the Video Settings screen)
// and runs at pass B's first stable receiver — exactly the slot the built-in ReSTIR occupies, so
// both engines stay feature-comparable (NRD lobe split, SSS receivers, estimator scaling) and the
// toggle is a true A/B between Caustica's hand-rolled reservoirs and the SDK's.
//
// Resource notes:
//   - RTXDI's reservoir buffer is one device buffer with two ping-pong array layers in the SDK's
//     16x16-block tiled layout (see RTXDI_ReservoirPositionToPointer); the layers are addressed
//     through rtxdiParams.y (previous frame, immutable) and rtxdiParams.z (this frame's stores).
//   - The fused pairwise resampler only ever queries G-buffer data for the PREVIOUS frame, and all
//     of it comes from RAB_GetGBufferSurface(..., previousFrame = true). Caustica has no persistent
//     previous-frame G-buffer, so the bridge stores a compact 32-byte receiver-surface record
//     (RtxdiSurfaceHistory) next to each reservoir instead — the same trick the built-in ReSTIR
//     uses when it packs surfacePos/surfaceNormal into PackedRestirReservoir. Current-frame queries
//     return an invalid surface: the fused pairwise path never issues them.
//   - Light indices are not stable across frames (the emitter buffer is rebuilt per frame), so
//     RAB_TranslateLightIndex validates history with the same light-generation lane the built-in
//     ReSTIR uses, and kills every stale index when the generation moves.

import world_common;
import world_core;
import math;
import trace;
import lighting;

// ---- SDK build configuration for this integration --------------------------------------
// Presampling (RIS tiles) and ReGIR are compiled out: initial candidates come from uniform
// selection over the whole light buffer, which is the SDK's no-presampling mode. Checkerboard
// rendering stays off (every pixel is shaded), and bias correction is pairwise MIS — the mode the
// fused spatio-temporal pass is built around, and the one that needs no resampling-time rays.
#define RTXDI_ENABLE_PRESAMPLING 0
#define RTXDI_LIGHT_RESERVOIR_BUFFER DevicePtr<RTXDI_PackedDIReservoir>(worldPush.rtxdiReservoirAddr)
#define RTXDI_NEIGHBOR_OFFSETS_BUFFER ConstPtr<float2>(worldPush.rtxdiNeighborOffsetsAddr)
#define RTXDI_ALLOWED_BIAS_CORRECTION RTXDI_BIAS_CORRECTION_PAIRWISE

#include "../rtxdi/Rtxdi/RtxdiTypes.h"
#include "../rtxdi/Rtxdi/RtxdiParameters.h"
// The SDK's DI core expects the application bridge to pre-include the random sampler state (the
// upstream sample's RtxdiBridge.hlsli does the same); it also pulls in Utils/Math.hlsli and the
// per-pass seed constants.
#include "../rtxdi/Rtxdi/Utils/RandomSamplerState.hlsli"
#include "../rtxdi/Rtxdi/DI/InitialSampling.hlsli"
#include "../rtxdi/Rtxdi/DI/SpatioTemporalResampling.hlsli"

// ---- Bridge types -----------------------------------------------------------------------

// The receiver the SDK resamples for: one pass-B shading vertex with every input the shared
// target function (lighting.evalSampleContrib) needs. Reconstructed for previous-frame pixels
// from RtxdiSurfaceHistory, so it must round-trip through that packing unchanged.
public struct RAB_Surface {
    public float3 worldPos;      // rebased world space (same space as hitPos everywhere else)
    public float3 normal;        // shading normal
    public float3 viewDir;       // toward the camera that observed this surface
    public float3 rayDir;        // the incident ray (v = -rayDir); feeds the SSS phase term
    public float3 diffuseAlbedo;
    public float3 specularF0;
    public float  roughness;     // linear (GGX alpha), the convention evalSampleContrib expects
    public float  sss;           // LabPBR subsurface amount
    public float  linearDepth;   // distance from the observing camera
    public bool   twoSided;      // dynamic-entity billboards shade both faces
    public bool   valid;
};

public struct RAB_Material {
    public float3 diffuseAlbedo;
    public float  roughness;
};

// A Caustica emitter record straight from the RIS light buffer (world_common.Light).
public struct RAB_LightInfo {
    public Light light;
    public bool  valid;
};

// One point on an emitter rectangle with its radiance and solid-angle pdf, the SDK's polymorphic
// light sample. solidAnglePdf = dist^2 / (cosL * area) — the exact inverse of the geometry factor
// evalSampleContrib applies, which is what makes the W/solidAnglePdf shading estimator and the
// target function agree.
public struct RAB_LightSample {
    public float3 position;
    public float3 radiance;      // already scaled by lightScales.x, like the RIS candidates
    public float3 normal;        // emitter geometric outward normal
    public float  area;
    public float  solidAnglePdf;
    public uint   packedLe;      // unscaled R11G11B10 source radiance (survives intensity changes)
    public bool   valid;
};

// Compact previous-frame receiver record, one per pixel next to each reservoir. Camera-relative
// positions so a terrain-origin rebase cannot invalidate stationary history (PackedRestirReservoir
// uses the same convention). The material dword packs rough/ssS/twoSided/valid around two rgb8
// colours; RtRtxdiLayout.SURFACE_HISTORY_BYTES mirrors the std430 stride on the Java side.
public struct RtxdiSurfaceHistory {
    public float4 posDepth;      // xyz camera-relative receiver position, w linear depth
    public uint4  material;      // x oct16 normal, y rgb8 albedo, z rgb8 F0, w packed scalars/flags
};

public static uint2 rtxdiScreen = uint2(0u, 0u); // render dimensions, set by rtxdiDirectLighting

// ---- Bridge: surfaces -------------------------------------------------------------------

public RAB_Surface RAB_EmptySurface() {
    RAB_Surface s;
    s.worldPos = float3(0.0, 0.0, 0.0);
    s.normal = float3(0.0, 0.0, 0.0);
    s.viewDir = float3(0.0, 0.0, 0.0);
    s.rayDir = float3(0.0, 0.0, 0.0);
    s.diffuseAlbedo = float3(0.0, 0.0, 0.0);
    s.specularF0 = float3(0.0, 0.0, 0.0);
    s.roughness = 1.0;
    s.sss = 0.0;
    s.linearDepth = 0.0;
    s.twoSided = false;
    s.valid = false;
    return s;
}

public bool RAB_IsSurfaceValid(RAB_Surface surface) {
    return surface.valid;
}

public float3 RAB_GetSurfaceWorldPos(RAB_Surface surface) {
    return surface.worldPos;
}

public void RAB_SetSurfaceWorldPos(inout RAB_Surface surface, float3 worldPos) {
    surface.worldPos = worldPos;
}

public float3 RAB_GetSurfaceNormal(RAB_Surface surface) {
    return surface.normal;
}

public void RAB_SetSurfaceNormal(inout RAB_Surface surface, float3 normal) {
    surface.normal = normal;
}

public float RAB_GetSurfaceLinearDepth(RAB_Surface surface) {
    return surface.linearDepth;
}

public float3 RAB_GetSurfaceViewDir(RAB_Surface surface) {
    return surface.viewDir;
}

public float RAB_GetSurfaceRoughness(RAB_Surface surface) {
    return surface.roughness;
}

public RAB_Material RAB_GetMaterial(RAB_Surface surface) {
    RAB_Material m;
    m.diffuseAlbedo = surface.diffuseAlbedo;
    m.roughness = surface.roughness;
    return m;
}

public bool RAB_AreMaterialsSimilar(RAB_Material a, RAB_Material b) {
    // The sample app compares packed albedo + roughness; blocky Minecraft materials are either
    // identical or worlds apart, so a generous tolerance keeps adjacent same-block faces merging
    // while different blocks never exchange reservoirs.
    float3 albedoDelta = a.diffuseAlbedo - b.diffuseAlbedo;
    return dot(albedoDelta, albedoDelta) <= 0.04
            && abs(a.roughness - b.roughness) <= 0.25;
}

uint rtxdiPackRgb8(float3 c) {
    uint3 q = uint3(saturate(c) * 255.0 + 0.5);
    return q.x | (q.y << 8u) | (q.z << 16u);
}

float3 rtxdiUnpackRgb8(uint p) {
    return float3(float(p & 0xffu), float((p >> 8u) & 0xffu), float((p >> 16u) & 0xffu)) / 255.0;
}

public int2 RAB_ClampSamplePositionIntoView(int2 pixelPosition, bool previousFrame) {
    // The RTXDI buffer dimensions never change mid-frame; the previous frame's view is clamped
    // against the same render size (a resize reallocates every RTXDI buffer anyway).
    int2 dims = int2(rtxdiScreen);
    return clamp(pixelPosition, int2(0, 0), max(dims - int2(1, 1), int2(0, 0)));
}

public RAB_Surface RAB_GetGBufferSurface(int2 pixelPosition, bool previousFrame) {
    if (!previousFrame) {
        // Current-frame G-buffer queries belong to the separate spatial-resampling passes, which
        // Caustica does not run: the fused pairwise pass is entirely previous-frame, so there is
        // nothing meaningful to return here. Reporting an invalid surface keeps any compiled-but-
        // unexecuted caller on the safe skip path.
        return RAB_EmptySurface();
    }
    uint2 dims = rtxdiScreen;
    if (any(pixelPosition < int2(0, 0)) || any(pixelPosition >= int2(dims))
            || worldPush.rtxdiSurfacePrevAddr == 0) {
        return RAB_EmptySurface();
    }
    RtxdiSurfaceHistory h = ConstPtr<RtxdiSurfaceHistory>(worldPush.rtxdiSurfacePrevAddr)[
            uint(pixelPosition.y) * dims.x + uint(pixelPosition.x)];
    uint packed = h.material.w;
    if ((packed & 0x80000000u) == 0u || !(h.posDepth.w > 0.0)) {
        return RAB_EmptySurface();
    }
    RAB_Surface s;
    // Records are relative to the camera that produced them: camDelta is current-minus-previous,
    // so this rebuilds last frame's rebased coordinates exactly like restirLoadCandidate does.
    s.worldPos = h.posDepth.xyz + worldPush.camOffset - worldPush.camDelta;
    s.normal = restirUnpackNormal(h.material.x);
    s.diffuseAlbedo = rtxdiUnpackRgb8(h.material.y);
    s.specularF0 = rtxdiUnpackRgb8(h.material.z);
    s.roughness = float(packed & 0xffu) / 255.0;
    s.sss = float((packed >> 8u) & 0xffu) / 255.0;
    s.twoSided = (packed & 0x10000u) != 0u;
    s.linearDepth = h.posDepth.w;
    // The camera that observed this surface sat at camOffset - camDelta in current rebased space.
    float3 previousCamera = worldPush.camOffset - worldPush.camDelta;
    s.viewDir = normalize(previousCamera - s.worldPos);
    s.rayDir = -s.viewDir;
    s.valid = true;
    return s;
}

// BRDF importance sampling is disabled in this integration (numBrdfSamples = 0): Minecraft's
// emitter population is sparse rect lights, where NEE candidate sampling dominates. The bridge
// functions still exist because the SDK's initial-sampling code references them.

bool RAB_SurfaceImportanceSampleBrdf(RAB_Surface surface, inout RTXDI_RandomSamplerState rng,
                                            out float3 sampleDir) {
    sampleDir = float3(0.0, 0.0, 0.0);
    return false;
}

float RAB_SurfaceEvaluateBrdfPdf(RAB_Surface surface, float3 outDir) {
    return 0.0;
}

bool RAB_GetSurfaceBrdfSample(RAB_Surface surface, inout RTXDI_RandomSamplerState rng,
                                     out float3 dir) {
    dir = float3(0.0, 0.0, 0.0);
    return false;
}

float RAB_GetSurfaceBrdfPdf(RAB_Surface surface, float3 dir) {
    return 0.0;
}

// ---- Bridge: lights ---------------------------------------------------------------------

public RAB_LightInfo RAB_EmptyLightInfo() {
    RAB_LightInfo i;
    Light empty = {};
    i.light = empty;
    i.valid = false;
    return i;
}

public RAB_LightInfo RAB_LoadLightInfo(uint index, bool previousFrame) {
    RAB_LightInfo i = RAB_EmptyLightInfo();
    if (index >= worldPush.lightCount || pc.lightBufAddr == 0) {
        return i;
    }
    // Caustica keeps a single light buffer that is rebuilt each frame. When the previous frame's
    // generation still matches (checked by RAB_TranslateLightIndex before any load), indices are
    // byte-identical between frames, so both frames read the same current record.
    i.light = ConstPtr<Light>(pc.lightBufAddr)[index];
    i.valid = true;
    return i;
}

public RAB_LightInfo RAB_LoadCompactLightInfo(uint linearIndex) {
    // Compact light storage belongs to the (compiled-out) presampling RIS tiles.
    return RAB_EmptyLightInfo();
}

public bool RAB_StoreCompactLightInfo(uint linearIndex, RAB_LightInfo lightInfo) {
    return false;
}

public int RAB_TranslateLightIndex(uint lightIndex, bool previousFrame) {
    if (lightIndex >= worldPush.lightCount) {
        return -1;
    }
    // Emitter records have no stable IDs across frames: the buffer is rebuilt in arbitrary order,
    // so an index is only meaningful when the light hierarchy that produced it is still live. The
    // generation lane in rtxdiParams.w carries the generation of the frame that wrote the history
    // buffers; on any mismatch every stored index is stale and all history is dropped — the same
    // rejection the built-in ReSTIR encodes into PackedRestirReservoir.meta.
    if ((worldPush.rtxdiParams.w & 0x7fu) != (pc.lightGeneration & 0x7fu)) {
        return -1;
    }
    return int(lightIndex);
}

public RAB_LightSample RAB_EmptyLightSample() {
    RAB_LightSample s;
    s.position = float3(0.0, 0.0, 0.0);
    s.radiance = float3(0.0, 0.0, 0.0);
    s.normal = float3(0.0, 0.0, 0.0);
    s.area = 0.0;
    s.solidAnglePdf = 0.0;
    s.packedLe = 0u;
    s.valid = false;
    return s;
}

public RAB_LightSample RAB_SamplePolymorphicLight(RAB_LightInfo lightInfo, RAB_Surface surface,
                                                  float2 uv) {
    RAB_LightSample s = RAB_EmptyLightSample();
    if (!lightInfo.valid) {
        return s;
    }
    Light lg = lightInfo.light;
    // (s,t) in [-1,1]^2 across the rectangle, pdf 1/area — identical to the RIS candidate
    // sampling in lighting.risInitial, so both engines sample the same light geometry.
    float2 st = uv * 2.0 - 1.0;
    float3 sp = lg.pos + worldPush.lightRebase.xyz
            + st.x * lightHalfU(lg) + st.y * lightHalfV(lg);
    float3 lightNormal = lightGeometricNormal(lg);
    float area = lightArea(lg);
    float3 toL = sp - surface.worldPos;
    float dist2 = dot(toL, toL);
    if (area <= 0.0 || dist2 < 1.0e-6) {
        return s;
    }
    float dist = sqrt(dist2);
    float3 wi = toL / dist;
    float cosL = max(0.0, dot(lightNormal, -wi));
    if (cosL <= 0.0) {
        return s; // sample faces away from the receiver
    }
    s.position = sp;
    s.normal = lightNormal;
    s.area = area;
    s.packedLe = lg.le;
    s.radiance = lightRadiance(lg) * max(worldPush.lightScales.x, 0.0);
    s.solidAnglePdf = dist2 / max(cosL * area, 1.0e-20);
    s.valid = true;
    return s;
}

public float3 RAB_LightSamplePosition(RAB_LightSample lightSample) {
    return lightSample.position;
}

public float3 RAB_LightSampleRadiance(RAB_LightSample lightSample) {
    return lightSample.radiance;
}

public bool RAB_IsAnalyticLightSample(RAB_LightSample lightSample) {
    return true; // every Caustica emitter is an analytic rectangle
}

public float RAB_LightSampleSolidAnglePdf(RAB_LightSample lightSample) {
    return lightSample.solidAnglePdf;
}

public float RAB_GetLightSampleTargetPdfForSurface(RAB_LightSample lightSample, RAB_Surface surface) {
    // The shared RIS target: the luminance of the full unshadowed Lambert+GGX(+SSS) contribution.
    // Using lighting's own evaluator is what keeps the RTXDI and RIS/ReSTIR engines optimizing
    // (and shading) exactly the same quantity.
    float phat;
    evalSampleContrib(lightSample.position, lightSample.normal, lightSample.radiance,
            lightSample.area, surface.worldPos, surface.normal, surface.viewDir, surface.rayDir,
            surface.diffuseAlbedo, surface.specularF0, surface.roughness, surface.twoSided,
            surface.sss, phat);
    return phat;
}

public float RAB_GetLightTargetPdfForVolume(RAB_LightInfo light, float3 volumeCenter, float volumeRadius) {
    // Volume importance drives ReGIR light-grid construction, which this integration compiles out;
    // a conservative power estimate keeps the contract honest for any future caller.
    if (!light.valid) {
        return 0.0;
    }
    float3 delta = light.light.pos + worldPush.lightRebase.xyz - volumeCenter;
    float distance = max(length(delta) - volumeRadius, 0.0);
    return lightArea(light.light) * luminance(lightRadiance(light.light))
            / max(distance * distance, 1.0);
}

public void RAB_GetLightDirDistance(RAB_Surface surface, RAB_LightSample lightSample,
                                    out float3 o_lightDir, out float o_lightDistance) {
    float3 toL = lightSample.position - surface.worldPos;
    o_lightDistance = length(toL);
    o_lightDir = o_lightDistance > 0.0 ? toL / o_lightDistance : float3(0.0, 0.0, 0.0);
}

public float RAB_EvaluateLocalLightSourcePdf(uint lightIndex) {
    // Only consulted by the (disabled) BRDF-sampling initial-sampling mode.
    return 0.0;
}

public float RAB_EvaluateEnvironmentMapSamplingPdf(float3 L) {
    return 0.0; // no environment-map light: the sky/sun stay on the existing celestial NEE path
}

public float2 RAB_GetEnvironmentMapRandXYFromDir(float3 worldDir) {
    return float2(0.0, 0.0);
}

public bool RAB_TraceRayForLocalLight(float3 origin, float3 direction, float tMin, float tMax,
                                      out uint o_lightIndex, out float2 o_randXY) {
    // BRDF-sampling support (numBrdfSamples = 0): reporting "hit nothing" keeps the compiled
    // branch inert without inventing hit data the trace cannot currently return.
    o_lightIndex = RTXDI_InvalidLightIndex;
    o_randXY = float2(0.0, 0.0);
    return false;
}

// ---- Bridge: visibility -----------------------------------------------------------------
// Resampling stays ray-free (pairwise MIS assumes visibility), exactly like the built-in ReSTIR;
// the single final shadow ray at shading time is traced by rtxdiShade below. These conservative
// tests only exist for SDK code paths that this integration never executes at runtime.

public bool RAB_GetConservativeVisibility(RAB_Surface surface, RAB_LightSample lightSample) {
    if (!surface.valid || !lightSample.valid || lightSample.solidAnglePdf <= 0.0) {
        return false;
    }
    float3 toL = lightSample.position - surface.worldPos;
    float dist = length(toL);
    if (dist <= 0.0) {
        return false;
    }
    VisibilityResult shadow = visibility(surface.worldPos, toL / dist, dist * 0.999);
    return max(shadow.transmittance.r, max(shadow.transmittance.g, shadow.transmittance.b)) > 0.0;
}

public bool RAB_GetTemporalConservativeVisibility(RAB_Surface currentSurface,
                                                  RAB_Surface previousSurface,
                                                  RAB_LightSample lightSample) {
    return RAB_GetConservativeVisibility(previousSurface, lightSample);
}

// ---- Integration ------------------------------------------------------------------------

RTXDI_LightBufferParameters rtxdiLightBufferParams() {
    RTXDI_LightBufferParameters p;
    p.localLightBufferRegion.firstLightIndex = 0u;
    p.localLightBufferRegion.numLights = worldPush.lightCount;
    p.localLightBufferRegion.pad1 = 0u;
    p.localLightBufferRegion.pad2 = 0u;
    p.infiniteLightBufferRegion.firstLightIndex = 0u;
    p.infiniteLightBufferRegion.numLights = 0u;
    p.infiniteLightBufferRegion.pad1 = 0u;
    p.infiniteLightBufferRegion.pad2 = 0u;
    p.environmentLightParams.lightPresent = 0u;
    p.environmentLightParams.lightIndex = 0u;
    p.environmentLightParams.pad1 = 0u;
    p.environmentLightParams.pad2 = 0u;
    return p;
}

RTXDI_ReservoirBufferParameters rtxdiReservoirParams(uint2 dimensions) {
    // RTXDI stores reservoirs in 16x16-pixel tiles (RTXDI_RESERVOIR_BLOCK_SIZE), tiled x-major
    // across the row, rows stacked to the layer. RtRtxdiLayout mirrors these pitches on the Java
    // side when sizing the buffer, so the two must stay in lockstep.
    RTXDI_ReservoirBufferParameters p;
    p.reservoirBlockRowPitch = uint(((dimensions.x + 15u) / 16u) * 256u);
    p.reservoirArrayPitch = p.reservoirBlockRowPitch * uint((dimensions.y + 15u) / 16u);
    p.pad1 = 0u;
    p.pad2 = 0u;
    return p;
}

// Screen-space motion in RTXDI's convention: xy = previous pixel position minus current one (in
// render pixels, before RTXDI's internal rounding), z = previous linear depth minus current. Built
// from the same prevViewProj reprojection restirPreviousPixel uses, including the object-motion
// compensation (payload.motionPrev) and the camera rebase (camDelta).
public float3 rtxdiScreenMotion(uint2 pixel, uint2 dimensions, float3 hitPos, float3 motionPrev) {
    float3 currentCameraRelative = hitPos - worldPush.camOffset;
    float3 previousCameraRelative = currentCameraRelative + worldPush.camDelta - motionPrev;
    float4 clip = mul(worldPush.prevViewProj, float4(previousCameraRelative, 1.0));
    if (clip.w <= 0.0) {
        return float3(1.0e6, 1.0e6, 0.0); // behind the previous camera: every lookup misses
    }
    float2 uv = clip.xy / clip.w * 0.5 + 0.5;
    float2 previousPixel = uv * float2(dimensions);
    float currentDepth = length(currentCameraRelative);
    float previousDepth = length(previousCameraRelative);
    return float3(previousPixel - float2(pixel), previousDepth - currentDepth);
}

void rtxdiStoreSurfaceHistory(RAB_Surface surface, uint pixelIndex) {
    if (worldPush.rtxdiSurfaceCurAddr == 0) {
        return;
    }
    RtxdiSurfaceHistory record;
    record.posDepth = float4(surface.worldPos - worldPush.camOffset, surface.linearDepth);
    record.material.x = restirPackNormal(surface.normal);
    record.material.y = rtxdiPackRgb8(surface.diffuseAlbedo);
    record.material.z = rtxdiPackRgb8(surface.specularF0);
    record.material.w = uint(saturate(surface.roughness) * 255.0 + 0.5)
            | (uint(saturate(surface.sss) * 255.0 + 0.5) << 8u)
            | (surface.twoSided ? 0x10000u : 0u)
            | (surface.valid ? 0x80000000u : 0u);
    DevicePtr<RtxdiSurfaceHistory>(worldPush.rtxdiSurfaceCurAddr)[pixelIndex] = record;
}

// Shade one finalized RTXDI reservoir: the SDK estimator is radiance * W / solidAnglePdf through
// the BRDF, which for this bridge is exactly evalSampleContribSplit * W — the same winning-sample
// estimate, shadow ray, firefly clamp and NRD lobe split as lighting.shadeReservoirSplit, so the
// RTXDI engine feeds the denoiser an identical signal.
void rtxdiShade(RTXDI_DIReservoir reservoir, RAB_LightSample lightSample, RAB_Surface surface,
                       out float3 outDiffuse, out float3 outSpecular) {
    outDiffuse = float3(0.0, 0.0, 0.0);
    outSpecular = float3(0.0, 0.0, 0.0);
    if (!RTXDI_IsValidDIReservoir(reservoir) || !lightSample.valid
            || lightSample.solidAnglePdf <= 0.0 || !(reservoir.weightSum > 0.0)) {
        return;
    }
    float phat;
    float3 diffPart;
    float3 specPart;
    evalSampleContribSplit(lightSample.position, lightSample.normal, lightSample.radiance,
            lightSample.area, surface.worldPos, surface.normal, surface.viewDir, surface.rayDir,
            surface.diffuseAlbedo, surface.specularF0, surface.roughness, surface.twoSided,
            surface.sss, phat, diffPart, specPart);
    if (phat <= 0.0) {
        return;
    }
    // Same biased-origin shadow ray as shadeReservoir: origin on the sample's side of the surface,
    // measured from that origin, stopped just short of the emitter face.
    float side = dot(surface.normal, lightSample.position - surface.worldPos) >= 0.0 ? 1.0 : -1.0;
    float3 origin = surface.worldPos + side * surface.normal * SURF_BIAS;
    float3 toL = lightSample.position - origin;
    float dist = length(toL);
    if (dist <= 0.0) {
        return;
    }
    VisibilityResult shadow = visibility(origin, toL / dist, dist * 0.999);
    float3 vis = shadow.transmittance;
    float3 shadedDiff = diffPart * vis * reservoir.weightSum;
    float3 shadedSpec = specPart * vis * reservoir.weightSum;
    // Firefly suppression: RTXDI's group boiling filter cannot run inside a ray-generation pass,
    // so the same luminance clamp the built-in ReSTIR applies at shading time caps outliers while
    // preserving hue.
    float shadedLuminance = luminance(shadedDiff + shadedSpec);
    if (!(shadedLuminance >= 0.0)) {
        return; // NaN estimate: reject outright
    }
    if (shadedLuminance > RESTIR_MAX_SAMPLE_LUMINANCE) {
        float scale = RESTIR_MAX_SAMPLE_LUMINANCE / shadedLuminance;
        shadedDiff *= scale;
        shadedSpec *= scale;
    }
    outDiffuse = shadedDiff;
    outSpecular = shadedSpec;
}

// The RTXDI engine entry point, called by world.rgen at the first stable receiver of the primary
// continuation (restirMode == 2). Runs initial sampling, the fused pairwise spatio-temporal reuse
// pass, stores the reservoir + surface history for next frame, and shades the survivor. Always
// stores — an empty reservoir is the pixel's valid "no light" state for the next frame.
public void rtxdiDirectLighting(uint2 pixel, uint2 dimensions,
                                float3 hitPos, float3 n, float3 v, float3 rd,
                                float3 diffAlb, float3 F0, float rough, bool twoSided, float sss,
                                float3 motionPrev, out float3 outDiffuse, out float3 outSpecular) {
    outDiffuse = float3(0.0, 0.0, 0.0);
    outSpecular = float3(0.0, 0.0, 0.0);
    rtxdiScreen = dimensions;

    // The receiving surface, in the SDK's terms.
    RAB_Surface surface;
    surface.worldPos = hitPos;
    surface.normal = n;
    surface.viewDir = v;
    surface.rayDir = rd;
    surface.diffuseAlbedo = diffAlb;
    surface.specularF0 = F0;
    surface.roughness = rough;
    surface.sss = sss;
    surface.linearDepth = length(hitPos - worldPush.camOffset);
    surface.twoSided = twoSided;
    surface.valid = true;

    RTXDI_RandomSamplerState rng = RTXDI_InitRandomSampler(pixel, worldPush.frameIndex,
            RTXDI_DI_GENERATE_INITIAL_SAMPLES_RANDOM_SEED);
    RTXDI_RandomSamplerState coherentRng = RTXDI_InitRandomSampler(
            pixel / RTXDI_TILE_SIZE_IN_PIXELS, worldPush.frameIndex,
            RTXDI_DI_GENERATE_INITIAL_SAMPLES_RANDOM_SEED);

    RTXDI_LightBufferParameters lightBufferParams = rtxdiLightBufferParams();
    RTXDI_DIInitialSamplingParameters initialSamplingParams;
    initialSamplingParams.numLocalLightSamples = max(1u, uint(worldPush.rtxdiSampling.x));
    initialSamplingParams.numInfiniteLightSamples = 0u;
    initialSamplingParams.numEnvironmentSamples = 0u;
    initialSamplingParams.numBrdfSamples = 0u;
    initialSamplingParams.brdfCutoff = 0.0;
    initialSamplingParams.brdfRayMinT = 0.0;
    initialSamplingParams.localLightSamplingMode = ReSTIRDI_LocalLightSamplingMode_UNIFORM;
    initialSamplingParams.enableInitialVisibility = 0u;
    initialSamplingParams.environmentMapImportanceSampling = 0u;
    initialSamplingParams.pad1 = 0u;
    initialSamplingParams.pad2 = 0u;
    initialSamplingParams.pad3 = 0u;

    RAB_LightSample lightSample;
    RTXDI_DIReservoir reservoir = RTXDI_SampleLightsForSurface(rng, coherentRng, surface,
            initialSamplingParams, lightBufferParams, lightSample);

    RTXDI_RuntimeParameters runtimeParams;
    runtimeParams.neighborOffsetMask = worldPush.rtxdiParams.x;
    runtimeParams.activeCheckerboardField = 0u;
    runtimeParams.frameIndex = worldPush.frameIndex;
    runtimeParams.pad2 = 0u;

    RTXDI_ReservoirBufferParameters reservoirParams = rtxdiReservoirParams(dimensions);

    RTXDI_DISpatioTemporalResamplingParameters reuseParams;
    reuseParams.depthThreshold = max(worldPush.rtxdiReuse.x, 1.0e-4);
    // Blocky world normals are axis aligned, so a looser threshold would happily merge
    // perpendicular faces; 0.9 keeps reuse on coplanar-ish surfaces like the built-in path.
    reuseParams.normalThreshold = saturate(worldPush.rtxdiReuse.y);
    reuseParams.biasCorrectionMode = RTXDI_BIAS_CORRECTION_PAIRWISE;
    reuseParams.maxHistoryLength = max(1u, uint(worldPush.rtxdiSampling.w));
    reuseParams.enablePermutationSampling = (uint(worldPush.rtxdiReuse.z) & 1u) != 0u ? 1u : 0u;
    reuseParams.uniformRandomNumber = worldPush.frameIndex * 747796405u + 2891336453u;
    reuseParams.enableVisibilityShortcut = 0u;
    reuseParams.numSamples = max(1u, uint(worldPush.rtxdiSampling.y));
    reuseParams.numDisocclusionBoostSamples = uint(worldPush.rtxdiReuse.w);
    reuseParams.samplingRadius = max(worldPush.rtxdiSampling.z, 1.0);
    reuseParams.enableMaterialSimilarityTest = (uint(worldPush.rtxdiReuse.z) & 2u) != 0u ? 1u : 0u;
    reuseParams.discountNaiveSamples = (uint(worldPush.rtxdiReuse.z) & 4u) != 0u ? 1u : 0u;

    float3 screenMotion = rtxdiScreenMotion(pixel, dimensions, hitPos, motionPrev);
    int2 temporalSamplePixelPos;
    reservoir = RTXDI_DISpatioTemporalResamplingWithPairwiseMIS(pixel, surface, reservoir, rng,
            screenMotion, worldPush.rtxdiParams.y, runtimeParams, reservoirParams, reuseParams,
            temporalSamplePixelPos, lightSample);

    rtxdiShade(reservoir, lightSample, surface, outDiffuse, outSpecular);

    // Persist this frame's reservoir (SDK packing, store layer) and the receiver surface record
    // that next frame's bridge lookups reconstruct RAB_Surface from.
    RTXDI_StoreDIReservoir(reservoir, reservoirParams, pixel, worldPush.rtxdiParams.z);
    rtxdiStoreSurfaceHistory(surface, pixel.y * dimensions.x + pixel.x);
}
