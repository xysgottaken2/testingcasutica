package dev.comfyfluffy.caustica.rt;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Guards the layer-wall POM path. Relief is still a 2D height march (a per-voxel grid would tank
 * closest-hit), so the missing Z of each layer has to be a vertical wall at height cliffs and at
 * the sprite border — otherwise a close side view is a straight square going into the face.
 */
final class RtPomShaderRegressionTest {
    private static final Path REPO_ROOT = repoRoot();
    private static final Path RCHIT = REPO_ROOT.resolve("shaders/world/world.rchit.slang");
    private static final Path CLOUDS = REPO_ROOT.resolve("shaders/world/clouds.slang");

    @Test
    void parallaxHitsLayerWallsInsteadOfAbortingAtTheSpriteBorder() throws IOException {
        String source = Files.readString(RCHIT);
        String body = slice(source, "ParallaxHit parallaxUv(", "float3 applyBreaking");

        assertTrue(body.contains("struct ParallaxHit") || source.contains("struct ParallaxHit"),
                "POM must return a wall normal alongside the displaced UV");
        assertTrue(body.contains("hitWall") && body.contains("pomWallWorldNormal"),
                "the height march must detect vertical walls, not only horizontal layer tops");
        assertFalse(body.contains("return atlasUv;"),
                "leaving the sprite must hit the border wall, not pop back to the undisplaced quad");
        assertTrue(body.contains("clamp(nextUv, float2(0.0, 0.0), float2(1.0, 1.0))"),
                "the sprite-border wall stays on the last in-bounds UV");
        assertTrue(body.contains("(hi - lo) > layerDepth * 0.65"),
                "a height cliff between layers must be a wall, not another horizontal card");
        assertFalse(body.contains("edgeFade"),
                "flattening relief at the sprite edge recreates the straight-square silhouette");
    }

    @Test
    void closestHitAppliesWallNormalsAfterMaterialEvaluation() throws IOException {
        String source = Files.readString(RCHIT);
        assertTrue(source.contains("n = pomApplyWall(surface.normal, entityPomWall, vdir);"),
                "entity POM walls must replace the top-face normal map");
        assertTrue(source.contains("n = pomApplyWall(surface.normal, pomWall, vdir);"),
                "terrain POM walls must replace the top-face normal map");
    }

    @Test
    void volumetricCloudsCarveAHeightOffsetWallInsteadOfAStraightExtrusion() throws IOException {
        String source = Files.readString(CLOUDS);
        String body = slice(source, "float cloudVolumeDensity", "float cloudLightTransmittance");
        assertTrue(body.contains("LAYER WALL") || body.contains("layer wall") || body.contains("wall = cloudNoise"),
                "volumetric density must document/implement the 2D layer wall");
        assertTrue(body.contains("float2(hf, 1.0 - hf)") || body.contains("hf, 1.0 - hf"),
                "the wall sample must walk with height so the side is not a straight extrusion");
        assertTrue(body.contains("threshold += (wall - 0.5)"),
                "the wall must move the coverage isosurface, not only the billow detail");
    }

    private static String slice(String source, String startNeedle, String endNeedle) {
        int start = source.indexOf(startNeedle);
        assertTrue(start >= 0, "missing shader snippet start: " + startNeedle);
        int end = source.indexOf(endNeedle, start);
        assertTrue(end > start, "missing shader snippet end: " + endNeedle);
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
