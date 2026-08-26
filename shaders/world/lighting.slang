// Direct lighting: the emitter light grid, RIS reservoirs, and reservoir shading.
// INDIRECT PASS ONLY — the primary pass shades nothing. Depends on trace and math.

// contribution weight, M the effective sample count. wSum/phat are streaming scratch (not persisted).

import world_common;
import world_core;
import math;
import trace;

public struct Reservoir {
    public float3 pos;  // light sample point (rebased world space)
    public float3 lnrm; // emitter outward normal
    public float3 le;   // emitter radiance after the current runtime scale
    public float area;  // emitter rectangle area (the area-light pdf factor)
    public float M;
    public float W;
    public float wSum;
    public float phat;
    public uint packedLe; // unscaled R11G11B10 source radiance; survives a live intensity change
    public uint age;
    // Runtime-only source receiver used to validate the connection Jacobian before history transfer.
    public float3 sourcePos;
    public float3 sourceNormal;
    public uint restir; // 1 after the bounded ReSTIR path has finalized the sample

    // Runtime-only ReSTCV payload carried with whichever historical representative wins resampling.
    // sourceW is that record's original finalized W; it lets the one current visibility result be
    // converted back to the source estimator's weight for a same-sample control difference.
    public float sourceW;
    public float3 cvEstimate;
    public float3 cvRepresentative;
    public float cvConfidence;
    public uint cvValid;
    // Validated centre history is a conservative fallback if the fresh sample wins the reservoir.
    public float3 cvFallbackEstimate;
    public float cvFallbackConfidence;
    public uint cvFallbackValid;
};

// Config values arrive through WorldPush, but hard shader limits remain as a final ABI/safety guard.
public static const float RESTIR_HARD_MAX_M = 64.0;
public static const float RESTIR_HARD_MAX_W = 64.0;
public static const float RESTIR_HARD_MAX_CONTRIBUTION = 128.0;
public static const uint RESTIR_HARD_MAX_SPATIAL_SAMPLES = 8u;
public static const uint RESTIR_HARD_MAX_AGE = 120u;
public static const float RESTIR_MIN_PHAT = 1.0e-4;
// Minimum importance floor to avoid aggressive discard of emissive samples like Shroomlight
// (prevents black spots / flicker from reservoirs dropping low-luma but valid emitters).
public static const float RESTIR_PHAT_EMISSIVE_FLOOR = 5.0e-3;
public static const uint RESTCV_RECORD_VERSION = 1u;

public uint restirFreshCandidates() {
    return uint(clamp(round(worldPush.restirBudgets.x), 1.0, 16.0));
}
public float restirTemporalMCap() {
    return clamp(round(worldPush.restirBudgets.y), 1.0, 16.0);
}
public float restirSpatialMCap() {
    return clamp(round(worldPush.restirBudgets.z), 1.0, 8.0);
}
public float restirMaxM() {
    return clamp(round(worldPush.restirBudgets.w), 1.0, RESTIR_HARD_MAX_M);
}
public uint restirSpatialSamples() {
    return uint(clamp(round(worldPush.restirReuse.x), 0.0,
            float(RESTIR_HARD_MAX_SPATIAL_SAMPLES)));
}
public float restirSpatialRadius() { return clamp(worldPush.restirReuse.y, 1.0, 16.0); }
public uint restirMaxAge() {
    return uint(clamp(round(worldPush.restirReuse.z), 0.0, float(RESTIR_HARD_MAX_AGE)));
}
public float restcvMaxConfidence() { return clamp(round(worldPush.restirReuse.w), 1.0, 64.0); }
public float restirMaxW() { return clamp(worldPush.restirStability.x, 1.0, RESTIR_HARD_MAX_W); }
public float restirContributionLimit() {
    return clamp(worldPush.restirStability.y, 4.0, RESTIR_HARD_MAX_CONTRIBUTION);
}
public float restirMaxWeightSum() {
    return restirMaxM() * restirMaxW() * restirContributionLimit();
}
public bool restirTemporalReuseEnabled() { return worldPush.restirTemporal.w >= 0.5; }
public bool restirSpatialReuseEnabled() { return worldPush.restirSpatial.w >= 0.5; }
public bool restcvEnabled() { return pc.restirMode == 2u; }

public Reservoir resEmpty() {
    Reservoir r;
    r.pos = float3(0.0, 0.0, 0.0);
    r.lnrm = float3(0.0, 0.0, 0.0);
    r.le = float3(0.0, 0.0, 0.0);
    r.area = 0.0;
    r.M = 0.0;
    r.W = 0.0;
    r.wSum = 0.0;
    r.phat = 0.0;
    r.packedLe = 0u;
    r.age = 0u;
    r.sourcePos = float3(0.0, 0.0, 0.0);
    r.sourceNormal = float3(0.0, 0.0, 0.0);
    r.restir = 0u;
    r.sourceW = 0.0;
    r.cvEstimate = float3(0.0, 0.0, 0.0);
    r.cvRepresentative = float3(0.0, 0.0, 0.0);
    r.cvConfidence = 0.0;
    r.cvValid = 0u;
    r.cvFallbackEstimate = float3(0.0, 0.0, 0.0);
    r.cvFallbackConfidence = 0.0;
    r.cvFallbackValid = 0u;
    return r;
}

