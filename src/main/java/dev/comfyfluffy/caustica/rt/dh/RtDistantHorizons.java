package dev.comfyfluffy.caustica.rt.dh;

import dev.comfyfluffy.caustica.CausticaMod;
import dev.comfyfluffy.caustica.rt.RtContext;
import dev.comfyfluffy.caustica.rt.RtFrameStats;
import dev.comfyfluffy.caustica.rt.accel.RtBuffer;
import it.unimi.dsi.fastutil.longs.Long2ObjectOpenHashMap;
import net.fabricmc.loader.api.FabricLoader;
import org.lwjgl.system.MemoryUtil;
import org.lwjgl.vulkan.VK10;
import java.util.concurrent.ConcurrentLinkedQueue;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * Distant Horizons integration — 100% async, soft dependency via reflection.
 *
 * <p>All DH API calls (SQLite I/O + reflection) run on a dedicated background thread.
 * The background thread also builds simplified grid meshes from collected height samples.
 * The render thread only polls concurrent queues — zero I/O, zero reflection.</p>
 */
public final class RtDistantHorizons {
    private static final RtDistantHorizons INSTANCE = new RtDistantHorizons();
    /** Build a grid mesh every time this many new samples arrive. */
    private static final int MESH_BUILD_INTERVAL = 200;
    /** Grid size (in chunks) for each mesh tile. */
    private static final int GRID_SIZE = 5;

    private final boolean dhAvailable;
    private final AtomicBoolean apiReady = new AtomicBoolean(false);
    private final ExecutorService background = Executors.newSingleThreadExecutor(r -> {
        Thread t = new Thread(r, "caustica-dh-worker");
        t.setDaemon(true);
        return t;
    });
    private final AtomicBoolean workerActive = new AtomicBoolean(false);

    /** Background → Render thread: raw height samples. */
    private final ConcurrentLinkedQueue<LodSample> sampleQueue = new ConcurrentLinkedQueue<>();
    /** Background → Render thread: completed grid meshes. */
    private final ConcurrentLinkedQueue<DhLodMesh> meshQueue = new ConcurrentLinkedQueue<>();

    /** Track which meshes have been uploaded to GPU (render thread). Key = tileKey(ox, oz). */
    private final Long2ObjectOpenHashMap<LodGpuBuffers> gpuMeshes = new Long2ObjectOpenHashMap<>();
    /** UVs for the terrain (positions, indices) use this AS-input usage. */
    private static final int AS_INPUT = org.lwjgl.vulkan.KHRAccelerationStructure
            .VK_BUFFER_USAGE_ACCELERATION_STRUCTURE_BUILD_INPUT_READ_ONLY_BIT_KHR;

    /** Accumulated height samples (background thread only). Key = chunkKey(cx, cz). */
    private final Long2ObjectOpenHashMap<LodSample> sampleMap = new Long2ObjectOpenHashMap<>();
    /** Track which grid tiles have been built (background thread only). Key = tileKey(rx, rz). */
    private final Long2ObjectOpenHashMap<Boolean> builtTiles = new Long2ObjectOpenHashMap<>();
    /** Samples received since last mesh build pass. */
    private int samplesSinceLastMesh;

    // Reflection handles
    private volatile Object terrainRepo;
    private volatile Object worldProxy;
    private volatile java.lang.reflect.Method getDataMethod;
    private volatile java.lang.reflect.Method createCacheMethod;
    private volatile java.lang.reflect.Method getLevelMethod;

    private RtDistantHorizons() {
        this.dhAvailable = FabricLoader.getInstance().isModLoaded("distanthorizons");
    }

    public static RtDistantHorizons getInstance() { return INSTANCE; }
    public static boolean isDhAvailable() { return INSTANCE.dhAvailable; }

    // ---- Render thread API (tick / frame) ----

    public void tick() {
        if (!dhAvailable) return;
        // Drain sample queue (fast, no I/O)
        while (sampleQueue.poll() != null) {}
        // Drain mesh queue
        int meshes = 0;
        while (meshQueue.poll() != null) meshes++;
        if (meshes > 0) RtFrameStats.FRAME.count("dhMeshesReceived", meshes);

        if (apiReady.get() && workerActive.compareAndSet(false, true)) {
            background.submit(this::backgroundLoop);
            CausticaMod.LOGGER.info("[DH] Worker started");
        }
        if (!apiReady.get()) background.submit(this::tryInit);
    }

