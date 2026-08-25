package dev.comfyfluffy.caustica.rt;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Regression guards for SHaRC's cross-pass correctness contract.
 *
 * <p>A radiance cache can compile and still be completely inert: the old implementation refreshed the
 * same timestamp that its warm-up test interpreted as age, so nearby entries could never become old
 * enough to query. It also read and rewrote one float struct from many raygen invocations, making the
 * occasional far-field hit depend on GPU scheduling. These tests pin the architectural fixes rather
 * than any one tuning preset.
 */
final class RtSharcShaderRegressionTest {
    private static final Path ROOT = repoRoot();
    private static final Path SHARC = ROOT.resolve("shaders/world/sharc.slang");
    private static final Path RESOLVE = ROOT.resolve("shaders/world/sharc_resolve.comp.slang");
    private static final Path RAYGEN = ROOT.resolve("shaders/world/world.rgen.slang");
    private static final Path COMMON = ROOT.resolve("shaders/world/world_common.slang");
    private static final Path HOST = ROOT.resolve("src/main/java/dev/comfyfluffy/caustica/rt/RtSharc.java");
    private static final Path COMPOSITE =
            ROOT.resolve("src/main/java/dev/comfyfluffy/caustica/rt/RtComposite.java");
    private static final Path CONFIG =
            ROOT.resolve("src/main/java/dev/comfyfluffy/caustica/CausticaConfig.java");
    private static final Path VIDEO_OPTIONS =
            ROOT.resolve("src/main/java/dev/comfyfluffy/caustica/client/RtVideoOptions.java");
    private static final Path PIPELINE = ROOT.resolve(
            "src/main/java/dev/comfyfluffy/caustica/rt/pipeline/RtSharcResolvePipeline.java");

    @Test
    void cacheKeysAreWorldStableAcrossCameraMotionAndTerrainRebases() throws IOException {
        String sharc = Files.readString(SHARC);
        String raygen = Files.readString(RAYGEN);
        String composite = Files.readString(COMPOSITE);

        assertTrue(sharc.contains("sharcCellAxis(rebasedPosition.x, push.sharcGridOrigin.x, cellSize)"),
                "the key must combine the small hit coordinate with the integer world origin");
        assertTrue(composite.contains("new Int4(terrain.blockX, terrain.blockY, terrain.blockZ,"),
                "the host must publish the terrain rebase origin, not three reserved zeroes");
        assertTrue(raygen.contains("sharcQuery(worldPush, hitPos, n, cachedRadiance)"),
                "hitPos is already terrain-rebased; subtracting the camera makes the cache swim");
        assertFalse(raygen.contains("float3 sharcPos = hitPos - worldPush.camOffset"),
                "camera-relative SHaRC keys recreate the reported motion flicker");
    }

    @Test
    void farRangeFadesBackToTracingInsteadOfPopping() throws IOException {
        String sharc = Files.readString(SHARC);
        String raygen = Files.readString(RAYGEN);

        assertTrue(sharc.contains("smoothstep(maxDistance * 0.8, maxDistance, distanceToCamera)"),
                "the query-distance boundary needs a transition band, not a hard moving ring");
        assertTrue(raygen.contains("* sharcRangeWeight(worldPush, hitPos);"),
                "range confidence must become traced residual rather than darkening cached radiance");
    }