// Unshadowed contribution of a fixed light sample point at surface (hitPos,n,v); out p-hat = its
// luminance (the resampling target). Evaluated from the UNBIASED hitPos — SURF_BIAS is applied only to
// the shadow-ray origin in shadeReservoir, on whichever side the survivor sample lands. Three receiver
// modes share one target function because they are mutually exclusive per candidate:
//   - front hemisphere (ndl>0): the same Lambert(+GGX) BRDF split the sun NEE uses;
//   - twoSided (particles): billboards have no back face, ndl=abs(ndl) folds both sides into the front;
//   - back hemisphere with sss>0 (LabPBR leaves/grass): HG transmission phase — cosT = dot(wi,rd) peaks
//     when the ray points from the light through the slab toward the camera (same as the sun SSS term).
// Split variant of the estimator above: bit-identical math and phat, but the diffuse (Lambert, SSS
// transmission) and specular (GGX) BRDF terms come out separately. NRD's REBLUR_DIFFUSE_SPECULAR
// needs per-lobe radiance; the ordinary path keeps using evalSampleContrib, which forwards here.
public float3 evalSampleContribSplit(float3 sp, float3 lnrm, float3 le, float area, float3 hitPos, float3 n,
                         float3 v, float3 rd, float3 diffAlb, float3 F0, float rough,
                         bool twoSided, float sss, out float phat, out float3 outDiff, out float3 outSpec) {
    phat = 0.0;
    outDiff = float3(0.0, 0.0, 0.0);
    outSpec = float3(0.0, 0.0, 0.0);
    float3 toL = sp - hitPos;
    float dist2 = dot(toL, toL);
    if (dist2 < 1.0e-6) {
        return float3(0.0, 0.0, 0.0);
    }
    float dist = sqrt(dist2);
    float3 wi = toL / dist;
    float cosL = max(0.0, dot(lnrm, -wi));
    if (cosL <= 0.0) {
        return float3(0.0, 0.0, 0.0); // receiver behind the emitter face
    }
    float ndl = dot(n, wi);
    if (twoSided) {
        ndl = abs(ndl);
    }
    float3 contrib = float3(0.0, 0.0, 0.0);
    if (ndl > 0.0) {
        float G = ndl * cosL / dist2; // area-light geometry term (x area)
        float3 brdfDiff = diffAlb * INV_PI;
        float3 brdfSpec = float3(0.0, 0.0, 0.0);
        // twoSided callers are particle billboards, which pass rough=1/F0=0 and want diffuse-only
        // shading: fresnelSchlick still returns up to full white at grazing angles even with F0=0 (that
        // IS the Fresnel effect), so skipping the term here — not just zeroing F0 — is what keeps
        // billboards from picking up a rim highlight they were never meant to have.
        if (!twoSided) {
            float3 h = normalize(wi + v);
            float ndh = max(0.0, dot(n, h));
            float ndv = max(1.0e-4, dot(n, v));
            float vdh = max(0.0, dot(v, h));
            float D = ggxD(ndh, rough);
            float Gs = ggxG1(ndv, rough) * ggxG1(ndl, rough);
            float3 Fs = fresnelSchlick(vdh, F0);
            brdfSpec = (D * Gs) * Fs / (4.0 * ndv * ndl);
        }
        outDiff = brdfDiff * le * (G * area);
        outSpec = brdfSpec * le * (G * area);
        contrib = outDiff + outSpec;
    } else if (sss > 0.0) {
        float backNdl = -ndl;
        float G = backNdl * cosL / dist2;
        float cosT = dot(wi, rd);
        outDiff = diffAlb * sss * SSS_STRENGTH * hg(cosT, SSS_G) * le * (G * area);
        contrib = outDiff;
    }
    float rawPhat = luminance(contrib);
    // If facing away and no SSS, this is truly unlit -> keep zero to allow culling.
    // Floor only applies when there is some front-facing contribution (even tiny) to avoid
    // aggressive discard of dim but valid emissives (Shroomlight fix).
    if (rawPhat <= 0.0) {
        phat = 0.0;
        outDiff = float3(0.0, 0.0, 0.0);
        outSpec = float3(0.0, 0.0, 0.0);
        return float3(0.0,0.0,0.0);
    }
    // Minimum importance floor: prevents aggressive discard of emissive samples like
    // Shroomlight / Redstone Lamp that may have low NDL but still carry visible energy.
    float emissiveFloor = luminance(le) * 0.01 * saturate(area / max(dist2, 1.0));
    phat = max(rawPhat, max(RESTIR_MIN_PHAT, max(emissiveFloor * 0.1, RESTIR_PHAT_EMISSIVE_FLOOR)));
    return contrib;
}

public float3 evalSampleContrib(float3 sp, float3 lnrm, float3 le, float area, float3 hitPos, float3 n,
                         float3 v, float3 rd, float3 diffAlb, float3 F0, float rough,
                         bool twoSided, float sss, out float phat) {
    float3 unusedDiff;
    float3 unusedSpec;
    return evalSampleContribSplit(sp, lnrm, le, area, hitPos, n, v, rd, diffAlb, F0, rough,
            twoSided, sss, phat, unusedDiff, unusedSpec);
}


// Select one light from the emitted-power distribution in O(1).
public void selectGlobalLight(inout uint proposalSeed, out uint lightIndex) {
    float aliasSample = rndf(proposalSeed) * float(worldPush.lightCount);
    uint column = min(uint(aliasSample), worldPush.lightCount - 1u);
    if (pc.lightAliasAddr != 0) {
        LightAlias a = ConstPtr<LightAlias>(pc.lightAliasAddr)[column];
        bool self = aliasSample - float(column) < a.accept;
        lightIndex = self ? column : a.aliasIndex;
    } else {
        lightIndex = column;
    }
}

public bool findLightGridCell(float3 p, out LightGridCell cell, out int3 cellCoord) {
    cell.spanOffset = 0u;
    cell.spanCount = 0u;
    cell.invWeightSum = 0.0;
    cellCoord = int3(0, 0, 0);
    if (pc.lightGridCellAddr == 0 || pc.lightGridSpanAddr == 0) return false;
    int3 coord = int3(floor((p - worldPush.lightGridOrigin.xyz) / worldPush.lightGridOrigin.w));
    if (coord.x < 0 || coord.y < 0 || coord.z < 0
            || coord.x >= worldPush.lightGridDims.x
            || coord.y >= worldPush.lightGridDims.y
            || coord.z >= worldPush.lightGridDims.z) return false;
    uint linear = (uint(coord.z) * uint(worldPush.lightGridDims.y) + uint(coord.y))
            * uint(worldPush.lightGridDims.x) + uint(coord.x);
    cell = ConstPtr<LightGridCell>(pc.lightGridCellAddr)[linear];
    cellCoord = coord;
    return cell.spanCount > 0u;
}

public void selectSectionLight(uint firstLight, uint lightCount, inout uint proposalSeed,
                        out uint lightIndex) {
    float aliasSample = rndf(proposalSeed) * float(lightCount);
    uint column = min(uint(aliasSample), lightCount - 1u);
    LightAlias alias = ConstPtr<LightAlias>(pc.lightLocalAliasAddr)[firstLight + column];
    bool self = aliasSample - float(column) < alias.accept;
    uint localIndex = self ? column : alias.aliasIndex;
    lightIndex = firstLight + localIndex;
}

public float unpackUnsignedFloat(uint bits, uint mantissaBits) {
    uint mantissaMask = (1u << mantissaBits) - 1u;
    uint mantissa = bits & mantissaMask;
    uint exponent = (bits >> mantissaBits) & 31u;
    if (exponent == 0u) {
        return float(mantissa) * exp2(float(1 - 15 - int(mantissaBits)));
    }
    return (1.0 + float(mantissa) / float(1u << mantissaBits))
            * exp2(float(int(exponent) - 15));
}

public float3 lightRadiancePacked(uint packed) {
    return float3(unpackUnsignedFloat(packed & 0x7ffu, 6u),
            unpackUnsignedFloat((packed >> 11u) & 0x7ffu, 6u),
            unpackUnsignedFloat((packed >> 22u) & 0x3ffu, 5u));
}