    public void frame() {
        if (!dhAvailable) return;
        // Convert queued CPU meshes to GPU buffers
        RtContext ctx = RtContext.currentOrNull();
        if (ctx != null) {
            DhLodMesh mesh;
            int uploaded = 0;
            while ((mesh = meshQueue.poll()) != null) {
                long tk = tileKey(mesh.originChunkX(), mesh.originChunkZ());
                if (!gpuMeshes.containsKey(tk)) {
                    LodGpuBuffers gpu = uploadMeshToGpu(ctx, mesh);
                    if (gpu != null) {
                        gpuMeshes.put(tk, gpu);
                        uploaded++;
                    }
                }
            }
            if (uploaded > 0) {
                RtFrameStats.FRAME.count("dhGpuMeshesUploaded", uploaded);
                CausticaMod.LOGGER.info("[DH] Uploaded {} LOD meshes to GPU (total: {})",
                        uploaded, gpuMeshes.size());
            }
        } else {
            // No context yet — just drain to avoid buildup
            while (meshQueue.poll() != null) {}
        }
    }

    public void onWorldUnload() {
        sampleQueue.clear();
        meshQueue.clear();
        // Destroy any allocated GPU buffers
        for (var entry : gpuMeshes.long2ObjectEntrySet()) {
            entry.getValue().destroy();
        }
        gpuMeshes.clear();
        sampleMap.clear();
        builtTiles.clear();
        samplesSinceLastMesh = 0;
    }

    public int sampledCount() { return sampleMap.size(); }
    public int meshCount() { return builtTiles.size(); }

    // ---- Background thread: init, scan, mesh build ----

    private void tryInit() {
        try {
            Class<?> d = Class.forName("com.seibel.distanthorizons.api.DhApi$Delayed");
            this.terrainRepo = d.getField("terrainRepo").get(null);
            this.worldProxy = d.getField("worldProxy").get(null);
            if (terrainRepo == null || worldProxy == null) return;

            this.getDataMethod = findMethod(terrainRepo.getClass(), "getAllTerrainDataAtChunkPos", 4);
            this.createCacheMethod = findMethod(terrainRepo.getClass(), "createSoftCache", 0);
            this.getLevelMethod = findMethod(worldProxy.getClass(), "getSinglePlayerLevel", 0);
            if (getDataMethod == null || createCacheMethod == null || getLevelMethod == null) return;

            apiReady.set(true);
            CausticaMod.LOGGER.info("[DH] API ready (async)");
        } catch (Exception e) {
            CausticaMod.LOGGER.debug("[DH] Init: {}", e.getMessage());
        }
    }

    private void backgroundLoop() {
        while (true) {
            try {
                backgroundScan();
                tryMeshBuild();
                Thread.sleep(100);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt(); break;
            } catch (Exception e) {
                CausticaMod.LOGGER.debug("[DH] Worker: {}", e.getMessage());
            }
        }
    }

    private void backgroundScan() {
        var mc = net.minecraft.client.Minecraft.getInstance();
        if (mc.level == null || mc.player == null) return;
        if (terrainRepo == null) return;

        int pcx = mc.player.getBlockX() >> 4;
        int pcz = mc.player.getBlockZ() >> 4;
        int rd = mc.options.getEffectiveRenderDistance();
        int inner = rd + 2, maxRing = 128 / 8;

        try {
            Object cache = createCacheMethod.invoke(terrainRepo);
            Object lv = getLevelMethod.invoke(worldProxy);
            if (lv == null) return;

            for (int r = inner; r <= maxRing && r < inner + 4; r++) {
                for (int dx = -r; dx <= r; dx++) {
                    for (int dz = -r; dz <= r; dz++) {
                        if ((int)Math.sqrt(dx*dx+dz*dz) != r) continue;
                        sampleOne(pcx + dx*8, pcz + dz*8, lv, cache);
                    }
                }
            }
        } catch (Exception e) {
            CausticaMod.LOGGER.debug("[DH] Scan: {}", e.getMessage());
        }
    }

