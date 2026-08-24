// Spatially hashed radiance cache used by Caustica's path tracer.
//
// The cache deliberately separates data written by tracing from data read by rendering:
//
//   * raygen inserts stable world-space keys and atomically accumulates fixed-point samples;
//   * sharc_resolve.comp consumes those samples after the trace, updates temporal history and clears
//     only the per-frame accumulator;
//   * cache queries read the resolved lane, which no raygen invocation modifies during the trace.
//
// Keeping those phases separate is essential. A float read/modify/write from every ray hitting a
// voxel is a data race, and querying that same memory while peers rewrite it makes the answer depend
// on GPU scheduling. Both failure modes show up as distant flicker rather than radiance reuse.
module sharc;

import world_common;

// One cache allocation is an array of these 64-byte records. Keep RtSharc.ENTRY_BYTES in lock-step.
// `metadata.x` is the insertion state and is the only word used as a lock during tracing:
//   0 = empty, 1 = being initialized, 2 = key ready.
// Resolve is dispatched after a Vulkan memory barrier, so it is the sole writer of resolved/history
// data and can recycle stale records without atomics.
public struct SharcEntry {
    public uint4  key;           // signed cell xyz as raw bits; w = dominant-normal class
    public uint4  accumulation;  // fixed-point radiance sum xyz; w = complete path sample count
    public float4 resolved;      // temporally resolved outgoing radiance xyz; w = validity
    public uint4  metadata;      // state, sampled-frame count, stale-frame count, packed reference normal
};

public static const uint SHARC_ENTRY_EMPTY = 0u;
public static const uint SHARC_ENTRY_LOCKED = 1u;
public static const uint SHARC_ENTRY_READY = 2u;
public static const uint SHARC_INVALID_INDEX = 0xffffffffu;
public static const uint SHARC_PROBE_COUNT = 8u;
public static const uint SHARC_INSERT_RETRIES = 4u;
public static const uint SHARC_PROPAGATION_DEPTH = 2u;
public static const uint SHARC_MAX_FRAME_SAMPLES = 2048u;
// At propagation depth two, one reserved sample can receive several downstream terms. This leaves
// enough uint32 headroom for an eight-bounce path while retaining ~0.002 radiance precision.
public static const float SHARC_RADIANCE_SCALE = 512.0;
public static const float SHARC_MAX_SAMPLE_CHANNEL = 128.0;

// A sparse update path keeps the last two diffuse cache vertices. Direct radiance observed at the
// current hit is propagated to older vertices with the BSDF/medium transport between them. Each
// vertex increments its sample count exactly once; downstream contributions only extend that sample.
public struct SharcPathState {
    public uint cacheIndices[SHARC_PROPAGATION_DEPTH];
    public float3 sampleWeights[SHARC_PROPAGATION_DEPTH];
    public uint pathLength;
    public uint updating;
};

public bool sharcReady(WorldPush push) {
    return worldFeature(push, FEATURE_SHARC)
        && push.sharcCacheAddr != 0
        && push.sharcGridOrigin.w > 0
        && push.sharcParams.x >= 1.0
        && push.sharcParams2.z >= 1.0;
}

public uint sharcMix(uint value) {
    value ^= value >> 16u;
    value *= 0x7feb352du;
    value ^= value >> 15u;
    value *= 0x846ca68bu;
    value ^= value >> 16u;
    return value;
}

public uint sharcHashKey(uint4 key) {
    uint h = sharcMix(key.x ^ 0x9e3779b9u);
    h ^= sharcMix(key.y ^ 0x85ebca6bu);
    h ^= sharcMix(key.z ^ 0xc2b2ae35u);
    h ^= sharcMix(key.w ^ 0x27d4eb2fu);
    return sharcMix(h);
}

public bool sharcKeyEquals(uint4 a, uint4 b) {
    return all(a == b);
}

// Integer division in shader languages truncates toward zero. This version floors so a negative
// terrain origin and a positive one quantize to one continuous block grid.
public int sharcFloorDiv(int value, int divisor) {
    int quotient = value / divisor;
    int remainder = value - quotient * divisor;
    return remainder < 0 ? quotient - 1 : quotient;
}

public int sharcCellAxis(float rebasedPosition, int worldOrigin, int cellSize) {
    int originCell = sharcFloorDiv(worldOrigin, cellSize);
    int originRemainder = worldOrigin - originCell * cellSize; // always [0, cellSize)
    return originCell + int(floor((rebasedPosition + float(originRemainder)) / float(cellSize)));
}

