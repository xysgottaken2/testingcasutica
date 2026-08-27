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
    private static final Path MEDIUM = REPO_ROOT.resolve("shaders/world/medium.slang");
    private static final Path JAVA =
            REPO_ROOT.resolve("src/main/java/dev/comfyfluffy/caustica/rt/RtComposite.java");
    private static final Path CONFIG =
            REPO_ROOT.resolve("src/main/java/dev/comfyfluffy/caustica/CausticaConfig.java");
    private static final Path OPTIONS =
            REPO_ROOT.resolve("src/main/java/dev/comfyfluffy/caustica/client/RtVideoOptions.java");

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

        // The COLOURS stay authored. Only the density moved from a hand-picked per-block constant to
        // one solved from the render distance (RtComposite.dimensionFog): a fixed sigma cannot survive a
        // view-distance change, and the Nether's old 0.012 left just 10% of the radiance at 192 blocks —
        // an opaque wall standing well inside the chunk-load edge it exists to hide.
        assertTrue(java.contains("case DIMENSION_NETHER -> dimensionFog(0.052f, 0.0125f, 0.0065f, "
                        + "NETHER_FOG_HORIZON_TRANSMITTANCE);"),
                "the Nether's original warm fog colour must not be cleared with cave fog");
        assertTrue(java.contains("case DIMENSION_END -> dimensionFog(0.010f, 0.0055f, 0.016f, "
                        + "END_FOG_HORIZON_TRANSMITTANCE);"),
                "the End's original violet fog colour must not be cleared with cave fog");
        assertTrue(java.contains("default -> overworldFog(weather, dayFactor, lightRadiance);"),
                "the Overworld haze must not be hard-zeroed again");

        // Neither dimension has a sun or a moon, so skyPush zeroes lightRadiance there; routing them
        // through the light-relative cap would erase their haze outright.
        String dimensionFog =
                slice(java, "private static Float4 dimensionFog(", "private static Float4 overworldFog(");
        assertFalse(dimensionFog.contains("luminance("),
                "the authored Nether/End haze must not be scaled by a light it does not have");
    }

    @Test
    void overworldHazeInScatterIsCappedAgainstTheFrameLight() throws IOException {
        String java = Files.readString(JAVA);

        // The night-grey regression this guards. The three fog colours are ABSOLUTE radiance, and the
        // night entry was only ~11x darker than the day one while moonlight is ~200x dimmer than
        // sunlight — so after dusk the in-scatter ran 30-200x stronger relative to the light than by
        // day, and being near-neutral it desaturated distant blocks to grey. The cap is the fix.
        assertTrue(java.contains(
                        "float light = Math.min(1.0f, luminance(lightRadiance) / FOG_MIN_LIGHT_FOR_FULL_HAZE);"),
                "the Overworld in-scatter must be capped against the frame's own light level");
        assertTrue(java.contains(
                        "return new Float4(clear[0] * light, clear[1] * light, clear[2] * light, density);"),
                "the cap must scale the in-scatter while leaving the extinction untouched");
        assertTrue(java.contains("private static final float FOG_MIN_LIGHT_FOR_FULL_HAZE"),
                "the cap threshold must be a named constant, not an inline literal");
    }

    @Test
    void hazeInScatterIsShapedByTheLightDirection() throws IOException {
        String medium = Files.readString(MEDIUM);

        // The one thing cloudMarch had that the haze lacked: each sample is SHADED. For a homogeneous
        // medium the angular response is constant along the ray, so it factors out of the integral and
        // is evaluated once per pixel rather than marched.
        String shape = slice(medium, "public float3 hazeScatterShape(", "public AmbientFog evalAmbientFog(");
        assertTrue(shape.contains("* (4.0 * PI)"),
                "the phase must be mean-1 over the sphere, so shaping redistributes brightness and never adds it");
        assertTrue(shape.contains("if (sunStrength <= 0.0) {") && shape.contains("return flat;"),
                "a dimension with no directional light must keep its authored flat haze bit-for-bit");
        assertTrue(shape.contains("max(1.0 + amount * (phase - 1.0), HAZE_MIN_SHAPE)"),
                "the shape must stay positive so it cannot punch a hole in the distance");

        String eval = slice(medium, "public AmbientFog evalAmbientFog(", "// ---- Participating medium");
        assertTrue(eval.contains("result.inScatter = ambientFog.xyz * scatterShape * (1.0 - t);"),
                "the shape must multiply the authored in-scatter, not replace it");
    }

    @Test
    void fogThicknessIsPlayerControllableAndLive() throws IOException {
        String config = Files.readString(CONFIG);
        String options = Files.readString(OPTIONS);
        String java = Files.readString(JAVA);

        assertTrue(config.contains("clampedFloat(\"caustica.rt.fogStrength\", \"composite.fog-strength\""),
                "the haze thickness must be a persisted, clamped runtime setting");
        assertTrue(options.contains("caustica.options.rt.fogStrength"),
                "the slider must be exposed in the RT video options");
        assertTrue(java.contains("float strength = Math.clamp("
                                + "CausticaConfig.Rt.Composite.FOG_HORIZON_STRENGTH.value(), 0.0f, 0.9f);")
                        && java.contains("return 1.0f - strength;"),
                "the slider is authored as a strength; the haze math needs the surviving transmittance");
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
                "float fogDepth = fogEnabled() ? max(gFogDepthMask[pix], 0.0) : 0.0;",
                "AmbientFog screenFog = evalAmbientFog(worldPush.ambientFog, fogDepth,",
                "hazeScatterShape(worldPush, primaryRayDir(fogNdc)));",
                "radiance = radiance * screenFog.transmittance + screenFog.inScatter;");
        assertTrue(world.contains("diffRad = diffRad * screenFog.transmittance + screenFog.inScatter;")
                        && world.contains("specRad *= screenFog.transmittance;"),
                "optional per-lobe denoiser signals must still sum to the fogged combined image");
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