    @Test
    void updateResolveAndQueryTouchDifferentLanes() throws IOException {
        String sharc = Files.readString(SHARC);
        String resolve = Files.readString(RESOLVE);
        String raygen = Files.readString(RAYGEN);
        String composite = Files.readString(COMPOSITE);

        assertTrue(sharc.contains("public uint4  accumulation;")
                        && sharc.contains("public float4 resolved;"),
                "atomic frame sums and query history must be separate storage lanes");
        assertTrue(sharc.contains("InterlockedAdd(cache[cacheIndex].accumulation.x")
                        && sharc.contains("InterlockedCompareExchange(cache[cacheIndex].accumulation.w"),
                "raygen updates need atomic RGB sums and an atomic complete-sample reservation");
        assertTrue(resolve.contains("sharcResolveEntry(push, dispatchId.x);"),
                "a post-trace compute dispatch must own temporal history updates");
        assertTrue(raygen.contains("tracePath(segment, dispatchIndex, 0x9e37u + leaf, true,")
                        && raygen.contains("s + leaf * spp, false,"),
                "training paths and displayed paths must run as distinct raygen modes");
        assertInOrder(composite,
                "withTraceMode(frameConstants, SHARC_UPDATE_PASS, 0).write(sharcUpdateConstants);",
                "active.trace(cmd, renderW, renderH, sharcUpdateConstants, 1);",
                "VulkanCommandEncoder.memoryBarrier(cmd, stack); // atomic updates -> SHaRC resolve",
                "sharc.resolve(cmd, pushBuf.deviceAddress);",
                "VulkanCommandEncoder.memoryBarrier(cmd, stack); // resolved history -> displayed trace",
                "active.trace(cmd, renderW, renderH, pushConstants, 1);",
                "VulkanCommandEncoder.memoryBarrier(cmd, stack); // RT writes -> temporal/upscale reads");
    }

    @Test
    void warmupCountsSampledFramesInsteadOfAgeSinceLastWrite() throws IOException {
        String sharc = Files.readString(SHARC);
        String query = slice(sharc, "public bool sharcQuery(", "\n}\n");
        String resolve = slice(sharc, "public void sharcResolveEntry(", "\n}\n");

        assertTrue(query.contains("entry.metadata.y < requiredFrames"),
                "query warm-up must use the number of frames that actually contributed samples");
        assertFalse(query.contains("push.frameIndex -"),
                "last-update age resets on every visible frame and therefore never warms nearby cells");
        assertTrue(resolve.contains("metadata.y = min(sampledFrames + 1u, 65535u)"),
                "resolve must advance confidence after a non-empty accumulation");
        assertTrue(resolve.contains("sampledFrames < warmupFrames")
                        && resolve.contains("rcp(float(sampledFrames + 1u))"),
                "warm-up frames must form a running mean instead of preserving a noisy first writer");
        assertTrue(resolve.indexOf("if (sampleCount == 0u)")
                        < resolve.indexOf("metadata.y = min(sampledFrames + 1u, 65535u)"),
                "frames with no update may become stale, but may not fake another warm-up sample");
    }

    @Test
    void collisionsProbeAndStaleEntriesAreActuallyRecycled() throws IOException {
        String sharc = Files.readString(SHARC);
        String insert = slice(sharc, "public bool sharcFindOrInsert(", "\n}\n");
        String resolve = slice(sharc, "public void sharcResolveEntry(", "\n}\n");

        assertTrue(insert.contains("probe < SHARC_PROBE_COUNT"),
                "one direct-mapped slot gives normal world geometry an unusably high collision rate");
        assertTrue(insert.contains("InterlockedCompareExchange(cache[emptyIndex].metadata.x"),
                "two paths must not claim the same empty probe slot");
        assertTrue(resolve.contains("if (staleFrames >= lifetime)"),
                "an entry with no recent samples must eventually release its slot");
        assertTrue(resolve.contains("cache[entryIndex] = empty;"),
                "recycling must clear key, accumulator, history and state together");
    }

    @Test
    void cacheStoresOutgoingRadianceWithoutDoubleApplyingTheMaterial() throws IOException {
        String raygen = Files.readString(RAYGEN);
        int query = raygen.indexOf("sharcQuery(worldPush, hitPos, n, cachedRadiance)");
        int localLighting = raygen.indexOf("// Emissive surfaces", query);

        assertTrue(query >= 0 && localLighting > query,
                "complete outgoing radiance must be queried before this surface adds direct lighting");
        assertFalse(raygen.contains("diffAlb * INV_PI * cachedRadiance"),
                "the cached value is already outgoing radiance; another BRDF darkens it twice");
        assertTrue(raygen.contains("throughput *= 1.0 - cacheWeight;"),
                "a partial-strength hit must trace the residual instead of dropping that path energy");
        assertTrue(raygen.contains("sharcPathRecordSurface(worldPush, sharcPath, hitPos, n, localLight)"),
                "sparse full paths must continue supplying cache samples at opaque surfaces");
    }

