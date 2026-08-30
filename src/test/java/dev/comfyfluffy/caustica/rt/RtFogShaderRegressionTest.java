package dev.comfyfluffy.caustica.rt;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Regression guards for the path-integrated volumetric fog (Method B) and the legacy screen-space fog
 * that it replaced.
 *
 * <p>The old selective screen-space fog ("masked fog") was removed entirely: there is no per-pixel depth
 * mask, no {@code maskedFogDepth}, and no post-aggregation composite. All fog now lives in the path
 * integral in {@code fog.slang}, and enclosed air (caves/rooms/overhangs) is excluded by a per-path
 * sky-exposure cull performed in {@code world.rgen.slang}.
 */
final class RtFogShaderRegressionTest {
    private static final Path REPO_ROOT = repoRoot();
    private static final Path CORE = REPO_ROOT.resolve("shaders/world/world_core.slang");
    private static final Path GUIDES = REPO_ROOT.resolve("shaders/world/guides.slang");
    private static final Path PRIMARY = REPO_ROOT.resolve("shaders/world/world_primary.rgen.slang");
    private static final Path WORLD = REPO_ROOT.resolve("shaders/world/world.rgen.slang");
    private static final Path FOG = REPO_ROOT.resolve("shaders/world/fog.slang");
    private static final Path MISS = REPO_ROOT.resolve("shaders/world/world.rmiss.slang");
    private static final Path JAVA =
            REPO_ROOT.resolve("src/main/java/dev/comfyfluffy/caustica/rt/RtComposite.java");

    @Test
    void legacyScreenSpaceFogIsFullyRemoved() throws IOException {
        String core = Files.readString(CORE);
        String guides = Files.readString(GUIDES);
        String world = Files.readString(WORLD);

        // The per-pixel depth mask and the post-aggregation composite are gone for every dimension.
        assertFalse(core.contains("gFogDepthMask"),
                "the per-pixel fog depth mask texture must be removed from world_core");
        assertFalse(guides.contains("maskedFogDepth") && guides.contains("gFogDepthMask[pix]"),
                "Pass A must no longer materialize a fog depth mask");
        assertFalse(world.contains("evalAmbientFog") && world.contains("screenFog"),
                "world.rgen must no longer composite emissive fog in screen space");
        assertFalse(world.contains("fogEnabled()"),
                "world.rgen must not depend on the removed masked fog toggle");
    }

    @Test
    void volumetricFogIsIntegratedPerSegmentAndCulledBySkyExposure() throws IOException {
        String world = Files.readString(WORLD);
        String fog = Files.readString(FOG);

        // fog.slang exposes the per-segment march and its gate, and takes the sky-exposure cull factor.
        assertTrue(fog.contains("public bool fogVolumetricEnabled(WorldPush push)"),
                "fog.slang must expose the volumetric gate");
        assertTrue(fog.contains("float exposure"),
                "fogSegment must take the sky-exposure cull factor");

        // The tracer integrates it over the camera->interface prefix and over every geometry hit, and
        // passes the per-path exposure it computed once.
        assertTrue(world.contains("FogVolume preFog = fogSegment("),
                "the camera->interface prefix must carry volumetric fog");
        assertTrue(world.contains("FogVolume segFog = fogSegment("),
                "per-hit path segments must carry volumetric fog");
        assertTrue(world.contains("fogSkyExposure("),
                "the sky-exposure cull helper must exist");
        assertTrue(world.contains("float fogExposure = 1.0;"),
                "the per-path exposure must be cached once per path");
    }

    @Test
    void ambientFogLaneIsVolumetricOnlyForTheOverworld() throws IOException {
        String java = Files.readString(JAVA);

        // The screen-space Nether/End authored haze lanes are removed: ambientFog now drives only the
        // volumetric fog, which is Overworld-only.
        String ambient = slice(java, "private static Float4 ambientFog", "private static Float4 fogState");
        assertTrue(ambient.startsWith("private static Float4 ambientFog"),
                "must be able to locate ambientFog");
        assertTrue(ambient.contains("if (dimension != DIMENSION_OVERWORLD)"),
                "the fog medium must be zeroed outside the Overworld");
        assertFalse(ambient.contains("DIMENSION_NETHER -> new Float4"),
                "the screen-space Nether haze lane must be removed");
        assertFalse(ambient.contains("DIMENSION_END -> new Float4"),
                "the screen-space End haze lane must be removed");
        assertFalse(ambient.contains("Composite.FOG.value()"),
                "the removed masked-fog toggle must not gate the fog any more");
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

    private static String slice(String source, String startNeedle, String endNeedle) {
        int start = source.indexOf(startNeedle);
        assertTrue(start >= 0, "missing snippet start: " + startNeedle);
        int end = source.indexOf(endNeedle, start);
        assertTrue(end > start, "missing snippet end for " + startNeedle + " before " + endNeedle);
        return source.substring(start, end);
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
