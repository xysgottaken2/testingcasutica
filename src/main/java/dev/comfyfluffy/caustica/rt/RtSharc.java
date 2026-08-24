package dev.comfyfluffy.caustica.rt;

import com.mojang.blaze3d.vulkan.VulkanCommandEncoder;
import dev.comfyfluffy.caustica.CausticaConfig;
import dev.comfyfluffy.caustica.CausticaMod;
import dev.comfyfluffy.caustica.rt.accel.RtBuffer;
import dev.comfyfluffy.caustica.rt.pipeline.RtSharcResolvePipeline;
import org.lwjgl.system.MemoryStack;
import org.lwjgl.vulkan.VK10;
import org.lwjgl.vulkan.VkCommandBuffer;

/**
 * Host-side state for the experimental SHaRC (Spatially Hashed Radiance Cache) integration.
 *
 * <p>The integration needs no native library or descriptor binding. Caustica allocates one persistent
 * device-addressed storage buffer, zeroes it, and publishes it through
 * {@code WorldPush.sharcCacheAddr}. Ray tracing writes only atomic per-frame accumulation lanes;
 * {@link RtSharcResolvePipeline} then resolves them into immutable query history after the trace.
 * Keeping update, resolve and query as distinct phases prevents same-dispatch float data races.
 *
 * <p>The buffer is device-local (the GPU is the only consumer) and is cleared with a
 * {@code vkCmdFillBuffer} on the same queue, so a drop-in reset does not need a host-visible mapping
 * or coherent-memory fallback. The entry count and layout are pinned by {@code sharc.slang}
 * ({@value #ENTRY_BYTES} bytes per entry).
 */
public final class RtSharc {
    /** Single current instance, shared by the renderer and the options UI. */
    public static final RtSharc INSTANCE = new RtSharc();

    /** Must match {@code SharcEntry} in {@code shaders/world/sharc.slang}. */
    public static final int ENTRY_BYTES = 64;
    public static final int MIN_ENTRIES = 2048;
    public static final int MAX_ENTRIES = 1 << 18; // 262144

    private RtBuffer cache;
    private RtSharcResolvePipeline resolvePipeline;
    private int entryCount;
    private int cellSize;
    private boolean clearRequested;

    private RtSharc() {
    }

    public boolean enabled() {
        return CausticaConfig.Rt.Sharc.ENABLED.value();
    }

    public int configuredEntryCount() {
        return Math.clamp(CausticaConfig.Rt.Sharc.CACHE_ENTRIES.value(), MIN_ENTRIES, MAX_ENTRIES);
    }

    private static int configuredCellSize() {
        return Math.clamp(Math.round(CausticaConfig.Rt.Sharc.CELL_SIZE.value()), 1, 64);
    }

    /** Create (or resize/clear) the cache buffer for the current config. Called on the render thread. */
    public synchronized void ensure(RtContext ctx) {
        if (resolvePipeline == null) {
            resolvePipeline = RtSharcResolvePipeline.create(ctx);
        }
        int wanted = configuredEntryCount();
        if (cache != null && entryCount != wanted) {
            rebuild(ctx, wanted);
        } else if (cache == null) {
            rebuild(ctx, wanted);
        }
        int wantedCellSize = configuredCellSize();
        if (cache != null && cellSize != wantedCellSize) {
            // Cell coordinates are part of every hash key. Keeping old owners after changing the
            // quantizer would block the new grid behind live-looking collisions until their lifetime.
            ctx.waitIdle();
            cellSize = wantedCellSize;
            clearNow(ctx);
            logDebug("SHaRC cache cleared: voxel size changed to {} blocks", cellSize);
        }
        // An explicit reset is handled by the caller after idling the device, so it is not raced
        // against a trace that may still point at the old contents.
    }

    public synchronized void requestClear() {
        clearRequested = true;
    }

    public synchronized boolean clearRequested() {
        return clearRequested;
    }

    public long address() {
        return cache != null ? cache.deviceAddress : 0L;
    }

    public int entryCount() {
        return cache != null ? entryCount : 0;
    }

    /**
     * Resolve this frame's atomic update sums into queryable history. The caller must place a memory
     * barrier between ray tracing and this dispatch, and another before any later consumer.
     */
    public synchronized void resolve(VkCommandBuffer cmd, long worldPushAddress) {
        if (cache != null && resolvePipeline != null && entryCount > 0) {
            resolvePipeline.dispatch(cmd, worldPushAddress, entryCount);
        }
    }

    public synchronized void releaseIfDisabled(RtContext ctx) {
        if (!enabled() && (cache != null || resolvePipeline != null)) {
            destroyNow(ctx);
        }
    }

    public synchronized void destroy(RtContext ctx) {
        destroyNow(ctx);
    }

    private void rebuild(RtContext ctx, int wanted) {
        boolean resize = cache != null;
        if (resize) {
            // Wait for any in-flight trace that still points at the old buffer before freeing it.
            ctx.waitIdle();
            cache.destroy();
            logDebug("SHaRC cache buffer resized: new entries={}, total={} MiB", wanted, bytesMiB(wanted));
        } else {
            logDebug("SHaRC cache buffer allocated: entries={}, total={} MiB, entryBytes={}",
                    wanted, bytesMiB(wanted), ENTRY_BYTES);
        }
        long bytes = (long) wanted * ENTRY_BYTES;
        int usage = VK10.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | VK10.VK_BUFFER_USAGE_TRANSFER_DST_BIT;
        cache = ctx.createBuffer(bytes, usage, false, "rt sharc radiance cache");
        entryCount = wanted;
        cellSize = configuredCellSize();
        clearNow(ctx);
    }

    /** Clear the whole cache on the command queue; {@code submitSync} also waits for completion. */
    public synchronized void clearNow(RtContext ctx) {
        if (cache != null) {
            ctx.submitSync(cmd -> {
                VK10.vkCmdFillBuffer(cmd, cache.handle, 0L, cache.size, 0);
                try (MemoryStack stack = MemoryStack.stackPush()) {
                    VulkanCommandEncoder.memoryBarrier(cmd, stack);
                }
            });
        }
        clearRequested = false;
    }

    private void destroyNow(RtContext ctx) {
        if ((cache != null || resolvePipeline != null) && ctx != null) {
            ctx.waitIdle();
        }
        if (cache != null) {
            cache.destroy();
            cache = null;
            entryCount = 0;
            cellSize = 0;
            logDebug("SHaRC cache buffer released");
        }
        if (resolvePipeline != null) {
            resolvePipeline.destroy();
            resolvePipeline = null;
        }
        clearRequested = false;
    }

    private static double bytesMiB(int entries) {
        return (long) entries * ENTRY_BYTES / (1024.0 * 1024.0);
    }

    private static void logDebug(String message, Object... args) {
        CausticaMod.LOGGER.info("[SHaRC] " + message, args);
    }
}
