// ReGIR world-grid reservoir builder. One dispatch per frame, before the world traces.
//
// Each thread owns one cell of a fixed REGIR_GRID_DIMS^3 cubic grid centred on the camera. It runs a
// small RIS over the global light list with an OMNIDIRECTIONAL target evaluated at the cell centre
// (the ReGIR "rejection sampling" build from Bitterli et al. 2020, RTXDI's world light grid):
// M candidate lights are proposed through the same power-weighted alias table the path tracer
// uses, each resampled against an isotropic receiver (|cosine| to the emitter face, no surface
// normal) so the cell's reservoir is a good proposal for ANY surface inside the cell. The shading
// vertices merge that reservoir as a single M-weighted candidate (see regirMergeCell in
// lighting.slang), turning M dependent light-list loads per vertex into one cell-record load.
//
// No temporal component by design: the grid is rebuilt every frame from the published light
// hierarchy, so moved/removed lights and light-generation changes are picked up immediately and
// the path tracer's own ReSTIR temporal reuse still accumulates the merged proposals across frames.
//
// Self-contained (imports world_common for the shared structs/constants only): the light-selection
// and radiance decode helpers are deliberately small local copies of the lighting.slang ones, so
// this compute stage never drags the ray-tracing bindings (topLevelAS, payload, trace intrinsics)
// into a compute pipeline.

import world_common;

struct RegirPush {
    public uint64_t worldPushAddr;
    public uint64_t lightBufAddr;
    public uint64_t lightAliasAddr;
    public uint64_t regirCellsAddr;
    public uint32_t lightCount;
    public uint32_t candidates;
    public uint32_t pad0;
    public uint32_t pad1;
};

[[vk::push_constant]]
RegirPush pc;

public static const uint REGIR_BUILD_DIMS = 24u; // must match lighting.slang REGIR_GRID_DIMS
public static const float REGIR_BUILD_CELL = 8.0f; // must match lighting.slang REGIR_CELL_SIZE
public static const uint REGIR_BUILD_CANDIDATES = 8u;
public static const float REGIR_TARGET_FLOOR = 1.0e-4;
public static const float REGIR_MAX_SAMPLE_LUMINANCE = 16.0;

uint pcgLocal(inout uint s) {
    uint state = s * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    s = (word >> 22u) ^ word;
    return s;
}

float rndfLocal(inout uint s) {
    pcgLocal(s);
    return float(s >> 8u) * (1.0 / 16777216.0);
}

float unpackUnsignedFloatLocal(uint bits, uint mantissaBits) {
    uint mantissaMask = (1u << mantissaBits) - 1u;
    uint mantissa = bits & mantissaMask;
    uint exponent = (bits >> mantissaBits) & 31u;
    if (exponent == 0u) {
        return float(mantissa) * exp2(float(1 - 15 - int(mantissaBits)));
    }
    return (1.0 + float(mantissa) / float(1u << mantissaBits))
            * exp2(float(int(exponent) - 15));
}

float3 lightRadiancePackedLocal(uint packed) {
    return float3(unpackUnsignedFloatLocal(packed & 0x7ffu, 6u),
            unpackUnsignedFloatLocal((packed >> 11u) & 0x7ffu, 6u),
            unpackUnsignedFloatLocal((packed >> 22u) & 0x3ffu, 5u));
}

float3 lightHalfULocal(Light light) {
    return float3(unpackHalf2Local(light.halfUxy), unpackHalf2Local(light.halfUzVx).x);
}

float3 lightHalfVLocal(Light light) {
    return float3(unpackHalf2Local(light.halfUzVx).y, unpackHalf2Local(light.halfVyz));
}

float2 unpackHalf2Local(uint p) {
    return float2(f16tof32(p & 0xFFFFu), f16tof32(p >> 16u));
}

float3 lightCrossUVLocal(Light light) {
    return cross(lightHalfULocal(light), lightHalfVLocal(light));
}

float lightAreaLocal(Light light) {
    return 4.0 * length(lightCrossUVLocal(light));
}

float3 lightGeometricNormalLocal(Light light) {
    float3 normal = normalize(lightCrossUVLocal(light));
    return (light.section & 0x40000000u) != 0u ? -normal : normal;
}

bool lightIsPointLocal(Light light) {
    return (light.section & LIGHT_POINT_BIT) != 0u;
}

float luminanceLocal(float3 c) {
    return dot(c, float3(0.2126, 0.7152, 0.0722));
}

