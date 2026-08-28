package dev.comfyfluffy.caustica.rt.material;

import dev.comfyfluffy.caustica.rt.gen.MaterialHeaderData;
import dev.comfyfluffy.caustica.rt.gen.MaterialHeaderData.Float4;
import dev.comfyfluffy.caustica.rt.gen.RestcvEstimateData;
import dev.comfyfluffy.caustica.rt.gen.RestirReservoirData;
import dev.comfyfluffy.caustica.rt.gen.WorldPushConstantsData;
import org.junit.jupiter.api.Test;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;

import static org.junit.jupiter.api.Assertions.assertEquals;

final class RtMaterialLayoutTest {
    @Test
    void reflectedMaterialHeaderMatchesHotAbi() {
        assertEquals(80, MaterialHeaderData.BYTE_SIZE);
        ByteBuffer data = ByteBuffer.allocateDirect(MaterialHeaderData.BYTE_SIZE)
                .order(ByteOrder.nativeOrder());
        new MaterialHeaderData(3, 5, 7, 11,
                new Float4(0.01f, 0.02f, 0.03f, 0.04f),
                new Float4(0.05f, 0.06f, 7.0f, 8.0f),
                new Float4(0.1f, 0.2f, 1.52f, 1.0f),
                new Float4(0.3f, 0.4f, 0.5f, 0.6f)).write(data);
        assertEquals(3, data.getInt(0));
        assertEquals(5, data.getInt(4));
        assertEquals(7, data.getInt(8));
        assertEquals(11, data.getInt(12));
        assertEquals(0.01f, data.getFloat(16));
        assertEquals(7.0f, data.getFloat(40));
        assertEquals(0.1f, data.getFloat(48));
        assertEquals(1.52f, data.getFloat(56));
        assertEquals(0.6f, data.getFloat(76));
    }

    @Test
    void reflectedWorldPushConstantsIncludeLightAndRestirBuffers() {
        // 16 uint64_t addresses (world/table/entity, DH table + hand-off mask, material, 5 light
        // buffers, path queue, 2 ReSTIR buffers, 2 ReSTCV buffers) followed by
        // frame/debug/light-generation/restir-mode.
        assertEquals(144, WorldPushConstantsData.BYTE_SIZE);
        ByteBuffer data = ByteBuffer.allocateDirect(WorldPushConstantsData.BYTE_SIZE)
                .order(ByteOrder.nativeOrder());
        new WorldPushConstantsData(1L, 2L, 3L, 4L, 5L, 6L, 7L, 8L, 9L, 10L, 11L, 12L, 13L, 14L,
                15L, 16L, 17, 18, 19, 20).write(data);
        assertEquals(4L, data.getLong(24));   // dhTableAddr
        assertEquals(5L, data.getLong(32));   // dhReadyMaskAddr
        assertEquals(6L, data.getLong(40));   // materialTableAddr
        assertEquals(7L, data.getLong(48));   // lightBufAddr
        assertEquals(11L, data.getLong(80));  // lightGridSpanAddr (last light-buffer address)
        assertEquals(12L, data.getLong(88));  // pathQueueAddr
        assertEquals(13L, data.getLong(96));  // restirPreviousAddr
        assertEquals(14L, data.getLong(104)); // restirCurrentAddr
        assertEquals(15L, data.getLong(112)); // restcvPreviousAddr
        assertEquals(16L, data.getLong(120)); // restcvCurrentAddr
        assertEquals(17, data.getInt(128));   // frameIndex
        assertEquals(18, data.getInt(132));   // debugView
        assertEquals(19, data.getInt(136));   // lightGeneration
        assertEquals(20, data.getInt(140));   // restirMode: authoritative live shading branch
    }

    @Test
    void reflectedRestirRecordStaysCompact() {
        assertEquals(48, RestirReservoirData.BYTE_SIZE);
    }

    @Test
    void reflectedRestcvEstimateIsCompact() {
        assertEquals(16, RestcvEstimateData.BYTE_SIZE);
    }
}