// Common late bound for independent RIS, legacy ReSTIR and ReSTCV. Applying it before the estimate
// reaches radiance or temporal history is the important part: disabling ReSTIR no longer disables the
// firefly guard. The !(x <= limit) form rejects NaN and infinity without relying on vector isfinite().
public float3 restirBoundContribution(float3 value, float limit) {
    if (!(abs(value.x) <= 1.0e20 && abs(value.y) <= 1.0e20 && abs(value.z) <= 1.0e20)) {
        return float3(0.0, 0.0, 0.0);
    }
    value = max(value, float3(0.0, 0.0, 0.0));
    float valueLuminance = luminance(value);
    if (!(valueLuminance >= 0.0 && valueLuminance <= 1.0e20)) {
        return float3(0.0, 0.0, 0.0);
    }
    float safeLimit = clamp(limit, 0.0, RESTIR_HARD_MAX_CONTRIBUTION);
    if (safeLimit > 0.0 && valueLuminance > safeLimit) {
        value *= safeLimit / valueLuminance;
    }
    return value;
}

// R11G11B10 has the same five-bit exponent/bias as IEEE half. Convert to half first, round away the
// discarded mantissa bits, and clamp exponent 31 back to the maximum finite encoding. This gives the
// two ReSTCV RGB records a compact 4-byte positive-HDR representation with deterministic decoding.
public uint restcvPackPositiveHdr(float3 value) {
    value = min(max(value, float3(0.0, 0.0, 0.0)), float3(HALF_MAX, HALF_MAX, HALF_MAX));
    uint rh = f32tof16(value.x) & 0x7fffu;
    uint gh = f32tof16(value.y) & 0x7fffu;
    uint bh = f32tof16(value.z) & 0x7fffu;
    uint r = min((rh + 8u) >> 4u, 0x7bfu);
    uint g = min((gh + 8u) >> 4u, 0x7bfu);
    uint b = min((bh + 16u) >> 5u, 0x3dfu);
    return r | (g << 11u) | (b << 22u);
}

public float3 restcvUnpackPositiveHdr(uint packed) {
    return lightRadiancePacked(packed);
}

public float3 lightRadiance(Light light) {
    return lightRadiancePacked(light.le);
}

public int3 lightSectionCoord(Light light) {
    uint packed = light.section;
    return int3(int(packed & 0x3ffu), int((packed >> 10u) & 0x3ffu),
            int((packed >> 20u) & 0x3ffu));
}

// The half axes share three lanes two-at-a-time; see the Light record in world_common.
public float3 lightHalfU(Light light) {
    return float3(unpackHalf2(light.halfUxy), unpackHalf2(light.halfUzVx).x);
}

public float3 lightHalfV(Light light) {
    return float3(unpackHalf2(light.halfUzVx).y, unpackHalf2(light.halfVyz));
}

// U x V drives both the emitter normal and the rectangle area, so it is computed once and shared.
public float3 lightCrossUV(Light light) {
    return cross(lightHalfU(light), lightHalfV(light));
}

// The rect spans 2U x 2V, so its area is 4|U x V| — exactly the rectArea the collector used to store.
public float lightArea(Light light) {
    return 4.0 * length(lightCrossUV(light));
}

public float3 lightGeometricNormal(Light light) {
    float3 normal = normalize(lightCrossUV(light));
    return (light.section & 0x40000000u) != 0u ? -normal : normal;
}

public float proposalPdf(Light light, float3 le, LightGridCell cell, int3 cellCoord,
                  float localProbability) {
    float power = max(0.0, lightArea(light) * luminance(le));
    float globalPdf = pc.lightAliasAddr != 0
            ? power * worldPush.lightRebase.w : 1.0 / float(worldPush.lightCount);
    float localPdf = 0.0;
    if (localProbability > 0.0 && power > 0.0) {
        int3 delta = lightSectionCoord(light) - cellCoord;
        if (all(abs(delta) <= int3(2, 2, 2))) {
            float3 deltaF = float3(delta);
            localPdf = power * cell.invWeightSum / max(1.0, dot(deltaF, deltaF));
        }
    }
    return localProbability * localPdf + (1.0 - localProbability) * globalPdf;
}

public void selectLightGridSpanLight(LightGridCell cell, inout uint proposalSeed,
                              out uint lightIndex) {
    ConstPtr<LightGridSpan> spans = ConstPtr<LightGridSpan>(pc.lightGridSpanAddr);
    float aliasSample = rndf(proposalSeed) * float(cell.spanCount);
    uint column = min(uint(aliasSample), cell.spanCount - 1u);
    LightGridSpan span = spans[cell.spanOffset + column];
    bool self = aliasSample - float(column) < span.accept;
    uint firstLight = self ? span.firstLight : span.aliasFirstLight;
    uint lightCount = self ? (span.packedLightCounts & 0xffffu)
            : (span.packedLightCounts >> 16u);
    selectSectionLight(firstLight, lightCount, proposalSeed, lightIndex);
}

// Sample the exact mixture q = alpha*qCell + (1-alpha)*qGlobal. qCell first selects a nearby section
// by emitted power and section distance, then its section-local power alias. Every light in
// the neighborhood is represented without a fixed cap; qGlobal gives distant lights full support.
// Alias spans make weighted local selection O(1). The mixture PDF is reconstructed after the single
// Light48 load: section power cancels with the section-local light PDF.
public void selectLightGridLight(LightGridCell cell, bool useLocal, inout uint proposalSeed,
                          out uint lightIndex) {
    if (useLocal) {
        selectLightGridSpanLight(cell, proposalSeed, lightIndex);
    } else {
        selectGlobalLight(proposalSeed, lightIndex);
    }
}

// ---- RIS cost profile. Temporary probes pinned the candidate walk out of the shader to bound what
// memory-side RIS work could ever be worth. Against an
// 18.0ms frame at M=8, removing every dependent load (span -> alias -> record) and all lane divergence
// saved 5.9ms — a third of the frame. Split by vertex that was ~4.3ms at secondary vertices against
// ~1.1ms at the primary hit, and forcing coherent selection recovered at most 1.3ms of it. So the cost
// was chasing depth, not divergence, and it lived at secondary vertices. A presampled candidate pool
// would attack the same 5.9ms structurally, but see the note on
// proposalSeed in tracePath for why it should share the pool rather than the seed.

