package dev.comfyfluffy.caustica.rt;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.junit.jupiter.api.Assertions.assertTrue;

/** Regression guards for waterfall edges and water-volume misses. */
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
    void verticalVoxelClosureFacesTransmitInsteadOfMirroringNearbyLights() throws IOException {
        String water = Files.readString(WATER);
        String helper = slice(water,
                "public float stabilizeFallingWaterFresnel",
                "// ---- Water caustics.");

        assertInOrder(helper,
                "if (dot(transmittedDir, transmittedDir) <= 0.0)",
                "return 1.0;",
                "float freeSurface = smoothstep(0.45, 0.75, abs(nGeo.y));",
                "return fresnel * freeSurface;");
        assertTrue(water.contains("if (abs(nGeo.y) < 0.5) return nGeo;"),
                "vertical waterfall faces must remain identifiable by their geometric normal");
    }

    @Test
    void bothWavefrontPassesStabilizeFresnelBeforeUsingIt() throws IOException {
        String primary = Files.readString(PRIMARY);
        String primaryHandler = slice(primary,
                "float etaI = medium.current.ior;",
                "return continuation;");
        assertInOrder(primaryHandler,
                "float F = fresnelDielectric",
                "float3 transmittedDir = refract",
                "if (isWater)",
                "F = stabilizeFallingWaterFresnel(F, geometricNormal, transmittedDir);",
                "gv_spec = makeSpecSurface",
                "bool splitEligible");

        String world = Files.readString(WORLD);
        String indirectHandler = slice(world,
                "if (material == MATERIAL_WATER || material == MATERIAL_DIELECTRIC)",
                "// A dielectric interface IS the specular event");
        assertInOrder(indirectHandler,
                "float F = fresnelDielectric",
                "float3 transmittedDir = refract",
                "if (isWater)",
                "F = stabilizeFallingWaterFresnel(F, geometricNormal, transmittedDir);",
                "bool chooseReflection = rndf(seed) < F;");
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
