package dev.comfyfluffy.caustica.rt;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Guards the world-edit responsiveness contract: temporal stages must react to world content
 * changes that motion vectors cannot express.
 *
 * <p>The reprojection machinery behind SVGF (and DLSS-RR's internal history) invalidates history
 * through motion vectors and geometry gates. That covers CAMERA movement — but a block placed or
 * broken while standing still changes the world under zero-length MVs, and every surface whose own
 * depth/normal did not change (the edit's indirect-light footprint, which dominates in the dark
 * interiors players build in) keeps a history that no longer matches the world. The edit then blends
 * in over the full accumulation window: the "placed block fades in slowly until you walk" lag, and
 * walking appeared to fix it only because disocclusion was doing the invalidation instead.
 *
 * <p>The fix spans three files, and each join is pinned here because a drift compiles cleanly and
 * only shows up as the lag coming back:
 * <ol>
 *   <li>{@code RtTerrain.markBlocksDirty} (and the edit-publish paths, plus full clears) bump a
 *       monotonic {@code worldEditCounter};</li>
 *   <li>{@code RtComposite.recordFrame} watches the serial and opens a timed response window
 *       ({@code WORLD_EDIT_RESPONSE_NANOS}) — during which SVGF's accumulation cap drops
 *       ({@code SVGF_EDIT_RESPONSE_MAX_FRAMES}) and SHaRC's temporal blend shortens — and hands
 *       DLSS-RR a rate-limited history reset;</li>
 *   <li>the SVGF reprojection keeps its existing push-constant contract; only the value the host
 *       passes changes, so no shader ABI is touched.</li>
 * </ol>
 */
final class RtWorldEditResponsivenessTest {
    private static final Path REPO_ROOT = repoRoot();
    private static final Path RT_TERRAIN =
            REPO_ROOT.resolve("src/main/java/dev/comfyfluffy/caustica/rt/terrain/RtTerrain.java");
    private static final Path RT_COMPOSITE =
            REPO_ROOT.resolve("src/main/java/dev/comfyfluffy/caustica/rt/RtComposite.java");
    private static final Path RT_DLSS_RR =
            REPO_ROOT.resolve("src/main/java/dev/comfyfluffy/caustica/rt/pipeline/RtDlssRr.java");

    /**
     * The edit signal must originate at vanilla's block-dirty entry points (any thread) and again
     * when the rebuilt geometry actually publishes — the async re-extract lands frames after the
     * edit, so a signal taken at edit time alone can expire before the change is even visible.
     */
    @Test
    void terrainPulsesWorldEditsAtObservationAndAtPublication() throws IOException {
        String terrain = Files.readString(RT_TERRAIN);

        assertTrue(terrain.contains("private final AtomicLong worldEditCounter"),
                "RtTerrain must carry the monotonic world-edit serial");
        assertTrue(terrain.contains("public static long worldEditCounter()"),
                "the serial must be readable by the render loop without taking the dirty lock");

        String markBlocksDirty = methodBody(terrain, "public static void markBlocksDirty(");
        assertTrue(markBlocksDirty.contains("terrain.worldEditCounter.incrementAndGet();"),
                "markBlocksDirty must bump the serial when the edit arrives (thread-safe under dirtyLock)");
        assertTrue(markBlocksDirty.contains("WorldEditBounds.unionOf(priorBounds,"),
                "markBlocksDirty must also union the edit's bounds for the visibility gate");

        int publishBumps = occurrences(terrain, "worldEditCounter.incrementAndGet();") - 1; // minus the markBlocksDirty bump
        assertTrue(publishBumps >= 3,
                "the publish paths must also bump: in-place section swap (applyBuildChanges), edit-emptied"
                        + " sections (drainCompletedBuilds, group and non-group), and full clears");
        assertTrue(occurrences(terrain, "INSTANCE.worldEditCounter.incrementAndGet();") >= 1,
                "a full clear (dimension switch / F3+A) is a wholesale world change and must pulse too");
    }

    /**
     * SVGF must shorten its accumulation window — not reset — while the response window is open.
     * A reset would flash the whole screen per placement; the shorter exponential window converges
     * the edit within a handful of frames using the same trade the image already accepts in motion.
     */
    @Test
    void svgfShortensItsAccumulationWindowRatherThanResettingDuringWorldEdits() throws IOException {
        String composite = Files.readString(RT_COMPOSITE);

        assertTrue(composite.contains("private static final float SVGF_EDIT_RESPONSE_MAX_FRAMES"),
                "the responsive accumulation cap must exist");
        assertTrue(composite.contains("private static final long WORLD_EDIT_RESPONSE_NANOS"),
                "the response window duration must exist");

        String recordFrame = methodBody(composite, "private void recordFrame(");
        assertTrue(recordFrame.contains("boolean worldEditPulse = worldEditSerial != seenWorldEditCounter;"),
                "recordFrame must detect world-edit pulses from the terrain serial");
        assertTrue(recordFrame.contains("boolean worldEditResponse = System.nanoTime() < worldEditResponseUntilNanos;"),
                "recordFrame must derive the timed response window");

        assertTrue(recordFrame.contains("float svgfMaxFrames = worldEditResponse"),
                "the SVGF window cap must depend on the response window");
        assertTrue(recordFrame.contains("svgfReset, svgfMaxFrames, svgfCamForwardDelta);"),
                "the reproject dispatch must pass the responsive cap (push-constant contract is unchanged)");
        assertTrue(composite.contains("boolean svgfReset = !svgfHasHistory;"),
                "the reset gate itself must stay untouched: only genuine history loss may reset");
    }

    /**
     * DLSS-RR owns its history internally, so the only lever is the reset flag — and it must be
     * visibility-gated and rate-limited: off-screen machinery (a piston farm in loaded chunks
     * pulses the serial continuously) must never reset it, and an edit's predict/publish pulse pair
     * and sustained building must coalesce instead of hammering the reconstruction per placement.
     */
    @Test
    void dlssRrHistoryResetsAreVisibilityGatedAndRateLimited() throws IOException {
        String rr = Files.readString(RT_DLSS_RR);
        String composite = Files.readString(RT_COMPOSITE);

        assertTrue(rr.contains("public void requestReset()"),
                "RtDlssRr must expose a history-reset request");

        String recordFrame = methodBody(composite, "private void recordFrame(");
        assertTrue(recordFrame.contains("RtDlssRr.INSTANCE.requestReset();"),
                "recordFrame must request the reset on a visible world-edit pulse while RR owns the denoise slot");
        assertTrue(composite.contains("private static final long RR_EDIT_RESET_MIN_INTERVAL_NANOS"),
                "the reset must be rate-limited");
        assertTrue(recordFrame.contains("rrResetNow - lastRrEditResetNanos >= RR_EDIT_RESET_MIN_INTERVAL_NANOS"),
                "the rate limit must actually gate the request");
    }

    /**
     * The response must be gated on the edit possibly being on screen. An off-screen edit costs the
     * player nothing visually (it is not in view, and turning to look re-invalidates history through
     * ordinary disocclusion), so pulsing the temporal stages for it would only subtract image
     * quality — continuously, for machinery like farms. The gate must stay conservative: unknown
     * bounds and doubt resolve to "visible" so the responsiveness itself can never go missing.
     */
    @Test
    void offScreenEditsDoNotOpenTheResponseWindow() throws IOException {
        String terrain = Files.readString(RT_TERRAIN);
        String composite = Files.readString(RT_COMPOSITE);

        assertTrue(terrain.contains("public record WorldEditBounds("),
                "RtTerrain must publish the recent-edit union AABB");
        assertTrue(terrain.contains("public static WorldEditBounds recentEditBounds()"),
                "the renderer must be able to read the union AABB");

        assertTrue(composite.contains("private boolean editMightBeVisible(RtTerrain terrain)"),
                "RtComposite must own the visibility decision (it has the camera)");
        assertTrue(composite.contains("private static final int WORLD_EDIT_VISIBILITY_PAD_BLOCKS"),
                "the AABB must be padded so light spilling in from past a screen edge counts as visible");
        assertTrue(composite.contains("return true; // provenance unknown: assume the player can see it"),
                "unknown bounds must degrade to visible — the gate may never suppress responsiveness");

        String recordFrame = methodBody(composite, "private void recordFrame(");
        assertTrue(recordFrame.contains("worldEditPulseVisible = editMightBeVisible(terrain);"),
                "each pulse must be visibility-tested");
        assertTrue(recordFrame.contains("if (worldEditPulseVisible) {"),
                "the response window must open only for visible pulses");
    }

    /**
     * SHaRC must re-warm quickly during the window, or the cache keeps feeding pre-edit radiance
     * into the exact frames trying to show the change. The knob is the inverse accumulation window
     * in frames, so responsiveness means taking the MAXIMUM of configured and responsive blend.
     */
    @Test
    void sharcBlendsFasterDuringWorldEdits() throws IOException {
        String composite = Files.readString(RT_COMPOSITE);

        assertTrue(composite.contains("private static Float4 sharcParams(boolean worldEditResponse)"),
                "the SHaRC parameter lane must know about the response window");
        assertTrue(composite.contains("temporalBlend = Math.max(temporalBlend, SHARC_EDIT_RESPONSE_BLEND);"),
                "the responsive blend must shorten the effective window (larger knob = shorter window)");
        String recordFrame = methodBody(composite, "private void recordFrame(");
        assertTrue(recordFrame.contains("sharcParams(worldEditResponse),"),
                "the WorldPush must receive the responsive blend while the window is open");
    }

    // ---- helpers -----------------------------------------------------------------------------

    /** Extracts a method body (plus its signature line) as flat text for containment checks. */
    private static String methodBody(String source, String signature) {
        int start = source.indexOf(signature);
        assertTrue(start >= 0, "signature not found: " + signature);
        int depth = 0;
        int end = start;
        boolean opened = false;
        for (int i = start; i < source.length(); i++) {
            char c = source.charAt(i);
            if (c == '{') {
                depth++;
                opened = true;
            } else if (c == '}') {
                depth--;
                if (opened && depth == 0) {
                    end = i + 1;
                    break;
                }
            }
        }
        assertTrue(end > start, "could not isolate method body for: " + signature);
        return source.substring(start, end);
    }

    private static int occurrences(String haystack, String needle) {
        int count = 0;
        for (int i = haystack.indexOf(needle); i >= 0; i = haystack.indexOf(needle, i + needle.length())) {
            count++;
        }
        return count;
    }

    private static Path repoRoot() {
        Path dir = Path.of("").toAbsolutePath();
        for (Path candidate = dir; candidate != null; candidate = candidate.getParent()) {
            if (Files.isDirectory(candidate.resolve("shaders/world"))
                    && Files.isDirectory(candidate.resolve("src/main/java"))) {
                return candidate;
            }
        }
        throw new IllegalStateException("could not locate the repository root from " + dir);
    }
}