// Initial RIS over M power-weighted candidates -> one resampled sample, no shadow ray yet. The chosen
// sample's W = wSum / (M * p-hat); M counts every candidate, including zero-weight ones.
public Reservoir risInitial(float3 hitPos, float3 n, float3 v, float3 rd, float3 diffAlb, float3 F0,
                     float rough, bool twoSided, float sss, uint requestedCandidateCount,
                     inout uint seed, inout uint proposalSeed) {
    Reservoir r = resEmpty();
    r.sourcePos = hitPos;
    r.sourceNormal = n;
    LightGridCell gridCell;
    int3 gridCellCoord;
    float3 gridLookup = hitPos;
    if (pc.lightGridCellAddr != 0) {
        // Stochastically blend across hard section boundaries. Every cell proposal retains full global
        // support, so conditioning on this independently jittered lookup remains unbiased.
        gridLookup += (float3(rndf(proposalSeed), rndf(proposalSeed), rndf(proposalSeed)) - 0.5)
                * worldPush.lightGridOrigin.w;
    }
    bool hasGridCell = findLightGridCell(gridLookup, gridCell, gridCellCoord);
    uint candidateCount = min(max(requestedCandidateCount, 1u), worldPush.risCandidates);
    r.M = float(candidateCount);
    // Deterministically stratify the proposal mixture. At the default M=8 this schedules exactly six
    // local and two global candidates, with every lane taking the same branch for a given candidate.
    // Counts that are not divisible by four use the nearest practical split with at least one global
    // candidate; M=1 is global-only so the estimator retains full support.
    uint globalCandidateCount = hasGridCell
            ? max(1u, (candidateCount + 2u) / 4u) : candidateCount;
    uint localCandidateCount = candidateCount - globalCandidateCount;
    float localProbability = float(localCandidateCount) / float(candidateCount);
    for (uint c = 0u; c < candidateCount; c++) {
        uint li;
        uint globalsBefore = (c * globalCandidateCount) / candidateCount;
        uint globalsAfter = ((c + 1u) * globalCandidateCount) / candidateCount;
        bool useLocal = hasGridCell && globalsAfter == globalsBefore;
        selectLightGridLight(gridCell, useLocal, proposalSeed, li);
        Light lg = ConstPtr<Light>(pc.lightBufAddr)[li];
        // Soft shadows: uniform point on the emitter rectangle ((s,t) in [-1,1]^2, pdf 1/area).
        float s = rndf(seed) * 2.0 - 1.0;
        float t = rndf(seed) * 2.0 - 1.0;
        float3 sp = lg.pos + worldPush.lightRebase.xyz
                + s * lightHalfU(lg) + t * lightHalfV(lg);
        float3 rawLe = lightRadiance(lg);
        float3 le = rawLe * max(worldPush.lightScales.x, 0.0);
        float3 lightNormal = lightGeometricNormal(lg);
        float area = lightArea(lg);
        float phat;
        evalSampleContrib(sp, lightNormal, le, area, hitPos, n, v, rd,
                diffAlb, F0, rough, twoSided, sss, phat);
        if (!(phat > 0.0 && phat <= 1.0e20)) {
            continue;
        }
        float sourcePdf = proposalPdf(lg, rawLe, gridCell, gridCellCoord, localProbability);
        float w = phat / max(sourcePdf, 1.0e-20);
        if (!(w > 0.0 && w <= 1.0e20)) {
            continue;
        }
        r.wSum = min(r.wSum + w, 1.0e20);
        if (rndf(seed) * r.wSum < w) { // weighted reservoir update
            r.pos = sp;
            r.lnrm = lightNormal;
            r.le = le;
            r.area = area;
            r.phat = phat;
            r.packedLe = lg.le;
            r.age = 0u;
        }
    }
    r.W = r.phat > 0.0 ? (r.wSum / (r.M * r.phat)) : 0.0;
    return r;
}

// ---- ReSTIR DI/GI history ---------------------------------------------------------------
//
// The first emitter-lighting vertex of the primary continuation is stable enough to reproject. It is
// direct illumination at an ordinary camera hit and transported indirect illumination when the primary
// pass handed us a reflection/refraction continuation. Deeper random-walk vertices keep independent RIS:
// their screen-space identity is not stable, and pretending otherwise causes much worse ghosting than the
// variance it removes. Four validated neighbours from the PREVIOUS buffer provide spatial reuse without
// a same-dispatch read/write race; the reprojected centre provides temporal reuse.

public float2 restirOctEncode(float3 direction) {
    float3 n = direction / max(abs(direction.x) + abs(direction.y) + abs(direction.z), 1.0e-20);
    float2 signNotZero = float2(n.x >= 0.0 ? 1.0 : -1.0, n.y >= 0.0 ? 1.0 : -1.0);
    float2 oct = n.z >= 0.0 ? n.xy : (1.0 - abs(n.yx)) * signNotZero;
    return oct * 0.5 + 0.5;
}

public float3 restirOctDecode(float2 encoded) {
    float2 oct = encoded * 2.0 - 1.0;
    float3 n = float3(oct, 1.0 - abs(oct.x) - abs(oct.y));
    if (n.z < 0.0) {
        float2 signNotZero = float2(n.x >= 0.0 ? 1.0 : -1.0, n.y >= 0.0 ? 1.0 : -1.0);
        n.xy = (1.0 - abs(n.yx)) * signNotZero;
    }
    return normalize(n);
}

public uint restirPackNormal(float3 n) {
    uint2 q = uint2(round(clamp(restirOctEncode(normalize(n)), 0.0, 1.0) * 65535.0));
    return q.x | (q.y << 16u);
}

public float3 restirUnpackNormal(uint p) {
    return restirOctDecode(float2(p & 0xffffu, p >> 16u) / 65535.0);
}

public void restirInvalidate(uint pixelIndex) {
    if (pc.restirCurrentAddr == 0) return;
    PackedRestirReservoir record = {};
    record.meta = 0u;
    DevicePtr<PackedRestirReservoir>(pc.restirCurrentAddr)[pixelIndex] = record;
}

public bool restirLoadCandidate(PackedRestirReservoir record, float3 expectedPreviousSurface,
                         float3 currentNormal, bool twoSided, float maxPositionDelta,
                         float minNormalDot, out Reservoir candidate) {
    candidate = resEmpty();
    uint storedM = record.meta & 0xffffu;
    uint age = (record.meta >> 16u) & 0xffu;
    uint generation = (record.meta >> 24u) & 0x7fu;
    bool storedTwoSided = (record.meta & 0x80000000u) != 0u;
    uint maximumAge = restirMaxAge();
    if (storedM == 0u || (maximumAge > 0u && age >= maximumAge) || storedTwoSided != twoSided
            || generation != (pc.lightGeneration & 0x7fu)
            || !(record.W > 0.0) || !(record.area > 0.0)) {
        return false; // the !(x>0) form rejects NaN as well as zero/negative values
    }

    // Records are relative to the camera that produced them. camDelta is current-minus-previous, so
    // this reconstructs both old positions in the current terrain-rebased coordinate system.
    float3 previousSurface = record.surfaceCameraRelative
            + worldPush.camOffset - worldPush.camDelta;
    float3 previousNormal = restirUnpackNormal(record.surfaceNormal);
    float positionDelta = length(previousSurface - expectedPreviousSurface);
    float normalAgreement = dot(previousNormal, currentNormal);
    if (!(positionDelta <= maxPositionDelta && normalAgreement >= minNormalDot)) {
        return false; // also rejects non-finite reconstructed geometry
    }

    candidate.pos = record.sampleCameraRelative + worldPush.camOffset - worldPush.camDelta;
    candidate.lnrm = restirUnpackNormal(record.sampleNormal);
    candidate.packedLe = record.packedLe;
    candidate.le = lightRadiancePacked(record.packedLe) * max(worldPush.lightScales.x, 0.0);
    candidate.area = record.area;
    candidate.M = min(float(storedM), restirMaxM());
    candidate.W = min(record.W, restirMaxW());
    candidate.age = age;
    candidate.sourcePos = previousSurface;
    candidate.sourceNormal = previousNormal;
    candidate.sourceW = candidate.W;

    uint cvConfidence = record.cvMeta & 0xffu;
    uint cvVersion = (record.cvMeta >> 16u) & 0xffu;
    bool cvStored = (record.cvMeta & 0x100u) != 0u;
    float blockScale = max(worldPush.lightScales.x, 0.0);
    if (cvStored && cvVersion == RESTCV_RECORD_VERSION && cvConfidence > 0u && blockScale > 1.0e-6) {
        candidate.cvEstimate = restirBoundContribution(
                restcvUnpackPositiveHdr(record.packedCvEstimate) * blockScale,
                restirContributionLimit());
        candidate.cvRepresentative = restirBoundContribution(
                restcvUnpackPositiveHdr(record.packedCvRepresentative) * blockScale,
                restirContributionLimit());
        candidate.cvConfidence = min(float(cvConfidence), restcvMaxConfidence());
        candidate.cvValid = 1u;
    }
    return true;
}

