package dev.comfyfluffy.caustica.rt;

/**
 * Pure host-side mirror of the RTXDI SDK's device layouts and tables.
 *
 * <p>These constants and functions must stay in lockstep with the vendored SDK core under
 * {@code shaders/rtxdi/Rtxdi} (and the bridge in {@code shaders/world/rtxdi.slang}):
 *
 * <ul>
 *   <li>{@link #reservoirPointer(int, int, int, int, long)} is a line-by-line port of
 *       {@code RTXDI_ReservoirPositionToPointer} — reservoirs live in one device buffer with two
 *       ping-pong array layers, tiled into {@code RTXDI_RESERVOIR_BLOCK_SIZE}&times;{@code
 *       RTXDI_RESERVOIR_BLOCK_SIZE} pixel blocks (16&times;16), blocks tiled x-major across each
 *       block row, block rows stacked to a layer, layers stacked to the buffer.</li>
 *   <li>{@link #neighborOffsets()} is a float transcription of the SDK's
 *       {@code rtxdi::FillNeighborOffsetBuffer} (R2 low-discrepancy sequence restricted to the unit
 *       disk). The SDK stores the table quantized as RG8_SNORM bytes; Caustica's buffer addressing
 *       is untyped, so the offsets are stored as float pairs in the same [-1, 1] disk and the
 *       shader scales them by the sampling radius exactly as the SDK does.</li>
 * </ul>
 *
 * <p>Everything here is deterministic and free of Vulkan state, so the tests pin the layout and
 * the table's statistical properties without a device.
 */
public final class RtRtxdiLayout {
    /** {@code RTXDI_RESERVOIR_BLOCK_SIZE}: reservoir tiles are 16&times;16 pixels. */
    public static final int RESERVOIR_BLOCK_SIZE = 16;

    /**
     * std430 stride of {@code RTXDI_PackedDIReservoir}: four 32-bit lanes (lightData, uvData,
     * mVisibility, distanceAge) followed by two floats (targetPdf, weight). Scalar alignment only,
     * so the struct packs to exactly 24 bytes with no tail padding.
     */
    public static final int RESERVOIR_BYTES = 24;

    /**
     * std430 stride of the bridge's {@code RtxdiSurfaceHistory} record: float4 posDepth + uint4
     * material, both 16-byte aligned.
     */
    public static final int SURFACE_HISTORY_BYTES = 32;

    /** Number of neighbor offsets in the table; must be a power of two for the mask to hold. */
    public static final int NEIGHBOR_OFFSET_COUNT = 8192;

    /** {@code RTXDI_RuntimeParameters.neighborOffsetMask}: the shader wraps indices with {@code &}. */
    public static final int NEIGHBOR_OFFSET_MASK = NEIGHBOR_OFFSET_COUNT - 1;

    /** {@code RTXDI_PackedDIReservoir_MaxM}: the packed reservoir's 14-bit M field. */
    public static final int MAX_M = 0x3fff;

    /** {@code RTXDI_PackedDIReservoir_MaxAge}: the packed reservoir's 8-bit age field. */
    public static final int MAX_AGE = 0xff;

    private RtRtxdiLayout() {
    }

    /** {@code reservoirBlockRowPitch}: reservoirs per block row = blocksX * 16 * 16. */
    public static int blockRowPitch(int width) {
        return blockCount(width) * RESERVOIR_BLOCK_SIZE * RESERVOIR_BLOCK_SIZE;
    }

    /** Reservoirs per array layer: block rows stacked over the full (padded) height. */
    public static long arrayPitch(int width, int height) {
        return (long) blockRowPitch(width) * blockCount(height);
    }

    /**
     * Total reservoir-buffer size for the two ping-pong layers. The previous frame reads layer
     * {@code previousLayer}; the current frame stores into the other.
     */
    public static long reservoirBufferBytes(int width, int height) {
        return arrayPitch(width, height) * 2L * RESERVOIR_BYTES;
    }

    /** Surface-history buffer size for one frame of receiver records (linear pixel indexing). */
    public static long surfaceHistoryBufferBytes(int width, int height) {
        return (long) width * height * SURFACE_HISTORY_BYTES;
    }

    /** Port of {@code RTXDI_ReservoirPositionToPointer} — see the class docs for the layout. */
    public static long reservoirPointer(int layer, int x, int y, int width, long arrayPitch) {
        int blockIdxX = x / RESERVOIR_BLOCK_SIZE;
        int positionInBlockX = x % RESERVOIR_BLOCK_SIZE;
        int blockIdxY = y / RESERVOIR_BLOCK_SIZE;
        int positionInBlockY = y % RESERVOIR_BLOCK_SIZE;
        return layer * arrayPitch
                + (long) blockIdxY * blockRowPitch(width)
                + (long) blockIdxX * (RESERVOIR_BLOCK_SIZE * RESERVOIR_BLOCK_SIZE)
                + positionInBlockY * RESERVOIR_BLOCK_SIZE
                + positionInBlockX;
    }

    /**
     * The neighbor-offset table as interleaved (x, y) pairs — the SDK's R2-sequence disk with the
     * same {@code phi2} additive recurrence, stored at float precision (see class docs). Entries
     * live in the unit disk, so the shader's {@code offset * samplingRadius} matches the SDK's
     * snorm interpretation.
     */
    public static float[] neighborOffsets() {
        float[] offsets = new float[NEIGHBOR_OFFSET_COUNT * 2];
        // Create a sequence of low-discrepancy samples within a unit radius around the origin
        // for "randomly" sampling neighbors during spatial resampling.
        final float phi2 = 1.0f / 1.3247179572447f;
        int num = 0;
        float u = 0.5f;
        float v = 0.5f;
        while (num < NEIGHBOR_OFFSET_COUNT) {
            u += phi2;
            v += phi2 * phi2;
            if (u >= 1.0f) {
                u -= 1.0f;
            }
            if (v >= 1.0f) {
                v -= 1.0f;
            }
            float dx = u - 0.5f;
            float dy = v - 0.5f;
            float rSq = dx * dx + dy * dy;
            if (rSq > 0.25f) {
                continue; // outside the unit-disk radius (0.5 in the sequence's unit square)
            }
            offsets[num * 2] = dx * 2.0f;
            offsets[num * 2 + 1] = dy * 2.0f;
            num++;
        }
        return offsets;
    }

    static int blockCount(int extent) {
        return (extent + RESERVOIR_BLOCK_SIZE - 1) / RESERVOIR_BLOCK_SIZE;
    }
}
