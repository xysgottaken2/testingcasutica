package dev.comfyfluffy.caustica.rt;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** Regression guards for selective cave fog and one-time screen-space composition. */
final class RtFogShaderRegressionTest {
    private static final Path REPO_ROOT = repoRoot();
    private static final Path CORE = REPO_ROOT.resolve("shaders/world/world_core.slang");
    private static final Path GUIDES = REPO_ROOT.resolve("shaders/world/guides.slang");
    private static final Path PRIMARY = REPO_ROOT.resolve("shaders/world/world_primary.rgen.slang");
    private static final Path WORLD = REPO_ROOT.resolve("shaders/world/world.rgen.slang");
    private static final Path MISS = REPO_ROOT.resolve("shaders/world/world.rmiss.slang");
    private static final Path JAVA =
            REPO_ROOT.resolve("src/main/java/dev/comfyfluffy/caustica/rt/RtComposite.java");

    @Test
    void primaryPassWritesDepthAndSkyVisibilityIntoFogMaskTexture() throws IOException {
        String core = Files.readString(CORE);
        String guides = Files.readString(GUIDES);
        String primary = Files.readString(PRIMARY);

        assertTrue(core.contains("RWTexture2D<float>  gFogDepthMask"),
                "fog needs a dedicated per-pixel mask texture");
        String maskFunction = slice(guides, "public float maskedFogDepth", "// Static surfaces");
        assertTrue(maskFunction.contains("visibility("),
                "the selective mask must test sky exposure instead of applying uniform fog");
        assertTrue(maskFunction.contains("cameraSubmerged()"),
                "atmospheric fog must not stack on the underwater medium");
        assertInOrder(maskFunction,
                "float depth = max(hitDepth, 0.0);",
                "if (worldPush.dimension != DIMENSION_OVERWORLD)",
                "return depth;",
                "VisibilityResult sky = visibility");
        assertTrue(guides.contains("gFogDepthMask[pix] = gv_fogDepth;"),
                "Pass A must materialize the selective depth mask for Pass B");
        assertInOrder(primary,
                "float3 hitPos = ro + rd * payload.hitT;",
                "gv_fogDepth = maskedFogDepth(hitPos, payload.hitT);",
                "uint material = payloadMaterial();");
    }

    @Test
    void netherAndEndRetainTheirAuthoredDistanceHaze() throws IOException {
        String java = Files.readString(JAVA);

        assertTrue(java.contains(
                        "case DIMENSION_NETHER -> new Float4(0.052f, 0.0125f, 0.0065f, 0.012f);"),
                "the Nether's original warm fog colour and density must not be cleared with cave fog");
        assertTrue(java.contains(
                        "case DIMENSION_END -> new Float4(0.010f, 0.0055f, 0.016f, 0.0016f);"),
                "the End's original violet fog colour and density must not be cleared with cave fog");
    }

    @Test
    void fogIsCompositedOnceAfterStochasticPathAggregation() throws IOException {
        String world = Files.readString(WORLD);

        assertEquals(1, occurrences(world, "evalAmbientFog(worldPush.ambientFog"),
                "fog must not return to dielectric prefixes or per-bounce path segments");
        assertFalse(world.contains("AmbientFog preFog"),
                "split water/glass prefixes must not independently add emissive fog");
        assertFalse(world.contains("AmbientFog segFog"),
                "secondary path segments must not independently add emissive fog");
        assertInOrder(world,
                "float3 radiance = frameRadiance / float(spp);",
                "bool screenFogActive = fogEnabled() && !fogVolumetricEnabled(worldPush);",
                "float fogDepth = screenFogActive ? max(gFogDepthMask[pix], 0.0) : 0.0;",
                "AmbientFog screenFog = evalAmbientFog(worldPush.ambientFog, fogDepth);",
                "radiance = radiance * screenFog.transmittance + screenFog.inScatter;");
        assertTrue(world.contains("diffRad = diffRad * screenFog.transmittance + screenFog.inScatter;")
                        && world.contains("specRad *= screenFog.transmittance;"),
                "optional per-lobe denoiser signals must still sum to the fogged combined image");
    }

    @Test
    void volumetricFogGatesOffScreenSpaceComposite() throws IOException {
        String world = Files.readString(WORLD);
        String fog = Files.readString(REPO_ROOT.resolve("shaders/world/fog.slang"));

        // The path-integrated volumetric facility is a separate medium from the selective screen-space
        // fog. When it is active the screen-space composite must be disabled, so the two never double-count.
        assertTrue(world.contains("fogEnabled() && !fogVolumetricEnabled(worldPush)"),
                "the screen-space fog must be gated off when volumetric fog is active");
        // fogSegment is integrated along path segments (prefix + per-hit), the point of a real medium.
        assertTrue(world.contains("FogVolume preFog = fogSegment("),
                "the dielectric camera->interface prefix must carry volumetric fog");
        assertTrue(world.contains("FogVolume segFog = fogSegment("),
                "per-hit path segments must carry volumetric fog");
        assertTrue(fog.contains("public FogVolume fogSegment(") && fog.contains("public bool fogVolumetricEnabled("),
                "fog.slang must expose the volumetric fog segment and gate");
    }

    @Test
    void fogToggleCannotFlattenDimensionSkyboxes() throws IOException {
        String miss = Files.readString(MISS);

        String dimensionMiss = slice(miss,
                "if (worldPush.dimension != DIMENSION_OVERWORLD)", "float day = worldPush.sunDir.w;");
        assertFalse(dimensionMiss.contains("ambientFog"),
                "the fog parameters/toggle must not recolor Nether or End far-field skyboxes");
        assertTrue(dimensionMiss.contains("netherSky(dir)") && dimensionMiss.contains("endSky(dir)"));
    }

    private static int occurrences(String source, String needle) {
        int count = 0;
        int at = 0;
        while ((at = source.indexOf(needle, at)) >= 0) {
            count++;
            at += needle.length();
        }
        return count;
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