    private void sampleOne(int cx, int cz, Object lv, Object cache) {
        try {
            Object result = getDataMethod.invoke(terrainRepo, lv, cx, cz, cache);
            if (result == null) return;
            Object data = extractData(result);
            if (!(data instanceof Object[][][] cols) || cols.length < 16) return;

            float maxY = -Float.MAX_VALUE;
            for (int x = 0; x < 16 && x < cols.length; x += 8) {
                var row = cols[x];
                if (row == null || row.length < 16) continue;
                for (int z = 0; z < 16; z += 8) {
                    var col = row[z];
                    if (col == null) continue;
                    for (var p : col) {
                        if (p == null) continue;
                        try { int y = p.getClass().getField("topYBlockPos").getInt(p); if (y > maxY) maxY = y; }
                        catch (Exception ignored) {}
                    }
                }
            }
            if (maxY > -Float.MAX_VALUE) {
                int worldY = (mc().level != null ? mc().level.getMinY() : -64) + (int)maxY;
                long key = chunkKey(cx, cz);
                // Only add if new or higher
                LodSample old = sampleMap.get(key);
                if (old == null || old.surfaceY < worldY) {
                    LodSample s = new LodSample(cx, cz, worldY);
                    sampleMap.put(key, s);
                    sampleQueue.offer(s);
                    samplesSinceLastMesh++;
                }
            }
        } catch (Exception ignored) {}
    }

    /** Check accumulated samples and build grid meshes for complete tiles. */
    private void tryMeshBuild() {
        if (samplesSinceLastMesh < MESH_BUILD_INTERVAL) return;
        samplesSinceLastMesh = 0;

        // Find candidate tile origins from current samples
        // A tile is a GRID_SIZE x GRID_SIZE block of samples
        // We check every sample as a potential tile corner
        Long2ObjectOpenHashMap<int[]> candidates = new Long2ObjectOpenHashMap<>();
        for (var entry : sampleMap.long2ObjectEntrySet()) {
            long key = entry.getLongKey();
            int cx = (int)(key >> 32);
            int cz = (int)key;
            // Round down to nearest GRID_SIZE boundary
            int ox = (cx / GRID_SIZE) * GRID_SIZE;
            int oz = (cz / GRID_SIZE) * GRID_SIZE;
            long tileKey = tileKey(ox, oz);
            if (builtTiles.containsKey(tileKey)) continue;

            int[] count = candidates.get(tileKey);
            if (count == null) {
                candidates.put(tileKey, new int[]{1});
            } else {
                count[0]++;
            }
        }

        // Build meshes for complete tiles
        int built = 0;
        for (var entry : candidates.long2ObjectEntrySet()) {
            if (entry.getValue()[0] < GRID_SIZE * GRID_SIZE * 0.6) continue; // 60% fill threshold
            long tileKey = entry.getLongKey();
            int ox = (int)(tileKey >> 32);
            int oz = (int)tileKey;
            if (builtTiles.containsKey(tileKey)) continue;

            DhLodMesh mesh = buildTileMesh(ox, oz);
            if (mesh != null) {
                meshQueue.offer(mesh);
                builtTiles.put(tileKey, Boolean.TRUE);
                built++;
            }
        }
        if (built > 0) CausticaMod.LOGGER.debug("[DH] Built {} LOD mesh tiles", built);
    }