// Area-measure connection geometry. The ratio G(current)/G(source) is the transfer Jacobian for the
// same emitter point seen from two receivers. We do not multiply by it (the target is re-evaluated in
// the same light-area sample domain); it is a strict disocclusion/grazing-angle validity test.
public bool restirConnectionGeometry(float3 samplePos, float3 sampleNormal,
                              float3 receiverPos, float3 receiverNormal, out float geometry) {
    geometry = 0.0;
    float3 toLight = samplePos - receiverPos;
    float dist2 = dot(toLight, toLight);
    if (!(dist2 >= 1.0e-6 && dist2 <= 1.0e8)) return false;
    float3 wi = toLight * rsqrt(dist2);
    float lightCosine = max(0.0, dot(sampleNormal, -wi));
    // abs supports both the particle's two-sided target and the SSS back lobe. Hemisphere/material
    // eligibility is still decided by evalSampleContrib at the current receiver.
    float receiverCosine = abs(dot(receiverNormal, wi));
    geometry = lightCosine * receiverCosine / dist2;
    return geometry >= 1.0e-8 && geometry <= 1.0e6;
}

public bool restirValidJacobian(Reservoir source, float3 hitPos, float3 n) {
    float sourceGeometry;
    float currentGeometry;
    if (!restirConnectionGeometry(source.pos, source.lnrm,
            source.sourcePos, source.sourceNormal, sourceGeometry)
            || !restirConnectionGeometry(source.pos, source.lnrm,
                    hitPos, n, currentGeometry)) {
        return false;
    }
    float jacobian = currentGeometry / sourceGeometry;
    float configuredMin = clamp(worldPush.restirStability.z, 0.01, 1.0);
    float configuredMax = clamp(worldPush.restirStability.w, 1.0, 10.0);
    float minJacobian = min(configuredMin, configuredMax);
    float maxJacobian = max(configuredMin, configuredMax);
    // Both comparisons are false for NaN; infinity also falls outside the upper bound.
    return jacobian >= minJacobian && jacobian <= maxJacobian;
}

// Combine one already-finalized source reservoir at the CURRENT receiver. The source's representative
// stands for source.M candidates, therefore its resampling weight is pHat_current * W * M. All three
// factors are bounded before entering the stream; invalid Jacobians and near-zero targets are discarded
// rather than allowed to manufacture a huge reciprocal weight in finalization.
//
// Positive targets below MIN_PHAT are clamped to a small floor so dim emissives keep contributing.
// Exact zero/invalid targets remain rejected; assigning them weight lets a sample that shades to black win.
public void restirMerge(inout Reservoir dst, Reservoir source, float maxM,
                 float3 hitPos, float3 n, float3 v, float3 rd, float3 diffAlb, float3 F0,
                 float rough, bool twoSided, float sss, inout uint seed) {
    float configuredMaxM = restirMaxM();
    float acceptedM = min(source.M, max(0.0, min(maxM, configuredMaxM) - dst.M));
    float sourceW = min(source.W, restirMaxW());
    if (!(acceptedM > 0.0 && sourceW > 0.0) || !restirValidJacobian(source, hitPos, n)) return;

    float target;
    evalSampleContrib(source.pos, source.lnrm, source.le, source.area,
            hitPos, n, v, rd, diffAlb, F0, rough, twoSided, sss, target);
    // A strictly positive dim target gets the emissive floor, but a true zero must be rejected. The
    // old "strong emitter" exception promoted behind-face/invalid connections to a positive weight;
    // those representatives then won and shaded to zero, causing black block-light flicker.
    if (!(target > 0.0)) return;
    float floorPhat = max(RESTIR_MIN_PHAT, RESTIR_PHAT_EMISSIVE_FLOOR);
    target = max(target, floorPhat);
    float safeTarget = min(target, restirContributionLimit());
    float w = min(safeTarget * sourceW * acceptedM,
            max(0.0, restirMaxWeightSum() - dst.wSum));
    if (!(w > 0.0)) return;

    dst.M = min(dst.M + acceptedM, configuredMaxM);
    dst.wSum += w;
    if (rndf(seed) * dst.wSum < w) {
        dst.pos = source.pos;
        dst.lnrm = source.lnrm;
        dst.le = source.le;
        dst.area = source.area;
        dst.phat = safeTarget;
        dst.packedLe = source.packedLe;
        // Age zero disables forced expiry; keep counting (with an 8-bit saturation) so enabling a
        // finite limit later immediately rejects a genuinely older representative.
        dst.age = min(source.age + 1u, 0xffu);
        // Keep control-variate state coupled to the representative that actually won. Copying only
        // the light sample while retaining another record's estimate would manufacture a difference
        // between unrelated random variables and is the most destructive ReSTCV failure mode.
        dst.sourceW = source.W;
        dst.cvEstimate = source.cvEstimate;
        dst.cvRepresentative = source.cvRepresentative;
        dst.cvConfidence = source.cvConfidence;
        dst.cvValid = source.cvValid;
    }
}

public bool restirPreviousPixel(float3 hitPos, float3 motionPrev, uint2 dimensions,
                         out int2 previousPixel) {
    float3 currentCameraRelative = hitPos - worldPush.camOffset;
    float4 clip = mul(worldPush.prevViewProj,
            float4(currentCameraRelative + worldPush.camDelta - motionPrev, 1.0));
    if (clip.w <= 0.0) {
        previousPixel = int2(0, 0);
        return false;
    }
    float2 uv = clip.xy / clip.w * 0.5 + 0.5;
    previousPixel = int2(floor(uv * float2(dimensions)));
    return all(previousPixel >= int2(0, 0)) && all(previousPixel < int2(dimensions));
}

