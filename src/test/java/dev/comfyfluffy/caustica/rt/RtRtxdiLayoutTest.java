package dev.comfyfluffy.caustica.rt;

import org.junit.jupiter.api.Test;

import java.util.HashSet;
import java.util.Set;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Pins the host-side RTXDI layouts and tables against the vendored SDK core they must match.
 *
 * <p>{@link RtRtxdiLayout} is the Java mirror of the RTXDI SDK's device-side contracts: the
 * block-linear reservoir addressing ({@code RTXDI_ReservoirPositionToPointer}), the packed
 * reservoir stride, and the neighbor-offset disk ({@code FillNeighborOffsetBuffer}). If either
 * side drifts, the shader silently reads the wrong reservoir — these tests make the drift loud
 * without needing a GPU.
 */
final class RtRtxdiLayoutTest {

    @Test
    void reservoirPointerMatchesTheSdkTiledLayout() {
        // 100x60 image: 7x4 blocks of 16x16, so each layer holds 28 blocks = 7168 reservoirs.
        int width = 100;
        int height = 60;
        long arrayPitch = RtRtxdiLayout.arrayPitch(width, height);
        assertEquals(7168L, arrayPitch, "block pitch/layer must be blocksX*blocksY*256");

        // Every pixel must map to a unique reservoir slot inside its layer, and the two layers
        // must not overlap — the SDK's pointer math is pure bit tiling, so a collision means the
        // host and device layouts disagree.
        Set<Long>[] seen = new Set[]{new HashSet<>(), new HashSet<>()};
        for (int layer = 0; layer < 2; layer++) {
            for (int y = 0; y < height; y++) {
                for (int x = 0; x < width; x++) {
                    long pointer = RtRtxdiLayout.reservoirPointer(layer, x, y, width, arrayPitch);
                    assertTrue(pointer >= 0 && pointer < arrayPitch,
                            "pointer must stay inside its own layer");
                    assertTrue(seen[layer].add(pointer),
                            "pixel (" + x + "," + y + ") layer " + layer + " collides in the tile map");
                }
            }
        }

        // The SDK's own worked example: within a block, x grows fastest, then y, then blocks
        // x-major across the row, then block rows.
        assertEquals(0L, RtRtxdiLayout.reservoirPointer(0, 0, 0, width, arrayPitch));
        assertEquals(1L, RtRtxdiLayout.reservoirPointer(0, 1, 0, width, arrayPitch));
        assertEquals(16L, RtRtxdiLayout.reservoirPointer(0, 0, 1, width, arrayPitch));
        assertEquals(256L, RtRtxdiLayout.reservoirPointer(0, 16, 0, width, arrayPitch));
        assertEquals(1792L, RtRtxdiLayout.reservoirPointer(0, 0, 16, width, arrayPitch),
                "the second block row starts after one block row pitch (7 blocks of 256 for width 100)");
        assertEquals(arrayPitch, RtRtxdiLayout.reservoirPointer(1, 0, 0, width, arrayPitch),
                "layer 1 begins exactly one array pitch after layer 0");
    }

    @Test
    void nonMultipleSizesAllocateWholeBlocks() {
        // 17x17 must round up to 2x2 blocks, never clip the tail pixel's storage.
        long pitch = RtRtxdiLayout.arrayPitch(17, 17);
        assertEquals(4L * 256L, pitch);
        long pointer = RtRtxdiLayout.reservoirPointer(0, 16, 16, 17, pitch);
        assertTrue(pointer < pitch, "the corner pixel of the padded tail block must be addressable");
        assertEquals(2L * 256L * RtRtxdiLayout.RESERVOIR_BYTES,
                RtRtxdiLayout.reservoirBufferBytes(16, 16),
                "a 16x16 image is exactly one block, two layers");
    }

    @Test
    void packedStridesMatchTheSdlPackedRecords() {
        // RTXDI_PackedDIReservoir: 4 uints + 2 floats, scalar std430 alignment, no tail padding.
        assertEquals(24, RtRtxdiLayout.RESERVOIR_BYTES);
        // RtxdiSurfaceHistory: float4 posDepth + uint4 material.
        assertEquals(32, RtRtxdiLayout.SURFACE_HISTORY_BYTES);
        // The packed M/age fields the SDK clamps into before storing.
        assertEquals(0x3fff, RtRtxdiLayout.MAX_M);
        assertEquals(0xff, RtRtxdiLayout.MAX_AGE);
    }

    @Test
    void neighborOffsetsFormTheSdkLowDiscrepancyDisk() {
        float[] offsets = RtRtxdiLayout.neighborOffsets();
        assertEquals(RtRtxdiLayout.NEIGHBOR_OFFSET_COUNT * 2, offsets.length,
                "the table must be exactly NEIGHBOR_OFFSET_COUNT float pairs");
        assertEquals(RtRtxdiLayout.NEIGHBOR_OFFSET_COUNT - 1, RtRtxdiLayout.NEIGHBOR_OFFSET_MASK,
                "the mask assumes a power-of-two table");
        int outside = 0;
        double sumX = 0;
        double sumY = 0;
        for (int i = 0; i < RtRtxdiLayout.NEIGHBOR_OFFSET_COUNT; i++) {
            float x = offsets[i * 2];
            float y = offsets[i * 2 + 1];
            float rSq = x * x + y * y;
            assertTrue(Float.isFinite(x) && Float.isFinite(y), "offsets must be finite");
            assertTrue(rSq <= 1.0f + 1.0e-5f, "every offset must lie inside the unit disk");
            // The R2 sequence's disk restriction keeps points off the corners, but they must still
            // spread over the full radius or spatial reuse degenerates to a tiny cluster.
            sumX += x;
            sumY += y;
            if (rSq < 0.01f) {
                outside++;
            }
        }
        assertTrue(outside < RtRtxdiLayout.NEIGHBOR_OFFSET_COUNT / 4,
                "the offsets must not collapse toward the center");
        assertTrue(Math.abs(sumX / RtRtxdiLayout.NEIGHBOR_OFFSET_COUNT) < 0.05,
                "the low-discrepancy sequence must be roughly centered");
        assertTrue(Math.abs(sumY / RtRtxdiLayout.NEIGHBOR_OFFSET_COUNT) < 0.05,
                "the low-discrepancy sequence must be roughly centered");

        // Deterministic: the table is uploaded once, so regeneration must be identical.
        float[] again = RtRtxdiLayout.neighborOffsets();
        for (int i = 0; i < offsets.length; i++) {
            assertEquals(offsets[i], again[i], 0.0f, "the table must be reproducible");
        }
    }
}