    /**
     * Build a grid mesh for one tile (GRID_SIZE × GRID_SIZE samples).
     * Each quad connects 4 adjacent height samples into 2 triangles.
     */
    private DhLodMesh buildTileMesh(int ox, int oz) {
        // Count how many columns we actually have
        int[][] heights = new int[GRID_SIZE][GRID_SIZE];
        boolean[][] filled = new boolean[GRID_SIZE][GRID_SIZE];
        int filledCount = 0;
        for (int gx = 0; gx < GRID_SIZE; gx++) {
            for (int gz = 0; gz < GRID_SIZE; gz++) {
                long k = chunkKey(ox + gx, oz + gz);
                LodSample s = sampleMap.get(k);
                if (s != null) {
                    heights[gx][gz] = s.surfaceY;
                    filled[gx][gz] = true;
                    filledCount++;
                }
            }
        }
        if (filledCount < 4) return null; // need at least 1 quad

        // Count quads
        int quadRows = GRID_SIZE - 1;
        int quadCols = GRID_SIZE - 1;
        int quadCount = 0;
        boolean[][] quadFilled = new boolean[quadRows][quadCols];
        for (int gx = 0; gx < quadRows; gx++) {
            for (int gz = 0; gz < quadCols; gz++) {
                if (filled[gx][gz] && filled[gx+1][gz] && filled[gx][gz+1] && filled[gx+1][gz+1]) {
                    quadFilled[gx][gz] = true;
                    quadCount++;
                }
            }
        }
        if (quadCount == 0) return null;

        // Each quad = 4 vertices, 6 indices, 6 corner UVs, 2 triangles × 12 material floats
        // Sample spacing = 8 chunks = 128 blocks
        int sampleSpacing = 128;
        int oxBlock = ox << 4;
        int ozBlock = oz << 4;

        float[] pos = new float[quadCount * 4 * 3];
        int[] idx = new int[quadCount * 6];
        float[] uv = new float[quadCount * 6];  // 6 UVs per quad (2 triangles, 3 corners each, 2 coords... actually 6 floats per triangle = 12 per quad)
        // Actually we need 12 floats per quad for corner UVs (2 triangles × 3 corners × 2 coords)
        float[] cornerUv = new float[quadCount * 12];
        float[] mat = new float[quadCount * 24]; // 12 floats per triangle × 2 triangles

        int vi = 0, ii = 0, ui = 0, mi = 0;

        for (int gx = 0; gx < quadRows; gx++) {
            for (int gz = 0; gz < quadCols; gz++) {
                if (!quadFilled[gx][gz]) continue;

                float x0 = oxBlock + gx * sampleSpacing;
                float x1 = x0 + sampleSpacing;
                float z0 = ozBlock + gz * sampleSpacing;
                float z1 = z0 + sampleSpacing;
                float y00 = heights[gx][gz];
                float y10 = heights[gx+1][gz];
                float y01 = heights[gx][gz+1];
                float y11 = heights[gx+1][gz+1];

                // 4 vertices (xyz)
                int v0 = vi; pos[vi++] = x0; pos[vi++] = y00; pos[vi++] = z0;
                int v1 = vi; pos[vi++] = x1; pos[vi++] = y10; pos[vi++] = z0;
                int v2 = vi; pos[vi++] = x0; pos[vi++] = y01; pos[vi++] = z1;
                int v3 = vi; pos[vi++] = x1; pos[vi++] = y11; pos[vi++] = z1;

                // 2 triangles: 0-1-2, 1-3-2
                idx[ii++] = v0; idx[ii++] = v1; idx[ii++] = v2;
                idx[ii++] = v1; idx[ii++] = v3; idx[ii++] = v2;

                // Corner UVs: 2 triangles, 3 corners each, 2 floats = 12 floats per quad
                // Tri 0: corners 0,1,2
                cornerUv[ui++] = 0; cornerUv[ui++] = 0;
                cornerUv[ui++] = 1; cornerUv[ui++] = 0;
                cornerUv[ui++] = 0; cornerUv[ui++] = 1;
                // Tri 1: corners 1,3,2
                cornerUv[ui++] = 1; cornerUv[ui++] = 0;
                cornerUv[ui++] = 1; cornerUv[ui++] = 1;
                cornerUv[ui++] = 0; cornerUv[ui++] = 1;

                // Compute normal (upward)
                float nx = 0, ny = 1, nz = 0;
                // Material: 12 floats per triangle (normal.xyzw, tint.rgba, materialId, flags, aux0, aux1)
                for (int t = 0; t < 2; t++) {
                    mat[mi++] = nx; mat[mi++] = ny; mat[mi++] = nz; mat[mi++] = 0;   // normal + emission
                    mat[mi++] = 1; mat[mi++] = 1; mat[mi++] = 1; mat[mi++] = 0;      // tint white
                    mat[mi++] = Float.intBitsToFloat(0); // materialId = 0 (block atlas fallback)
                    mat[mi++] = 0; // flags
                    mat[mi++] = 0; // aux0
                    mat[mi++] = 0; // aux1
                }
            }
        }

        // Trim arrays
        float[] trimPos = new float[vi];
        System.arraycopy(pos, 0, trimPos, 0, vi);
        int[] trimIdx = new int[ii];
        System.arraycopy(idx, 0, trimIdx, 0, ii);
        float[] trimUv = new float[ui];
        System.arraycopy(cornerUv, 0, trimUv, 0, ui);
        float[] trimMat = new float[mi];
        System.arraycopy(mat, 0, trimMat, 0, mi);

        return new DhLodMesh(ox, oz, trimPos, trimIdx, trimUv, trimMat);
    }

    // ---- Helpers ----

    private static Object extractData(Object result) {
        if (result instanceof Object[][][]) return result;
        try { return result.getClass().getMethod("get").invoke(result); } catch (Exception e1) {
        try { return result.getClass().getMethod("getData").invoke(result); } catch (Exception e2) {
        try { var f = result.getClass().getField("value"); return f.get(result); } catch (Exception e3) {}}}
        return null;
    }

    private static net.minecraft.client.Minecraft mc() {
        return net.minecraft.client.Minecraft.getInstance();
    }