// Payload normals include normal maps. Quantizing to the dominant signed axis keeps a stone normal
// map from generating hundreds of keys while still separating floor, ceiling and wall radiance.
public uint sharcNormalClass(float3 normal) {
    float3 a = abs(normal);
    if (a.x >= a.y && a.x >= a.z) {
        return normal.x >= 0.0 ? 0u : 1u;
    }
    if (a.y >= a.z) {
        return normal.y >= 0.0 ? 2u : 3u;
    }
    return normal.z >= 0.0 ? 4u : 5u;
}

public uint4 sharcKey(WorldPush push, float3 rebasedPosition, float3 normal) {
    int cellSize = max(int(round(push.sharcParams.x)), 1);
    // sharcGridOrigin.xyz is the integer terrain rebase origin. Combining it with the small rebased
    // hit coordinate this way avoids converting a 30-million-block world coordinate to float first.
    int3 cell = int3(
        sharcCellAxis(rebasedPosition.x, push.sharcGridOrigin.x, cellSize),
        sharcCellAxis(rebasedPosition.y, push.sharcGridOrigin.y, cellSize),
        sharcCellAxis(rebasedPosition.z, push.sharcGridOrigin.z, cellSize));
    return uint4(uint(cell.x), uint(cell.y), uint(cell.z), sharcNormalClass(normal));
}

public uint sharcPackNormal(float3 normal) {
    float3 encoded = saturate(normalize(normal) * 0.5 + 0.5);
    uint3 q = uint3(round(encoded * 255.0));
    return q.x | (q.y << 8u) | (q.z << 16u);
}

public float3 sharcUnpackNormal(uint packed) {
    float3 q = float3(float(packed & 255u),
                      float((packed >> 8u) & 255u),
                      float((packed >> 16u) & 255u));
    return normalize(q / 255.0 * 2.0 - 1.0);
}

// MAX_DISTANCE is a camera-to-hit bound. The previous implementation compared it with distance to
// the center of the voxel (at most sqrt(3)/2 voxels), making the default 96-block control inert and
// allowing the sparsest far-field cells to be the only visible cache effect.
public float sharcRangeWeight(WorldPush push, float3 rebasedPosition) {
    float maxDistance = max(push.sharcParams.w, 0.0);
    if (maxDistance <= 0.0) {
        return 0.0;
    }
    float distanceToCamera = length(rebasedPosition - push.camOffset);
    // Blend back to the traced estimator over the outer 20% instead of drawing a hard cache ring that
    // pops as the camera crosses maxDistance.
    return 1.0 - smoothstep(maxDistance * 0.8, maxDistance, distanceToCamera);
}

public bool sharcInRange(WorldPush push, float3 rebasedPosition) {
    return sharcRangeWeight(push, rebasedPosition) > 0.0;
}

public uint sharcProbeIndex(uint baseIndex, uint probe, uint capacity) {
    return (baseIndex + probe) % capacity;
}

public bool sharcFind(WorldPush push, uint4 key, out uint cacheIndex) {
    cacheIndex = SHARC_INVALID_INDEX;
    if (!sharcReady(push)) {
        return false;
    }
    uint capacity = uint(push.sharcGridOrigin.w);
    uint baseIndex = sharcHashKey(key) % capacity;
    ConstPtr<SharcEntry> cache = ConstPtr<SharcEntry>(push.sharcCacheAddr);
    for (uint probe = 0u; probe < SHARC_PROBE_COUNT; ++probe) {
        uint index = sharcProbeIndex(baseIndex, probe, capacity);
        SharcEntry entry = cache[index];
        if (entry.metadata.x == SHARC_ENTRY_READY && sharcKeyEquals(entry.key, key)) {
            cacheIndex = index;
            return true;
        }
    }
    return false;
}