// Random disk taps avoid the old cardinal star pattern, but are deliberately frame-stable for a given
// pixel. The former frame-index rotation changed every spatial candidate forever in a static scene,
// making block lighting visibly boil even after temporal history had converged. Per-pixel hashing still
// decorrelates neighbouring pixels without injecting perpetual temporal motion.
public float2 restirDiskOffset(uint sampleIndex, uint hash) {
    uint h = hash ^ (sampleIndex * 1973u + 9277u);
    h = pcg(h);
    float a01 = float(h & 0xFFFFu) / 65535.0;
    h = pcg(h);
    float r01 = float((h >> 8u) & 0xFFFFu) / 65535.0;
    float radius = sqrt(r01) * restirSpatialRadius();
    float angle = a01 * 6.2831853;
    return float2(cos(angle), sin(angle)) * radius;
}

public int2 restirSpatialOffset(uint sampleIndex, uint hash) {
    float2 f = restirDiskOffset(sampleIndex, hash);
    uint hjSeed = hash ^ sampleIndex * 7411u;
    uint hj = pcg(hjSeed);
    float jitterX = (rndf(hj) - 0.5) * 0.8;
    float jitterY = (rndf(hj) - 0.5) * 0.8;
    return int2(int(round(f.x + jitterX)), int(round(f.y + jitterY)));
}

public void restirStore(Reservoir r, uint pixelIndex, float3 surfacePos, float3 surfaceNormal,
                 bool twoSided, float3 cvEstimate, float3 cvRepresentative, float cvConfidence) {
    float maxM = restirMaxM();
    float maxW = restirMaxW();
    if (pc.restirCurrentAddr == 0
            || !(r.W > 0.0 && r.W <= maxW
                && r.M > 0.0 && r.M <= maxM && r.phat >= RESTIR_MIN_PHAT)) return;
    PackedRestirReservoir record;
    record.sampleCameraRelative = r.pos - worldPush.camOffset;
    record.area = r.area;
    record.surfaceCameraRelative = surfacePos - worldPush.camOffset;
    record.W = r.W;
    record.sampleNormal = restirPackNormal(r.lnrm);
    record.packedLe = r.packedLe;
    record.surfaceNormal = restirPackNormal(surfaceNormal);
    uint storedM = min(uint(round(r.M)), uint(maxM));
    record.meta = storedM
            | (min(r.age, 0xffu) << 16u)
            | ((pc.lightGeneration & 0x7fu) << 24u)
            | (twoSided ? 0x80000000u : 0u);

    // The block-light intensity is a live multiplier, not part of the emitter hierarchy generation.
    // Persist pre-scale values so history follows slider changes instead of flashing or being discarded.
    record.packedCvEstimate = 0u;
    record.packedCvRepresentative = 0u;
    record.cvMeta = 0u;
    record.reserved = 0u;
    float blockScale = max(worldPush.lightScales.x, 0.0);
    if (blockScale > 1.0e-6 && cvConfidence > 0.0) {
        float contributionLimit = restirContributionLimit();
        float3 safeEstimate = restirBoundContribution(cvEstimate, contributionLimit) / blockScale;
        float3 safeRepresentative = restirBoundContribution(cvRepresentative, contributionLimit) / blockScale;
        record.packedCvEstimate = restcvPackPositiveHdr(safeEstimate);
        record.packedCvRepresentative = restcvPackPositiveHdr(safeRepresentative);
        uint storedConfidence = min(uint(round(cvConfidence)), uint(restcvMaxConfidence()));
        record.cvMeta = storedConfidence | 0x100u | (RESTCV_RECORD_VERSION << 16u);
    }
    DevicePtr<PackedRestirReservoir>(pc.restirCurrentAddr)[pixelIndex] = record;
}

public Reservoir restirSpatiotemporal(Reservoir initial, uint2 pixel, uint2 dimensions,
                       float3 hitPos, float3 motionPrev, float3 n, float3 v, float3 rd,
                       float3 diffAlb, float3 F0, float rough, bool twoSided, float sss,
                       inout uint seed) {
    Reservoir result = initial;
    float maxM = restirMaxM();
    float maxW = restirMaxW();
    float contributionLimit = restirContributionLimit();
    // Normalize the fresh RIS set before history enters. The requested fresh count is already the
    // current-sample budget; scaling M and wSum together preserves W while hard bounds remove tails.
    float originalM = max(initial.M, 1.0);
    result.M = min(originalM, maxM);
    result.sourcePos = hitPos;
    result.sourceNormal = n;
    result.restir = 1u;
    if (initial.W > 0.0 && initial.phat >= RESTIR_MIN_PHAT) {
        float safeTarget = min(initial.phat, contributionLimit);
        float safeW = min(initial.W, min(maxW, contributionLimit / initial.phat));
        result.phat = safeTarget;
        result.W = safeW;
        result.wSum = min(safeW * result.M * safeTarget, restirMaxWeightSum());
    } else {
        result.W = 0.0;
        result.wSum = 0.0;
        result.phat = 0.0;
    }

    int2 previousPixel;
    bool hasPreviousPixel = restirPreviousPixel(hitPos, motionPrev, dimensions, previousPixel);
    if (hasPreviousPixel) {
        ConstPtr<PackedRestirReservoir> history =
                ConstPtr<PackedRestirReservoir>(pc.restirPreviousAddr);
        float cameraDistance = length(hitPos - worldPush.camOffset);
        float3 expectedPreviousSurface = hitPos - motionPrev;
        Reservoir candidate;
        uint previousIndex = uint(previousPixel.y) * dimensions.x + uint(previousPixel.x);
        float temporalPosition = max(clamp(worldPush.restirTemporal.x, 0.01, 2.0),
                cameraDistance * clamp(worldPush.restirTemporal.y, 0.0, 0.10));
        float temporalNormal = clamp(worldPush.restirTemporal.z, 0.50, 1.0);
        if (restirTemporalReuseEnabled()
                && restirLoadCandidate(history[previousIndex], expectedPreviousSurface, n, twoSided,
                        temporalPosition, temporalNormal, candidate)) {
            // Keep the centre's accumulated estimate independently of the reservoir winner. It is used
            // only with a deliberately small configured weight when a fresh representative wins.
            if (candidate.cvValid != 0u) {
                result.cvFallbackEstimate = candidate.cvEstimate;
                result.cvFallbackConfidence = candidate.cvConfidence;
                result.cvFallbackValid = 1u;
            }
            candidate.M = min(candidate.M, restirTemporalMCap());
            restirMerge(result, candidate, maxM, hitPos, n, v, rd,
                    diffAlb, F0, rough, twoSided, sss, seed);
        }

        // Read neighbours only from last frame's immutable buffer. Frame-stable random-disk offsets,
        // geometry validation and the connection Jacobian prevent both boiling and edge energy leaks.
        if (restirSpatialReuseEnabled()) {
            uint spatialSeed = pixel.x * 1973u + pixel.y * 9277u + 26699u;
            uint spatialHash = pcg(spatialSeed);
            uint spatialCount = restirSpatialSamples();
            float spatialPosition = max(clamp(worldPush.restirSpatial.x, 0.05, 4.0),
                    cameraDistance * clamp(worldPush.restirSpatial.y, 0.0, 0.20));
            float spatialNormal = clamp(worldPush.restirSpatial.z, 0.50, 1.0);
            for (uint i = 0u; i < spatialCount; ++i) {
                int2 neighbour = previousPixel + restirSpatialOffset(i, spatialHash);
                if (any(neighbour < int2(0, 0)) || any(neighbour >= int2(dimensions))) continue;
                uint neighbourIndex = uint(neighbour.y) * dimensions.x + uint(neighbour.x);
                if (restirLoadCandidate(history[neighbourIndex], expectedPreviousSurface, n, twoSided,
                        spatialPosition, spatialNormal, candidate)) {
                    candidate.M = min(candidate.M, restirSpatialMCap());
                    restirMerge(result, candidate, maxM, hitPos, n, v, rd,
                            diffAlb, F0, rough, twoSided, sss, seed);
                }
            }
        }
    }

    result.M = min(result.M, maxM);
    float rawW = result.phat >= RESTIR_MIN_PHAT && result.M > 0.0
            ? result.wSum / (result.M * result.phat) : 0.0;
    float selectedLuminanceW = result.phat >= RESTIR_MIN_PHAT
            ? contributionLimit / result.phat : 0.0;
    result.W = rawW > 0.0 ? min(rawW, min(maxW, selectedLuminanceW)) : 0.0;
    result.sourcePos = hitPos;
    result.sourceNormal = n;
    // Persistence waits until after the single final visibility ray: ReSTCV must store the visible
    // representative contribution, not the unshadowed target used by reservoir selection.
    return result;
}

