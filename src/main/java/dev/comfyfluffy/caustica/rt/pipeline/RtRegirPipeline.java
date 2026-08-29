package dev.comfyfluffy.caustica.rt.pipeline;

import org.lwjgl.system.MemoryStack;
import org.lwjgl.system.MemoryUtil;
import org.lwjgl.vulkan.VK10;
import org.lwjgl.vulkan.VkCommandBuffer;
import org.lwjgl.vulkan.VkComputePipelineCreateInfo;
import org.lwjgl.vulkan.VkDevice;
import org.lwjgl.vulkan.VkPipelineLayoutCreateInfo;
import org.lwjgl.vulkan.VkPipelineShaderStageCreateInfo;
import org.lwjgl.vulkan.VkPushConstantRange;
import org.lwjgl.vulkan.VkShaderModuleCreateInfo;

import java.io.IOException;
import java.io.InputStream;
import java.nio.ByteBuffer;
import java.nio.LongBuffer;

import dev.comfyfluffy.caustica.rt.RtContext;
import dev.comfyfluffy.caustica.rt.RtDebugLabels;
import dev.comfyfluffy.caustica.rt.accel.RtBuffer;

import static dev.comfyfluffy.caustica.rt.RtContext.check;

/**
 * ReGIR world-grid reservoir builder ({@code shaders/world/regir.comp.slang}). One small dispatch
 * per frame rebuilds a fixed {@code GRID_DIMS^3} array of cell reservoirs centred on the camera;
 * the world trace merges each shading point's cell as a single high-quality resampled light
 * candidate (see {@code lighting.slang}'s {@code regirMergeCell}).
 *
 * <p>The pipeline binds no descriptor sets: every input (WorldPush, the published light buffer
 * and its alias table) and the output cell buffer are reached through buffer-device-address
 * pointers carried in the push-constant block, exactly like the ray-tracing push constants.
 */
public final class RtRegirPipeline {
    private static final String SHADER_DIR = "/caustica/rt/";
    private static final String SHADER_NAME = "regir.comp.spv";

    /** Must match REGIR_BUILD_DIMS / REGIR_GRID_DIMS in regir.comp.slang / lighting.slang. */
    public static final int GRID_DIMS = 24;
    /**
     * Must match RegirCell in world_common.slang. std430 layout: float3 pos (16) + uint le,
     * float3 normal (16) + float area, float W + uint M -> 40 bytes rounded up to the struct's
     * 16-byte alignment = 48 bytes per cell.
     */
    public static final int CELL_BYTES = 48;

    /** Push layout mirrors {@code RegirPush} in regir.comp.slang: four 64-bit addresses + two u32. */
    private static final int PUSH_BYTES = 48;

    private final RtContext ctx;
    private final long pipelineLayout;
    private final long pipeline;
    private final RtBuffer cellBuffer;
    private boolean destroyed;

    private RtRegirPipeline(RtContext ctx, long layout, long pipeline, RtBuffer cellBuffer) {
        this.ctx = ctx;
        this.pipelineLayout = layout;
        this.pipeline = pipeline;
        this.cellBuffer = cellBuffer;
    }

    public static RtRegirPipeline create(RtContext ctx) {
        VkDevice vk = ctx.vk();
        long cellBytes = (long) GRID_DIMS * GRID_DIMS * GRID_DIMS * CELL_BYTES;
        RtBuffer cellBuffer = ctx.createAsyncBuffer(cellBytes,
                VK10.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | VK10.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
                false, "regir world-grid reservoirs");
        try (MemoryStack stack = MemoryStack.stackPush()) {
            VkPushConstantRange.Buffer pushRange = VkPushConstantRange.calloc(1, stack);
            pushRange.get(0).stageFlags(VK10.VK_SHADER_STAGE_COMPUTE_BIT).offset(0).size(PUSH_BYTES);
            VkPipelineLayoutCreateInfo plci = VkPipelineLayoutCreateInfo.calloc(stack).sType$Default()
                    .pSetLayouts(null).pPushConstantRanges(pushRange);
            LongBuffer p = stack.mallocLong(1);
            check(VK10.vkCreatePipelineLayout(vk, plci, null, p), "vkCreatePipelineLayout(regir)");
            long layout = p.get(0);
            RtDebugLabels.name(ctx, VK10.VK_OBJECT_TYPE_PIPELINE_LAYOUT, layout, "regir pipeline layout");

            long mod = loadModule(vk, stack);
            RtDebugLabels.name(ctx, VK10.VK_OBJECT_TYPE_SHADER_MODULE, mod, "regir.comp shader module");
            VkPipelineShaderStageCreateInfo stage = VkPipelineShaderStageCreateInfo.calloc(stack)
                    .sType$Default().stage(VK10.VK_SHADER_STAGE_COMPUTE_BIT).module(mod).pName(stack.UTF8("main"));
            VkComputePipelineCreateInfo.Buffer cpci = VkComputePipelineCreateInfo.calloc(1, stack);
            cpci.get(0).sType$Default().stage(stage).layout(layout);
            check(VK10.vkCreateComputePipelines(vk, VK10.VK_NULL_HANDLE, cpci, null, p),
                    "vkCreateComputePipelines(regir)");
            long pipeline = p.get(0);
            RtDebugLabels.name(ctx, VK10.VK_OBJECT_TYPE_PIPELINE, pipeline, "regir reservoir build pipeline");
            VK10.vkDestroyShaderModule(vk, mod, null);
            return new RtRegirPipeline(ctx, layout, pipeline, cellBuffer);
        }
    }

