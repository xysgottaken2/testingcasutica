package dev.comfyfluffy.caustica.rt;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** Regression guards for cloud/shadow interactions that are easy to re-break in shader-only changes. */
final class RtCloudShaderRegressionTest {
    private static final Path REPO_ROOT = repoRoot();
    private static final Path CLOUDS = REPO_ROOT.resolve("shaders/world/clouds.slang");
    private static final Path WORLD_RGEN = REPO_ROOT.resolve("shaders/world/world.rgen.slang");
    private static final Path WORLD_RMISS = REPO_ROOT.resolve("shaders/world/world.rmiss.slang");

    @Test
    void cloudSunShadowDoesNotReuseVisibleCloudTrace() throws IOException {
        String source = Files.readString(CLOUDS);
        String body = slice(source, "public float cloudSunShadow", "// ---- Classic");

        assertFalse(body.contains("cloudTrace("),
                "sun visibility must not use the visible-cloud query with camera/view fades");
        assertFalse(body.contains("cloudAlpha("),
                "sun visibility must not inherit visible-cloud alpha fades");
        assertTrue(body.contains("float t = deckRel / lightDir.y;"),
                "cloud shadows must intersect the light ray from the receiver");
        assertTrue(body.contains("push.cloudAnchor.xy + pointRel.xz + lightDir.xz * t"),
                "cloud shadows must sample at the receiver/light intersection, not at the camera");
    }

    @Test
    void classicStyleIsAnalyticBoxesAgainstTheAuthoredCellMap() throws IOException {
        String clouds = Files.readString(CLOUDS);
        String classic = slice(clouds, "// ---- Classic", "// ---- Volumetric");

        assertTrue(clouds.contains("cloudCellShown(push, cell)"),
                "the deck shape must come from the authored cell map, not a procedural field");
        assertTrue(classic.contains("cloudTraceBoxes(push, originRel, dir, maxDistance)"),
                "the classic style must be an analytic box intersection");
        assertFalse(classic.contains("cloudMarch("),
                "the classic style must not march a volume — boxes are exact by construction");
        assertTrue(classic.contains("h.face == 0u ? 1.0 : (h.face == 1u ? 0.7"),
                "classic shading must reproduce vanilla's face tone table (top 1.0 / bottom 0.7)");
    }

    @Test
    void volumetricMarchExcludesTheSlabInTheCrossingRegion() throws IOException {
        String clouds = Files.readString(CLOUDS);
        String march = slice(clouds, "public CloudVolume cloudMarch", "// ---- Unified entry point");

        assertInOrder(march,
                "crossFade = smoothstep(halfThickness * 0.5, halfThickness * 1.5, abs(deckRel))",
                "if (crossFade <= 0.0) {",
                "return result;");
        assertTrue(march.contains("result.scatter *= opacity * crossFade;"),
                "the crossing fade must scale the finished in-scatter, not the coverage field");
    }

    @Test
    void cloudColourComesFromTheVanillaPushNotAShaderRamp() throws IOException {
        String clouds = Files.readString(CLOUDS);

        assertTrue(clouds.contains("public float3 cloudTint(WorldPush push)"),
                "cloud tint must be a single accessor over the pushed lane");
        assertTrue(clouds.contains("push.cloudColor.xyz"),
                "the tint must read the vanilla-resolved cloud colour from LevelRenderState");
        assertFalse(clouds.contains("CLOUD_STORM_ALBEDO"),
                "the hand-tuned storm albedo ramp must not return (vanilla's own value replaces it)");
    }

    @Test
    void rainHidesCelestialDiscsEvenWhenTheDeckHasHoles() throws IOException {
        String miss = Files.readString(WORLD_RMISS);

        assertFalse(miss.contains("cloudsEnabled(worldPush) ? 1.0 : 1.0 - rainStrength"),
                "the disc visibility must not depend on the cloud toggle — holes in the deck leak sun");
        assertTrue(miss.contains("discVisible = 1.0 - smoothstep(0.02, 0.65, stormStrength)"),
                "rain must fade the sun/moon discs out aggressively");
    }

    @Test
    void directLightingAppliesCloudShadowOnlyAfterSceneVisibilitySurvives() throws IOException {
        String source = Files.readString(WORLD_RGEN);
        String frontNeeBlock = slice(source, "float cloudShadow = 1.0;", "float activeSss");
        String sssBlock = slice(source, "VisibilityResult shadowBack", "// Preserve all local lighting");

        assertInOrder(frontNeeBlock,
                "float3 vis = shadow.transmittance;",
                "if (max(vis.r, max(vis.g, vis.b)) > 0.0) {",
                "cloudShadow = cloudSunShadow(worldPush, hitPos - worldPush.camOffset, lightDir);");
        assertInOrder(sssBlock,
                "float3 visB = shadowBack.transmittance;",
                "if (max(visB.r, max(visB.g, visB.b)) > 0.0) {",
                "if (!cloudShadowReady) {");
    }

    private static String slice(String source, String startNeedle, String endNeedle) {
        int start = source.indexOf(startNeedle);
        assertTrue(start >= 0, "missing shader snippet start: " + startNeedle);
        int end = source.indexOf(endNeedle, start);
        assertTrue(end > start, "missing shader snippet end: " + endNeedle);
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

    /** Same root discovery pattern as RtShaderConstantMirrorTest, kept local to avoid test coupling. */
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