// Find an existing key or reserve the first empty slot in its bounded probe window. A bounded retry
// replaces an unbounded spinlock: transient contention may drop an update, but can never hang a GPU.
public bool sharcFindOrInsert(WorldPush push, uint4 key, float3 normal, out uint cacheIndex) {
    cacheIndex = SHARC_INVALID_INDEX;
    if (!sharcReady(push)) {
        return false;
    }
    uint capacity = uint(push.sharcGridOrigin.w);
    uint baseIndex = sharcHashKey(key) % capacity;
    DevicePtr<SharcEntry> cache = DevicePtr<SharcEntry>(push.sharcCacheAddr);

    for (uint retry = 0u; retry < SHARC_INSERT_RETRIES; ++retry) {
        uint emptyIndex = SHARC_INVALID_INDEX;
        bool initializerInFlight = false;
        for (uint probe = 0u; probe < SHARC_PROBE_COUNT; ++probe) {
            uint index = sharcProbeIndex(baseIndex, probe, capacity);
            uint state = cache[index].metadata.x;
            if (state == SHARC_ENTRY_READY && sharcKeyEquals(cache[index].key, key)) {
                cacheIndex = index;
                return true;
            }
            if (state == SHARC_ENTRY_LOCKED) {
                initializerInFlight = true;
            } else if (state == SHARC_ENTRY_EMPTY && emptyIndex == SHARC_INVALID_INDEX) {
                emptyIndex = index;
            }
        }

        // Do not leapfrog an initializer: paths for the same new key would otherwise create duplicate
        // records in adjacent probe slots. Retrying is cheap and remains strictly bounded.
        if (initializerInFlight || emptyIndex == SHARC_INVALID_INDEX) {
            continue;
        }

        uint previousState;
        InterlockedCompareExchange(cache[emptyIndex].metadata.x,
                                   SHARC_ENTRY_EMPTY, SHARC_ENTRY_LOCKED, previousState);
        if (previousState != SHARC_ENTRY_EMPTY) {
            continue;
        }

        SharcEntry initialized;
        initialized.key = key;
        initialized.accumulation = uint4(0u, 0u, 0u, 0u);
        initialized.resolved = float4(0.0, 0.0, 0.0, 0.0);
        initialized.metadata = uint4(SHARC_ENTRY_LOCKED, 0u, 0u, sharcPackNormal(normal));
        cache[emptyIndex] = initialized;
        DeviceMemoryBarrier();
        uint ignored;
        InterlockedExchange(cache[emptyIndex].metadata.x, SHARC_ENTRY_READY, ignored);
        cacheIndex = emptyIndex;
        return true;
    }
    return false;
}

// Atomically reserves one complete path sample. RGB contributions belonging to that sample may be
// added at later bounces, but they do not increment accumulation.w again.
public bool sharcReserveSample(DevicePtr<SharcEntry> cache, uint cacheIndex) {
    for (uint retry = 0u; retry < 8u; ++retry) {
        uint count = cache[cacheIndex].accumulation.w;
        if (count >= SHARC_MAX_FRAME_SAMPLES) {
            return false;
        }
        uint observed;
        InterlockedCompareExchange(cache[cacheIndex].accumulation.w, count, count + 1u, observed);
        if (observed == count) {
            return true;
        }
    }
    return false;
}

public float3 sharcSanitizeSample(float3 radiance) {
    if (any(isnan(radiance)) || any(isinf(radiance))) {
        return float3(0.0, 0.0, 0.0);
    }
    radiance = max(radiance, float3(0.0, 0.0, 0.0));
    float peak = max(radiance.x, max(radiance.y, radiance.z));
    if (peak > SHARC_MAX_SAMPLE_CHANNEL) {
        radiance *= SHARC_MAX_SAMPLE_CHANNEL / peak;
    }
    return radiance;
}

public void sharcAtomicAdd(DevicePtr<SharcEntry> cache, uint cacheIndex, float3 radiance) {
    float3 clean = sharcSanitizeSample(radiance);
    uint3 fixedPoint = uint3(round(clean * SHARC_RADIANCE_SCALE));
    uint ignored;
    if (fixedPoint.x != 0u) {
        InterlockedAdd(cache[cacheIndex].accumulation.x, fixedPoint.x, ignored);
    }
    if (fixedPoint.y != 0u) {
        InterlockedAdd(cache[cacheIndex].accumulation.y, fixedPoint.y, ignored);
    }
    if (fixedPoint.z != 0u) {
        InterlockedAdd(cache[cacheIndex].accumulation.z, fixedPoint.z, ignored);
    }
}