// Shade a finalized reservoir: recompute the survivor's contribution at (hitPos,n,v), cast ONE shadow
// ray, and return throughput-free radiance contrib*vis*W. The one ray serves whichever term fired for
// the survivor (front BRDF, twoSided billboard, or SSS backscatter) — the origin is biased toward the
// sample's side of the surface.
public float3 shadeReservoir(Reservoir s, float3 hitPos, float3 n, float3 v, float3 rd, float3 diffAlb,
                      float3 F0, float rough, bool twoSided, float sss) {
    if (s.W <= 0.0 || s.phat <= 0.0) {
        return float3(0.0, 0.0, 0.0);
    }
    float phat;
    float3 contrib = evalSampleContrib(s.pos, s.lnrm, s.le, s.area, hitPos, n, v, rd,
            diffAlb, F0, rough, twoSided, sss, phat);
    if (phat <= 0.0) {
        return float3(0.0, 0.0, 0.0);
    }
    // Pick the shadow-ray origin on the sample's side of the surface FIRST, then measure the ray from
    // that origin — measuring dist from hitPos while tracing from the biased origin shifts the ray tip
    // up to SURF_BIAS*ndl toward the emitter plane, beating the 0.001*dist stop-short margin for lights
    // closer than ~SURF_BIAS/0.001 blocks -> shadow ray hits the emitter's own face -> per-texel black.
    float side = dot(n, s.pos - hitPos) >= 0.0 ? 1.0 : -1.0;
    float3 origin = hitPos + side * n * SURF_BIAS;
    float3 toL = s.pos - origin;
    float dist = length(toL);
    // Stop just short of the sample point so the ray doesn't self-occlude on the emitter's own face.
    VisibilityResult shadow = visibility(origin, toL / dist, dist * 0.999);
    float3 vis = shadow.transmittance;
    // Shared stability contract: independent RIS gets the same final W and luminance bounds as both
    // history modes. This is intentionally unconditional so turning ReSTIR off cannot restore flashes.
    float appliedW = min(s.W, restirMaxW());
    return restirBoundContribution(contrib * vis * appliedW, restirContributionLimit());
}

// Resolve and persist one screen-space reservoir after its single visibility ray. ReSTCV follows the
// confidence-weighted accumulated-estimate idea from Hercier et al., adapted to Caustica's compact DI
// reservoir: if a historical representative wins, compare that SAME sample at its stored source W,
// then transfer the source estimate by current-minus-source representative contribution. No second
// shadow ray is needed. A validated centre estimate receives only a small configured fallback weight
// when the fresh sample wins, preventing frequent one-sample resets without making it authoritative.
public float3 shadeRestirReservoir(Reservoir s, uint pixelIndex, float3 hitPos, float3 n, float3 v,
                      float3 rd, float3 diffAlb, float3 F0, float rough, bool twoSided, float sss) {
    float3 standardEstimate = shadeReservoir(s, hitPos, n, v, rd, diffAlb, F0, rough, twoSided, sss);
    float3 resolvedEstimate = standardEstimate;
    float nextConfidence = 1.0;

    if (restcvEnabled()) {
        float strength = clamp(worldPush.restcvParams.x, 0.0, 1.0);
        float historyClamp = clamp(worldPush.restcvParams.z, 1.0, 16.0);
        float contributionLimit = restirContributionLimit();
        if (strength > 0.0 && s.cvValid != 0u && s.sourceW > 0.0 && s.W > 0.0) {
            // standardEstimate is weighted with final W. Convert it back to the selected historical
            // record's W before subtracting that record's representative contribution.
            float sourceToFinal = min(s.sourceW / max(s.W, 1.0e-6), RESTIR_HARD_MAX_W);
            float3 currentAtSourceWeight = restirBoundContribution(
                    standardEstimate * sourceToFinal, contributionLimit);
            float3 transfer = s.cvEstimate + currentAtSourceWeight - s.cvRepresentative;
            transfer = restirBoundContribution(transfer, contributionLimit);

            // Reject a corrupted/poorly shifted estimate before it enters the next history record. The
            // source estimate itself participates in the reference, so legitimate stable bright lighting
            // is retained while a newly manufactured spike is clipped.
            float referenceLuminance = max(luminance(standardEstimate), luminance(s.cvEstimate));
            float transferLimit = min(contributionLimit,
                    max(0.25, referenceLuminance * historyClamp));
            transfer = restirBoundContribution(transfer, transferLimit);
            float cvWeight = strength * min(s.cvConfidence, restcvMaxConfidence());
            resolvedEstimate = (standardEstimate + cvWeight * transfer) / (1.0 + cvWeight);
            nextConfidence = min(cvWeight + 1.0, restcvMaxConfidence());
        } else if (strength > 0.0 && s.cvFallbackValid != 0u) {
            float fallbackLimit = min(contributionLimit,
                    max(0.25, luminance(standardEstimate) * historyClamp));
            float3 fallback = restirBoundContribution(s.cvFallbackEstimate, fallbackLimit);
            // Scale the validated centre's confidence rather than normalizing it away. At the default
            // 20%, mature fallback history has one fifth of the selected-history authority: enough to
            // prevent frequent fresh winners from restarting visible noise, but still more responsive.
            float fallbackConfidence = min(s.cvFallbackConfidence, restcvMaxConfidence());
            float fallbackWeight = strength * clamp(worldPush.restcvParams.y, 0.0, 1.0)
                    * fallbackConfidence;
            resolvedEstimate = (standardEstimate + fallbackWeight * fallback) / (1.0 + fallbackWeight);
            nextConfidence = min(fallbackWeight + 1.0, restcvMaxConfidence());
        }
    }

    resolvedEstimate = restirBoundContribution(resolvedEstimate, restirContributionLimit());
    restirStore(s, pixelIndex, hitPos, n, twoSided,
            resolvedEstimate, standardEstimate, nextConfidence);
    return resolvedEstimate;
}