    /**
     * Rebuild the grid for this frame. {@code regirGridXyz} is the rebased-space origin of cell
     * (0,0,0); the shader derives cell centres from WorldPush.regirGrid. The dispatch covers the
     * whole fixed grid (512 threads of 27 cells each — sub-millisecond).
     */
    public void dispatch(VkCommandBuffer cmd, long worldPushAddress, long lightBufferAddress,
                         long lightAliasAddress, int lightCount, int candidates,
                         float gridOriginX, float gridOriginY, float gridOriginZ, float cellSize) {
        try (MemoryStack stack = MemoryStack.stackPush();
             RtDebugLabels.Scope ignored = RtDebugLabels.scope(ctx, cmd, "regir reservoir build")) {
            VK10.vkCmdBindPipeline(cmd, VK10.VK_PIPELINE_BIND_POINT_COMPUTE, pipeline);
            ByteBuffer push = MemoryUtil.memCalloc(PUSH_BYTES);
            try {
                int o = 0;
                putLong(push, o, worldPushAddress); o += 8;
                putLong(push, o, lightBufferAddress); o += 8;
                putLong(push, o, lightAliasAddress); o += 8;
                putLong(push, o, cellBuffer.deviceAddress); o += 8;
                push.putInt(o, lightCount); o += 4;
                push.putInt(o, Math.max(1, candidates)); o += 4;
                push.putInt(o, 0); o += 4;
                push.putInt(o, 0);
                VK10.vkCmdPushConstants(cmd, pipelineLayout, VK10.VK_SHADER_STAGE_COMPUTE_BIT, 0, push);
                VK10.vkCmdDispatch(cmd, (GRID_DIMS + 7) / 8, (GRID_DIMS + 7) / 8, (GRID_DIMS + 7) / 8);
            } finally {
                MemoryUtil.memFree(push);
            }
        }
    }

    public long cellBufferAddress() {
        return cellBuffer != null ? cellBuffer.deviceAddress : 0L;
    }

    public void destroy() {
        if (destroyed) {
            return;
        }
        destroyed = true;
        VkDevice vk = ctx.vk();
        VK10.vkDestroyPipeline(vk, pipeline, null);
        VK10.vkDestroyPipelineLayout(vk, pipelineLayout, null);
        cellBuffer.destroy();
    }

    private static void putLong(ByteBuffer buf, int offset, long value) {
        for (int i = 0; i < 8; i++) {
            buf.put(offset + i, (byte) (value >> (i * 8)));
        }
    }

    private static long loadModule(VkDevice vk, MemoryStack stack) {
        byte[] bytes;
        try (InputStream in = RtRegirPipeline.class.getResourceAsStream(SHADER_DIR + SHADER_NAME)) {
            if (in == null) {
                throw new IllegalStateException("missing SPIR-V resource: " + SHADER_DIR + SHADER_NAME);
            }
            bytes = in.readAllBytes();
        } catch (IOException e) {
            throw new IllegalStateException("failed to read " + SHADER_NAME, e);
        }
        ByteBuffer code = stack.malloc(bytes.length);
        code.put(bytes).flip();
        VkShaderModuleCreateInfo ci = VkShaderModuleCreateInfo.calloc(stack).sType$Default().pCode(code);
        LongBuffer p = stack.mallocLong(1);
        check(VK10.vkCreateShaderModule(vk, ci, null, p), "vkCreateShaderModule(regir)");
        return p.get(0);
    }
}
