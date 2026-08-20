package dev.comfyfluffy.caustica.rt;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** Regression guard for the targeted-block outline's full-screen corruption failure mode. */
final class RtBlockOutlineRegressionTest {
    private static final Path SOURCE = repoRoot().resolve(
            "src/main/java/dev/comfyfluffy/caustica/rt/overlay/RtBlockOutlineFeature.java");

    @Test
    void outlineDrawsDirectlyWithoutAFullscreenResolvedMaskReadback() throws IOException {
        String source = Files.readString(SOURCE);
        String resourceSetup = slice(source,
                "private void ensureResources", "@Override\n    public void record");
        assertTrue(resourceSetup.contains(".blend(RtOverlayPipelines.Blend.ALPHA)"),
                "the straight-alpha outline must blend directly over the shared overlay");
        assertFalse(resourceSetup.contains("overlay_fullscreen_triangle"));
        assertFalse(resourceSetup.contains("overlay_passthrough_composite"));

        String record = slice(source, "public void record", "@Override\n    public void destroy");
        assertInOrder(record,
                "RtWorldOverlay.beginColorRendering(cmd, stack, targetView",
                "VK10.vkCmdBindPipeline",
                "VK10.vkCmdDraw(cmd, vertexCount",
                "RtWorldOverlay.endRendering(cmd)");
        assertFalse(record.contains("beginMsaaColorRendering"),
                "the ray-query outline must not expose an MSAA resolve image through a fullscreen pass");
        assertFalse(source.contains("resolvedMask"));
    }

    private static String slice(String source, String startNeedle, String endNeedle) {
        int start = source.indexOf(startNeedle);
        assertTrue(start >= 0, "missing source snippet start: " + startNeedle);
        int end = source.indexOf(endNeedle, start);
        assertTrue(end > start, "missing source snippet end: " + endNeedle);
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
            if (Files.isDirectory(candidate.resolve("shaders/overlay"))
                    && Files.isDirectory(candidate.resolve("src/main/java"))) {
                return candidate;
            }
        }
        throw new IllegalStateException("could not locate the repository root from " + dir);
    }
}
