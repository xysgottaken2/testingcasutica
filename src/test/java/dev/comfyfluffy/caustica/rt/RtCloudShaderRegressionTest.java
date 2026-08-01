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
    private static final Path RTCOMPOSITE = REPO_ROOT.resolve(
            "src/main/java/dev/comfyfluffy/caustica/rt/RtComposite.java");
    private static final Path RT_ENTITIES = REPO_ROOT.resolve(
            "src/main/java/dev/comfyfluffy/caustica/rt/entity/RtEntities.java");
    private static final Path RT_VANILLA_WEATHER = REPO_ROOT.resolve(
            "src/main/java/dev/comfyfluffy/caustica/rt/RtVanillaWeather.java");

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
    void rainyOvercastIsSolidAndKillsCelestialLeaks() throws IOException {
        String clouds = Files.readString(CLOUDS);
        String miss = Files.readString(WORLD_RMISS);
        String composite = Files.readString(RTCOMPOSITE);

        assertTrue(clouds.contains("CLOUD_SOLID_COVERAGE"),
                "full rain coverage must bypass procedural cloud holes");
        assertTrue(clouds.contains("requestedCoverage >= CLOUD_SOLID_COVERAGE"),
                "both cloud styles must become a closed ceiling at full overcast");
        assertFalse(miss.contains("cloudsEnabled(worldPush) ? 1.0 : 1.0 - rainStrength"),
                "rain must hide the sun/moon disc even when cloud rendering is enabled");
        assertTrue(miss.contains("smoothstep(0.02, 0.65, stormStrength)"),
                "celestial discs must fade out aggressively in real rain");
        assertTrue(composite.contains("float rainLight = 1.0f - 0.96f * rain;"),
                "storm direct light must be nearly gone so cloud pinholes cannot project beams");
        assertTrue(composite.contains("opacity = opacity + (1f - opacity) * overcast;"),
                "rain should push cloud opacity closed along with coverage");
    }

    @Test
    void dielectricPrefixCarriesRainFogBeforeWaterContinuations() throws IOException {
        String source = Files.readString(WORLD_RGEN);
        String prefix = slice(source, "if (seg.bounce > 0)", "// Pass A is fixed");

        assertInOrder(prefix,
                "AmbientFog preFog = evalAmbientFog(worldPush.ambientFog, prefixDist);",
                "L += throughput * preFog.inScatter;",
                "throughput *= preFog.transmittance;",
                "CloudVolume pre = cloudSegment");
    }

    @Test
    void stormCloudShadowDoesNotCreateDeckAltitudeCutLine() throws IOException {
        String source = Files.readString(CLOUDS);
        String body = slice(source, "public float cloudSunShadow", "// ---- Classic");

        assertTrue(body.contains("globalStormAlpha"),
                "storm overcast must have a camera-independent/global attenuation term");
        assertInOrder(body,
                "float globalStormAlpha",
                "if (t <= 0.0) {",
                "return 1.0 - strength * globalStormAlpha;");
        assertTrue(body.contains("alpha = max(alpha, globalStormAlpha);"),
                "analytic cloud shadows must blend with global storm attenuation instead of making a hard deck line");
    }

    @Test
    void rainUsesVanillaWeatherRendererNotProceduralEntityMesh() throws IOException {
        String entities = Files.readString(RT_ENTITIES);
        String weather = Files.readString(RT_VANILLA_WEATHER);

        assertFalse(entities.contains("RAIN_STREAK"),
                "falling rain must not be a duplicated procedural entity mesh");
        assertFalse(entities.contains("appendProceduralRainStreaks"),
                "RtEntities should only capture real ParticleEngine particles, not fake rain columns");
        assertTrue(weather.contains("weatherRenderState"),
                "vanilla extracted WeatherRenderState must drive falling rain/snow");
        assertTrue(weather.contains("WeatherEffectRenderer.render"),
                "falling rain/snow should be replayed through vanilla's renderer");
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