    @Test
    void cacheHitDebugViewMakesTheIntegrationMeasurable() throws IOException {
        String raygen = Files.readString(RAYGEN);
        String options = Files.readString(VIDEO_OPTIONS);

        assertTrue(raygen.contains("SHARC_QUERY_DEBUG_VIEW = 13u")
                        && raygen.contains("gv_sharcQueryHit")
                        && raygen.contains("gv_sharcQueryAttempted"),
                "debug view 13 must distinguish cache hits, misses and ineligible paths");
        assertTrue(options.contains("List.of(0, 1, 2, 3, 4, 5, 6, 7, 10, 11, 12, 13)"),
                "the SHaRC cache-hit mask must be selectable from video settings");
    }

    @Test
    void legacyInertDefaultsMigrateToSparseFirstIndirectQueries() throws IOException {
        String config = Files.readString(CONFIG);

        assertTrue(config.contains("sharc.start-bounce\", 1, 1, 6"),
                "new installs must query at the first indirect hit, not the low-energy second tail");
        assertTrue(config.contains("migrateLegacySharcDefaults()")
                        && config.contains("Rt.Sharc.START_BOUNCE.set(1)")
                        && config.contains("Rt.Sharc.UPDATE_COVERAGE.set(0.05f)"),
                "the exact old 50%-update/bounce-2 tuple must be migrated for existing users");
    }

    @Test
    void hostAndShaderAgreeOnRecordAndResolvePipelineShape() throws IOException {
        String host = Files.readString(HOST);
        String shader = Files.readString(SHARC);
        String pipeline = Files.readString(PIPELINE);
        String common = Files.readString(COMMON);

        assertTrue(host.contains("public static final int ENTRY_BYTES = 64;"),
                "host allocation stride must match four 16-byte shader lanes");
        assertTrue(shader.contains("public struct SharcEntry")
                        && shader.contains("public uint4  key;")
                        && shader.contains("public uint4  metadata;"),
                "the shader record must remain four std430-aligned vectors");
        assertTrue(pipeline.contains("/caustica/rt/sharc_resolve.comp.spv")
                        && pipeline.contains("private static final int PUSH_BYTES = Long.BYTES;"),
                "the resolve pipeline takes only the WorldPush device address");
        assertTrue(common.contains("sharcGridOrigin: xyz = integer terrain rebase origin"),
                "the generated WorldPush ABI documentation must describe its now-load-bearing xyz lanes");
    }

    private static String slice(String source, String startNeedle, String endNeedle) {
        int start = source.indexOf(startNeedle);
        assertTrue(start >= 0, "missing snippet start: " + startNeedle);
        int end = source.indexOf(endNeedle, start);
        assertTrue(end > start, "missing snippet end: " + endNeedle);
        return source.substring(start, end);
    }

    private static void assertInOrder(String source, String... needles) {
        int at = -1;
        for (String needle : needles) {
            int next = source.indexOf(needle, at + 1);
            assertTrue(next > at, "expected snippet after index " + at + ": " + needle);
            at = next;
        }
    }

    private static Path repoRoot() {
        Path dir = Path.of("").toAbsolutePath();
        for (Path candidate = dir; candidate != null; candidate = candidate.getParent()) {
            if (Files.isDirectory(candidate.resolve("shaders/world"))
                    && Files.isDirectory(candidate.resolve("src/main/java"))) {
                return candidate;
            }
        }
        throw new IllegalStateException("could not locate repository root from " + dir);
    }
}