// Global power-weighted alias selection, O(1). Mirrors lighting.slang selectGlobalLight: when no
// alias table is published the column index degrades to a uniform draw.
uint selectGlobalLight(uint lightCount, float invPower, inout uint seed) {
    float sample = rndfLocal(seed) * float(lightCount);
    uint column = min(uint(sample), lightCount - 1u);
    if (pc.lightAliasAddr != 0u && invPower > 0.0) {
        LightAlias a = ConstPtr<LightAlias>(pc.lightAliasAddr)[column];
        bool self = sample - float(column) < a.accept;
        return self ? column : a.aliasIndex;
    }
    return column;
}

// Omni-directional target for a candidate sample seen from the cell centre: Lambertian
// irradiance-style weight with the surface normal folded out (|cos| at an isotropic receiver).
// Same G*area geometry factor the BRDF-aware target uses, so merging at a real receiver with the
// full evaluation is the standard re-weighted RIS.
float cellTarget(float3 samplePos, float3 emitterNormal, float3 le, float area, float3 cellCentre) {
    float3 toL = samplePos - cellCentre;
    float d2 = dot(toL, toL);
    if (d2 < 1.0e-6) return 0.0;
    float dist = sqrt(d2);
    float3 wi = toL / dist;
    float cosL = abs(dot(emitterNormal, wi));
    if (cosL <= 0.0) return 0.0;
    float g = cosL / d2; // omni receiver: no surface NDL
    return max(luminanceLocal(le) * g * area, 0.0);
}

[shader("compute")]
[numthreads(8, 8, 8)]
void main(uint3 id : SV_DispatchThreadID) {
    if (any(id >= uint3(REGIR_BUILD_DIMS))) {
        return;
    }
    WorldPush push = ConstPtr<WorldPush>(pc.worldPushAddr)[0];
    uint linear = (id.z * REGIR_BUILD_DIMS + id.y) * REGIR_BUILD_DIMS + id.x;

    uint M = 0u;
    float wSum = 0.0;
    float bestTarget = 0.0;
    float3 bestPos = float3(0.0, 0.0, 0.0);
    float3 bestNormal = float3(0.0, 1.0, 0.0);
    float bestArea = 0.0;
    uint bestPackedLe = 0u;

    // Cell centre in rebased world space: regirGrid.xyz is the origin of cell 0 and w the size.
    float3 cellCentre = push.regirGrid.xyz
            + (float3(id) + float3(0.5, 0.5, 0.5)) * push.regirGrid.w;
    uint seed = id.x * 73856093u ^ id.y * 19349663u ^ id.z * 83492791u
            ^ (push.frameIndex * 2654435761u);
    seed = pcgLocal(seed);

    bool analyticOn = (push.featureFlags & FEATURE_ANALYTIC_CLUSTERED) != 0u;
    uint candidateCount = max(pc.candidates, 1u);
    for (uint c = 0u; c < candidateCount; c++) {
        uint li = selectGlobalLight(pc.lightCount, push.lightRebase.w, seed);
        Light lg = ConstPtr<Light>(pc.lightBufAddr)[li];
        // Analytic mode owns point emitters at primary receivers; exclude them from the grid so a
        // ReGIR proposal cannot re-add the deterministic direct term.
        if (analyticOn && lightIsPointLocal(lg)) {
            continue;
        }
        // Uniform point on the emitter rectangle ((s,t) in [-1,1]^2, pdf 1/area).
        float s = rndfLocal(seed) * 2.0 - 1.0;
        float t = rndfLocal(seed) * 2.0 - 1.0;
        float3 samplePos = lg.pos + push.lightRebase.xyz
                + s * lightHalfULocal(lg) + t * lightHalfVLocal(lg);
        float3 emitterNormal = lightGeometricNormalLocal(lg);
        float area = lightAreaLocal(lg);
        float3 le = lightRadiancePackedLocal(lg.le) * max(push.lightScales.x, 0.0);
        float target = cellTarget(samplePos, emitterNormal, le, area, cellCentre);
        if (!(target > 0.0)) {
            continue;
        }
        target = min(max(target, REGIR_TARGET_FLOOR), REGIR_MAX_SAMPLE_LUMINANCE);
        M++;
        wSum += target;
        if (rndfLocal(seed) * wSum < target) {
            bestPos = samplePos;
            bestNormal = emitterNormal;
            bestArea = area;
            bestPackedLe = lg.le;
            bestTarget = target;
        }
    }

    RegirCell result;
    result.samplePos = bestPos;
    result.packedLe = bestPackedLe;
    result.sampleNormal = bestNormal;
    result.area = bestArea;
    if (M > 0u && bestTarget > 0.0) {
        result.M = M;
        result.W = min(wSum / (float(M) * bestTarget), 16.0);
    } else {
        result.M = 0u;
        result.W = 0.0;
    }
    DevicePtr<RegirCell>(pc.regirCellsAddr)[linear] = result;
}
