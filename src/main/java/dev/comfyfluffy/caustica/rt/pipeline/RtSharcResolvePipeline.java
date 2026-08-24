package dev.comfyfluffy.caustica.rt.pipeline;

import dev.comfyfluffy.caustica.rt.RtContext;
import dev.comfyfluffy.caustica.rt.RtDebugLabels;
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

import static dev.comfyfluffy.caustica.rt.RtContext.check;

/**
 * Resolves SHaRC's atomic per-frame sums into persistent radiance history.
 *
 * <p>The shader reaches both {@code WorldPush} and the monolithic cache through buffer device
 * addresses, so this pipeline needs no descriptor set. Its sole push constant is the current
 * {@code WorldPush} ring-slot address. One invocation owns one cache record; after the ray-tracing to
 * compute barrier it can average samples, advance warm-up/stale counters and recycle old hash slots
 * without any cross-invocation atomics.
 */
public final class RtSharcResolvePipeline {
    private static final String SHADER = "/caustica/rt/sharc_resolve.comp.spv";
    private static final int PUSH_BYTES = Long.BYTES;
    private static final int WORKGROUP_SIZE = 256;

    private final RtContext ctx;
    private final long pipelineLayout;
    private final long pipeline;
    private boolean destroyed;

    private RtSharcResolvePipeline(RtContext ctx, long pipelineLayout, long pipeline) {
        this.ctx = ctx;
        this.pipelineLayout = pipelineLayout;
        this.pipeline = pipeline;
    }

    public static RtSharcResolvePipeline create(RtContext ctx) {
        VkDevice vk = ctx.vk();
        try (MemoryStack stack = MemoryStack.stackPush()) {
            LongBuffer handle = stack.mallocLong(1);
            VkPushConstantRange.Buffer range = VkPushConstantRange.calloc(1, stack)
                    .stageFlags(VK10.VK_SHADER_STAGE_COMPUTE_BIT)
                    .offset(0)
                    .size(PUSH_BYTES);
            VkPipelineLayoutCreateInfo layoutInfo = VkPipelineLayoutCreateInfo.calloc(stack)
                    .sType$Default()
                    .pPushConstantRanges(range);
            check(VK10.vkCreatePipelineLayout(vk, layoutInfo, null, handle),
                    "vkCreatePipelineLayout(SHaRC resolve)");
            long layout = handle.get(0);
            RtDebugLabels.name(ctx, VK10.VK_OBJECT_TYPE_PIPELINE_LAYOUT, layout,
                    "SHaRC resolve pipeline layout");

            long module = loadModule(vk, stack);
            RtDebugLabels.name(ctx, VK10.VK_OBJECT_TYPE_SHADER_MODULE, module,
                    "SHaRC resolve shader module");
            VkPipelineShaderStageCreateInfo stage = VkPipelineShaderStageCreateInfo.calloc(stack)
                    .sType$Default()
                    .stage(VK10.VK_SHADER_STAGE_COMPUTE_BIT)
                    .module(module)
                    .pName(stack.UTF8("main"));
            VkComputePipelineCreateInfo.Buffer pipelineInfo = VkComputePipelineCreateInfo.calloc(1, stack);
            pipelineInfo.get(0).sType$Default().stage(stage).layout(layout);
            check(VK10.vkCreateComputePipelines(vk, VK10.VK_NULL_HANDLE, pipelineInfo, null, handle),
                    "vkCreateComputePipelines(SHaRC resolve)");
            long pipeline = handle.get(0);
            RtDebugLabels.name(ctx, VK10.VK_OBJECT_TYPE_PIPELINE, pipeline, "SHaRC resolve pipeline");
            VK10.vkDestroyShaderModule(vk, module, null);
            return new RtSharcResolvePipeline(ctx, layout, pipeline);
        }
    }

    public void dispatch(VkCommandBuffer cmd, long worldPushAddress, int entryCount) {
        if (destroyed || worldPushAddress == 0L || entryCount <= 0) {
            return;
        }
        try (MemoryStack stack = MemoryStack.stackPush();
             RtDebugLabels.Scope ignored = RtDebugLabels.scope(ctx, cmd, "SHaRC resolve")) {
            VK10.vkCmdBindPipeline(cmd, VK10.VK_PIPELINE_BIND_POINT_COMPUTE, pipeline);
            ByteBuffer push = stack.malloc(PUSH_BYTES);
            push.putLong(0, worldPushAddress);
            VK10.vkCmdPushConstants(cmd, pipelineLayout, VK10.VK_SHADER_STAGE_COMPUTE_BIT, 0, push);
            VK10.vkCmdDispatch(cmd, (entryCount + WORKGROUP_SIZE - 1) / WORKGROUP_SIZE, 1, 1);
        }
    }

    public void destroy() {
        if (destroyed) {
            return;
        }
        destroyed = true;
        VkDevice vk = ctx.vk();
        VK10.vkDestroyPipeline(vk, pipeline, null);
        VK10.vkDestroyPipelineLayout(vk, pipelineLayout, null);
    }

    private static long loadModule(VkDevice vk, MemoryStack stack) {
        byte[] bytes;
        try (InputStream in = RtSharcResolvePipeline.class.getResourceAsStream(SHADER)) {
            if (in == null) {
                throw new IllegalStateException("missing SPIR-V resource: " + SHADER);
            }
            bytes = in.readAllBytes();
        } catch (IOException e) {
            throw new IllegalStateException("failed to read SPIR-V resource: " + SHADER, e);
        }
        ByteBuffer code = MemoryUtil.memAlloc(bytes.length).put(bytes);
        code.flip();
        try {
            VkShaderModuleCreateInfo moduleInfo = VkShaderModuleCreateInfo.calloc(stack)
                    .sType$Default()
                    .pCode(code);
            LongBuffer module = stack.mallocLong(1);
            check(VK10.vkCreateShaderModule(vk, moduleInfo, null, module),
                    "vkCreateShaderModule(SHaRC resolve)");
            return module.get(0);
        } finally {
            MemoryUtil.memFree(code);
        }
    }
}