public bool sharcBeginSample(WorldPush push, uint cacheIndex, float3 radiance) {
    DevicePtr<SharcEntry> cache = DevicePtr<SharcEntry>(push.sharcCacheAddr);
    if (!sharcReserveSample(cache, cacheIndex)) {
        return false;
    }
    sharcAtomicAdd(cache, cacheIndex, radiance);
    return true;
}

public void sharcAddContribution(WorldPush push, uint cacheIndex, float3 radiance) {
    DevicePtr<SharcEntry> cache = DevicePtr<SharcEntry>(push.sharcCacheAddr);
    sharcAtomicAdd(cache, cacheIndex, radiance);
}

public void sharcPathInit(WorldPush push, uint seed, out SharcPathState state) {
    state.pathLength = 0u;
    state.updating = 0u;
    for (uint i = 0u; i < SHARC_PROPAGATION_DEPTH; ++i) {
        state.cacheIndices[i] = SHARC_INVALID_INDEX;
        state.sampleWeights[i] = float3(0.0, 0.0, 0.0);
    }
    if (!sharcReady(push)) {
        return;
    }
    float coverage = saturate(push.sharcParams2.y);
    float randomValue = float(sharcMix(seed) & 0x00ffffffu) / 16777216.0;
    state.updating = randomValue < coverage ? 1u : 0u;
}

public bool sharcPathIsUpdating(SharcPathState state) {
    return state.updating != 0u;
}

// Adds radiance produced after all currently tracked vertices. It does not create another sample;
// every tracked vertex already reserved its one count when that path first hit it.
public void sharcPathAdd(WorldPush push, SharcPathState state, float3 radiance) {
    if (!sharcPathIsUpdating(state)) {
        return;
    }
    for (uint i = 0u; i < state.pathLength; ++i) {
        sharcAddContribution(push, state.cacheIndices[i], radiance * state.sampleWeights[i]);
    }
}

public void sharcPathMultiply(inout SharcPathState state, float3 transport) {
    if (!sharcPathIsUpdating(state)) {
        return;
    }
    float3 clean = any(isnan(transport)) || any(isinf(transport))
        ? float3(0.0, 0.0, 0.0) : max(transport, float3(0.0, 0.0, 0.0));
    for (uint i = 0u; i < state.pathLength; ++i) {
        state.sampleWeights[i] *= clean;
    }
}

// Complete one cache vertex: propagate this hit's direct outgoing radiance to older vertices, reserve
// one sample for this vertex, then retain it for up to SHARC_PROPAGATION_DEPTH downstream events.
public void sharcPathRecordSurface(WorldPush push, inout SharcPathState state,
                                   float3 rebasedPosition, float3 normal, float3 directRadiance) {
    if (!sharcPathIsUpdating(state)) {
        return;
    }

    // A path can leave the configured cache radius after starting inside it. Its radiance still
    // completes older in-range samples even though this new surface does not get its own entry.
    sharcPathAdd(push, state, directRadiance);
    if (!sharcInRange(push, rebasedPosition)) {
        return;
    }

    uint4 key = sharcKey(push, rebasedPosition, normal);
    uint cacheIndex;
    if (!sharcFindOrInsert(push, key, normal, cacheIndex)
            || !sharcBeginSample(push, cacheIndex, directRadiance)) {
        return;
    }

    uint last = min(state.pathLength, SHARC_PROPAGATION_DEPTH - 1u);
    for (uint i = last; i > 0u; --i) {
        state.cacheIndices[i] = state.cacheIndices[i - 1u];
        state.sampleWeights[i] = state.sampleWeights[i - 1u];
    }
    state.cacheIndices[0] = cacheIndex;
    state.sampleWeights[0] = float3(1.0, 1.0, 1.0);
    state.pathLength = min(state.pathLength + 1u, SHARC_PROPAGATION_DEPTH);
}