    private static java.lang.reflect.Method findMethod(Class<?> cls, String name, int params) {
        for (var m : cls.getMethods())
            if (m.getName().equals(name) && m.getParameterCount() == params) return m;
        return null;
    }

    private static long chunkKey(int cx, int cz) {
        return ((long) cx << 32) | (cz & 0xFFFFFFFFL);
    }

    private static long tileKey(int ox, int oz) {
        return ((long) ox << 32) | (oz & 0xFFFFFFFFL);
    }

    // ---- Data records ----

    /** Raw height sample from a single DH chunk query. */
    record LodSample(int cx, int cz, int surfaceY) {}

    /** Mesh data for one LOD tile — ready for Vulkan buffer upload. */
    public record DhLodMesh(
        int originChunkX,  // chunk coordinate of tile origin
        int originChunkZ,
        float[] positions, // 3 floats per vertex (xyz)
        int[] indices,     // triangle indices
        float[] cornerUv,  // 6 floats per triangle (3 corners × 2 UV coords)
        float[] material   // 12 floats per triangle (normal+emission, tint, materialId, flags, aux0, aux1)
    ) {
        public int vertexCount() { return positions.length / 3; }
        public int triangleCount() { return indices.length / 3; }
    }

    // ---- Vulkan buffer upload ----

    /** Vulkan buffers for one uploaded LOD mesh section. */
    record LodGpuBuffers(
        long tileKey,
        int originChunkX,
        int originChunkZ,
        RtBuffer positions,
        RtBuffer indices,
        RtBuffer uvs,
        RtBuffer material,
        int vertexCount,
        int triangleCount
    ) {
        void destroy() {
            if (positions != null) positions.destroy();
            if (indices != null) indices.destroy();
            if (uvs != null) uvs.destroy();
            if (material != null) material.destroy();
        }
    }

    /**
     * Upload a CPU-side LOD mesh to Vulkan buffers.
     * Creates host-visible buffers and fills them directly.
     * The mesh is ready for BLAS construction once uploaded.
     */
    private LodGpuBuffers uploadMeshToGpu(RtContext ctx, DhLodMesh mesh) {
        if (mesh.vertexCount() == 0) return null;

        int transferDst = VK10.VK_BUFFER_USAGE_TRANSFER_DST_BIT;
        int storage = VK10.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT;
        String label = "dh lod " + mesh.originChunkX() + "," + mesh.originChunkZ();

        long posBytes = (long) mesh.positions().length * Float.BYTES;
        long idxBytes = (long) mesh.indices().length * Integer.BYTES;
        long uvBytes = (long) mesh.cornerUv().length * Float.BYTES;
        long matBytes = (long) mesh.material().length * Float.BYTES;

        try {
            // Create host-visible buffers for positions and indices (will be used for BLAS)
            RtBuffer posBuf = ctx.createBuffer(posBytes, AS_INPUT | transferDst, true, label + " pos");
            RtBuffer idxBuf = ctx.createBuffer(idxBytes, AS_INPUT | transferDst, true, label + " idx");
            // Storage buffers for UVs and material (read by hit shaders)
            RtBuffer uvBuf = ctx.createBuffer(uvBytes, storage, true, label + " uv");
            RtBuffer matBuf = ctx.createBuffer(matBytes, storage, true, label + " mat");

            // Fill buffers via mapped memory
            MemoryUtil.memFloatBuffer(posBuf.mapped, mesh.positions().length).put(mesh.positions());
            MemoryUtil.memIntBuffer(idxBuf.mapped, mesh.indices().length).put(mesh.indices());
            MemoryUtil.memFloatBuffer(uvBuf.mapped, mesh.cornerUv().length).put(mesh.cornerUv());
            MemoryUtil.memFloatBuffer(matBuf.mapped, mesh.material().length).put(mesh.material());

            // Flush (no-op for HOST_COHERENT but safe)
            posBuf.flush();
            idxBuf.flush();
            uvBuf.flush();
            matBuf.flush();

            return new LodGpuBuffers(
                tileKey(mesh.originChunkX(), mesh.originChunkZ()),
                mesh.originChunkX(), mesh.originChunkZ(),
                posBuf, idxBuf, uvBuf, matBuf,
                mesh.vertexCount(), mesh.triangleCount()
            );
        } catch (Exception e) {
            CausticaMod.LOGGER.debug("[DH] GPU upload failed: {}", e.getMessage());
            return null;
        }
    }
}
