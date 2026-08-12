package dev.comfyfluffy.caustica.rt;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** Regression guards for stable all-face water guides and water-volume misses. */
final class RtWaterShaderRegressionTest {
    private static final Path REPO_ROOT = repoRoot();
    private static final Path WATER = REPO_ROOT.resolve("shaders/world/water.slang");
    private static final Path PRIMARY = REPO_ROOT.resolve("shaders/world/world_primary.rgen.slang");
    private static final Path WORLD = REPO_ROOT.resolve("shaders/world/world.rgen.slang");
    private static final Path GUIDES = REPO_ROOT.resolve("shaders/world/guides.slang");

    @Test
    void unresolvedInWaterPathCannotRevealTheFarFieldSky() throws IOException {
        String world = Files.readString(WORLD);
        String missHandler = slice(world,
                "if (payload.hitT < 0.0)",
                "// Beer–Lambert: attenuate along the segment");

        assertInOrder(missHandler,
                "if (medium.current.water)",
                "break;",
                "float3 sky = payload.albedo;",
                "L += throughput * sky;");
    }

    @Test
    void unresolvedInWaterGuideKeepsForegroundInsteadOfPublishingSky() throws IOException {
        String guides = Files.readString(GUIDES);
        String missHandler = slice(guides,
                "if (payload.hitT <= 0.0)",
                "uint material = payloadMaterial();");

        assertInOrder(missHandler,
                "if (medium.current.water)",
                "return;",
                "setTransmissionGuide",
                "guideFilter * SKY_DIFF_ALBEDO");
    }

    @Test
    void everyWaterFaceKeepsTheCompleteCrystallineForegroundTuple() throws IOException {
        String water = Files.readString(WATER);
        assertFalse(water.contains("WATERFALL_RR_GUIDE_ROUGHNESS"),
                "vertical water must not be rougher than top/bottom water");

        String primary = Files.readString(PRIMARY);
        String interfaceHandler = slice(primary,
                "bool isWater = material == MATERIAL_WATER;",
                "return continuation;");
        assertInOrder(interfaceHandler,
                "float F = fresnelDielectric",
                "float3 transmittedDir = refract",
                "gv_normal = n;",
                "gv_rough = 0.0;",
                "gv_albedo = float3(0.0, 0.0, 0.0);",
                "gv_spec = makeSpecSurface",
                "float3(F, F, F)",
                "if (dot(transmittedDir, transmittedDir) > 0.0 && !isWater)",
                "bool splitEligible",
                "throughput * F");
        assertFalse(interfaceHandler.contains("waterfallSide"),
                "top, bottom and side faces must use exactly the same guide policy");
    }

    @Test
    void physicalWaterFresnelRemainsUnchangedInTheIndirectPass() throws IOException {
        String world = Files.readString(WORLD);
        String dielectricHandler = slice(world,
                "if (material == MATERIAL_WATER || material == MATERIAL_DIELECTRIC)",
                "// A dielectric interface IS the specular event");

        assertInOrder(dielectricHandler,
                "float F = fresnelDielectric",
                "float3 transmittedDir = refract",
                "bool chooseReflection = rndf(seed) < F;");
        assertFalse(world.contains("stabilizeFallingWaterFresnel"),
                "the RR-only fix must not remove the waterfall's physical reflections");
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