// Query only temporally resolved data. `stableFrames` counts frames that actually supplied samples;
// refreshing a visible cell therefore makes it more trustworthy instead of resetting its age to zero.
public bool sharcQuery(WorldPush push, float3 rebasedPosition, float3 normal, out float3 radiance) {
    radiance = float3(0.0, 0.0, 0.0);
    if (!sharcReady(push) || !sharcInRange(push, rebasedPosition)) {
        return false;
    }

    uint cacheIndex;
    if (!sharcFind(push, sharcKey(push, rebasedPosition, normal), cacheIndex)) {
        return false;
    }
    SharcEntry entry = ConstPtr<SharcEntry>(push.sharcCacheAddr)[cacheIndex];
    uint requiredFrames = max(uint(push.sharcParams3.x), 1u);
    if (entry.metadata.y < requiredFrames || entry.resolved.w <= 0.0) {
        return false;
    }
    float3 storedNormal = sharcUnpackNormal(entry.metadata.w);
    if (dot(storedNormal, normalize(normal)) < push.sharcParams2.w) {
        return false;
    }
    if (any(isnan(entry.resolved.xyz)) || any(isinf(entry.resolved.xyz))) {
        return false;
    }
    radiance = max(entry.resolved.xyz, float3(0.0, 0.0, 0.0));
    return true;
}

// One compute invocation owns one entry. The ray-tracing -> compute Vulkan barrier makes all atomic
// additions visible before this function runs; the following frame cannot query until queue order makes
// this resolve visible. No raygen invocation ever reads accumulation or writes resolved.
public void sharcResolveEntry(WorldPush push, uint entryIndex) {
    uint capacity = uint(max(push.sharcGridOrigin.w, 0));
    if (!sharcReady(push) || entryIndex >= capacity) {
        return;
    }

    DevicePtr<SharcEntry> cache = DevicePtr<SharcEntry>(push.sharcCacheAddr);
    SharcEntry entry = cache[entryIndex];
    if (entry.metadata.x != SHARC_ENTRY_READY) {
        // A bounded insertion can only leave LOCKED behind after an interrupted/invalid invocation.
        // Recover it here so one bad path cannot permanently consume a probe slot.
        if (entry.metadata.x == SHARC_ENTRY_LOCKED) {
            SharcEntry empty;
            empty.key = uint4(0u, 0u, 0u, 0u);
            empty.accumulation = uint4(0u, 0u, 0u, 0u);
            empty.resolved = float4(0.0, 0.0, 0.0, 0.0);
            empty.metadata = uint4(0u, 0u, 0u, 0u);
            cache[entryIndex] = empty;
        }
        return;
    }

    uint sampleCount = entry.accumulation.w;
    if (sampleCount == 0u) {
        uint staleFrames = entry.metadata.z + 1u;
        uint lifetime = max(uint(push.sharcParams2.z), 1u);
        if (staleFrames >= lifetime) {
            SharcEntry empty;
            empty.key = uint4(0u, 0u, 0u, 0u);
            empty.accumulation = uint4(0u, 0u, 0u, 0u);
            empty.resolved = float4(0.0, 0.0, 0.0, 0.0);
            empty.metadata = uint4(0u, 0u, 0u, 0u);
            cache[entryIndex] = empty;
        } else {
            cache[entryIndex].metadata.z = staleFrames;
        }
        return;
    }

    float normalization = rcp(float(sampleCount) * SHARC_RADIANCE_SCALE);
    float3 frameRadiance = float3(entry.accumulation.xyz) * normalization;
    uint sampledFrames = entry.metadata.y;
    float3 history = entry.resolved.xyz;
    float3 resolvedRadiance;
    if (sampledFrames == 0u || entry.resolved.w <= 0.0) {
        resolvedRadiance = frameRadiance;
    } else {
        // During warm-up use an unbiased running mean: a newly claimed slot may receive only its CAS
        // winner's sample in frame one, so letting that frame dominate would bake one noisy outlier into
        // the cache just as it becomes queryable. After warm-up, TEMPORAL_BLEND controls responsiveness.
        uint warmupFrames = max(uint(push.sharcParams3.x), 1u);
        float freshWeight = sampledFrames < warmupFrames
            ? rcp(float(sampledFrames + 1u))
            : clamp(push.sharcParams.z, 0.0, 0.99);
        resolvedRadiance = lerp(history, frameRadiance, freshWeight);
    }
    if (any(isnan(resolvedRadiance)) || any(isinf(resolvedRadiance))) {
        resolvedRadiance = sampledFrames > 0u ? history : float3(0.0, 0.0, 0.0);
    }

    cache[entryIndex].resolved = float4(max(resolvedRadiance, float3(0.0, 0.0, 0.0)), 1.0);
    cache[entryIndex].accumulation = uint4(0u, 0u, 0u, 0u);
    cache[entryIndex].metadata.y = min(sampledFrames + 1u, 65535u);
    cache[entryIndex].metadata.z = 0u;
}