// NRD-only twin of shadeReservoir: the SAME winning-sample estimate (identical shadow ray, W cap and
// firefly clamp), but with the diffuse/specular terms split for REBLUR_DIFFUSE_SPECULAR. Kept as a
// separate entry point so the ordinary path keeps calling shadeReservoir untouched.
public void shadeReservoirSplit(Reservoir s, float3 hitPos, float3 n, float3 v, float3 rd, float3 diffAlb,
                      float3 F0, float rough, bool twoSided, float sss,
                      out float3 outDiff, out float3 outSpec) {
    outDiff = float3(0.0, 0.0, 0.0);
    outSpec = float3(0.0, 0.0, 0.0);
    if (s.W <= 0.0 || s.phat <= 0.0) {
        return;
    }
    float phat;
    float3 diffPart;
    float3 specPart;
    evalSampleContribSplit(s.pos, s.lnrm, s.le, s.area, hitPos, n, v, rd,
            diffAlb, F0, rough, twoSided, sss, phat, diffPart, specPart);
    if (phat <= 0.0) {
        return;
    }
    // Same origin/measure/shadow sequence as shadeReservoir — see the comments there; the two must
    // stay in lockstep or the split estimate diverges from the ordinary one.
    float side = dot(n, s.pos - hitPos) >= 0.0 ? 1.0 : -1.0;
    float3 origin = hitPos + side * n * SURF_BIAS;
    float3 toL = s.pos - origin;
    float dist = length(toL);
    VisibilityResult shadow = visibility(origin, toL / dist, dist * 0.999);
    float3 vis = shadow.transmittance;
    float appliedW = min(s.W, restirMaxW());
    outDiff = diffPart * vis * appliedW;
    outSpec = specPart * vis * appliedW;
    float3 boundedTotal = restirBoundContribution(outDiff + outSpec, restirContributionLimit());
    float3 rawTotal = outDiff + outSpec;
    // Apply one component-wise factor to both lobes so their sum exactly follows the shared bound.
    float3 boundScale = float3(
            rawTotal.x > 1.0e-20 ? boundedTotal.x / rawTotal.x : 0.0,
            rawTotal.y > 1.0e-20 ? boundedTotal.y / rawTotal.y : 0.0,
            rawTotal.z > 1.0e-20 ? boundedTotal.z / rawTotal.z : 0.0);
    outDiff *= boundScale;
    outSpec *= boundScale;
}

// ReSTCV changes the combined reservoir estimate after the split shader's identical visibility ray.
// Redistribute that resolved RGB over the current lobes and place any zero-denominator residue in the
// diffuse lobe, keeping NRD's diffuse+specular signal exactly equal to the final-color estimator.
public void restirMatchSplitToResolved(float3 resolved, inout float3 diffPart, inout float3 specPart) {
    float3 splitTotal = diffPart + specPart;
    float3 scale = float3(
            splitTotal.x > 1.0e-20 ? resolved.x / splitTotal.x : 0.0,
            splitTotal.y > 1.0e-20 ? resolved.y / splitTotal.y : 0.0,
            splitTotal.z > 1.0e-20 ? resolved.z / splitTotal.z : 0.0);
    diffPart *= scale;
    specPart *= scale;
    diffPart += max(resolved - (diffPart + specPart), float3(0.0, 0.0, 0.0));
}

// Analytic held-item light (WorldPush.handLight): xyz position in the rebased space, w packed
// intensity (radiance*area product of the equivalent emitter; 0 = no luminous held item this
// frame). Held-item geometry never enters the RIS emitter light buffer — that buffer collects
// terrain quads only — so without this term a torch in hand lights the scene through rare
// indirect bounce hits alone and reads as a faint glow at best. This gives it the same direct
// treatment the celestial light gets: one visibility ray per receiver, inverse-square falloff,
// Lambertian irradiance for the caller to multiply by brdf and throughput. Runtime scale is
// lightScales.y (the Video Settings held-item intensity slider).
public float3 handLightIrradiance(float3 origin, float3 hitPos, float3 n, bool twoSided) {
    float intensity = worldPush.handLight.w * max(worldPush.lightScales.y, 0.0);
    if (intensity <= 0.0) {
        return float3(0.0, 0.0, 0.0);
    }
    float3 toL = worldPush.handLight.xyz - hitPos;
    float d2 = dot(toL, toL);
    if (d2 < 1.0e-4) {
        return float3(0.0, 0.0, 0.0);
    }
    float dist = sqrt(d2);
    float3 ldir = toL / dist;
    float ndl = twoSided ? abs(dot(n, ldir)) : max(0.0, dot(n, ldir));
    if (ndl <= 0.0) {
        return float3(0.0, 0.0, 0.0);
    }
    // Stop well short of the light centre: geometry near the flame (another player's held item, the
    // local player's own body in third person) would otherwise occlude the very light it carries.
    // The floor keeps tmax strictly above RAY_TMIN so the degenerate close-range ray stays valid.
    float tmax = max(dist - 0.25, 2.0 * RAY_TMIN);
    // CULL_HAND_LIGHT: ordinary occluders except the first-person viewmodel — its captured arm/item
    // sits at the light position and otherwise floats a phantom shadow in the middle of the beam.
    VisibilityResult shadow = visibilityCulled(origin, ldir, tmax, CULL_HAND_LIGHT);
    float3 vis = shadow.transmittance;
    if (max(vis.r, max(vis.g, vis.b)) <= 0.0) {
        return float3(0.0, 0.0, 0.0);
    }
    // Per-item tint (torch warm, soul torch cyan, lava orange-red...); near-distance clamp keeps
    // the estimate finite when the receiver practically touches the flame.
    return vis * (worldPush.handLightColor.xyz * ndl * intensity / max(d2, 0.25));
}

// TLAS instance-mask bits (set on the Java side, ANDed against these per-ray cull masks):
//   bit 0 (0x01) — secondary rays: shadows, GI bounces, reflections.
//   bit 1 (0x02) — the primary camera ray.
// Terrain / entities / block entities keep 0xFF (both bits). Particles use 0x02: primary-visible.
// The held-item light traces with CULL_HAND_LIGHT (bits 2..7): everything above except the
// first-person viewmodel (0x01), which must not shadow its own beam.
