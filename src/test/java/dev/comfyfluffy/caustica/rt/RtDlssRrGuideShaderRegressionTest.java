package dev.comfyfluffy.caustica.rt;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.junit.jupiter.api.Assertions.assertTrue;

/** Regression guards for guide data consumed by DLSS Ray Reconstruction. */
final class RtDlssRrGuideShaderRegressionTest {
    private static final Path REPO_ROOT = repoRoot();

    @Test
    void dlssReceivesSpecularHitDistanceWithReflectionMotion() throws IOException {
        String core = source("shaders/world/world_core.slang");
        String guides = source("shaders/world/guides.slang");
        String composite = source("src/main/java/dev/comfyfluffy/caustica/rt/RtComposite.java");
        String rr = source("src/main/java/dev/comfyfluffy/caustica/rt/pipeline/RtDlssRr.java");
        String shim = source("native/ngx_shim/ngx_shim.cpp");
        String skyMiss = source("shaders/world/world.rmiss.slang");

        assertTrue(core.contains("gSpecHitDistance"),
                "the world pass must expose a specular hit-distance guide texture");
        assertTrue(guides.contains("specHitDistance = payload.hitT;"),
                "the reflection guide probe must publish the reflected hit distance");
        assertTrue(guides.contains("gSpecHitDistance[pix] = specHitDistance;"),
                "Pass A must write a hit-distance guide next to specular motion");
        assertTrue(composite.contains("private static final int GUIDE_COUNT = 11;"),
                "the world descriptor set must reserve the extra guide binding");
        assertTrue(skyMiss.contains("[[vk::binding(14, 0)]] Sampler2D celestialsAtlas;"),
                "adding the extra guide moves the sky atlas binding after bindings 3..13");
        assertTrue(composite.contains("gSpecHitDistance = ctx.createStorageImage"),
                "the guide image must be allocated at render resolution");
        assertTrue(rr.contains("specularHitDistance.view, specularHitDistance.image"),
                "the Java DLSS bridge must forward the guide image to the native shim");
        assertTrue(shim.contains("eval.pInSpecularHitDistance = &specularHitDistance;"),
                "DLSS-RR must receive the specular hit-distance resource, not a null pointer");
    }

    @Test
    void nonZeroGuideAlbedoHasAFp16SafeFloor() throws IOException {
        String guides = source("shaders/world/guides.slang");
        String primary = source("shaders/world/world_primary.rgen.slang");

        assertTrue(guides.contains("public static const float GUIDE_ALBEDO_MIN = 2.0e-3;"),
                "DLSS guide demodulation needs a tiny non-zero floor for dark LabPBR texels");
        assertTrue(guides.contains("? max(albedo, float3(GUIDE_ALBEDO_MIN))"),
                "non-zero guide colours must be raised without inventing absent lobes");
        assertTrue(primary.contains("gv_albedo = stabilizeGuideAlbedo(diffAlb);"),
                "primary opaque diffuse guides must use the stabilized guide albedo");
        assertTrue(guides.contains("s.albedo = stabilizeGuideAlbedo(albedo);"),
                "specular guide albedo must use the same floor so dark metals keep stable RR guides");
    }

    private static String source(String path) throws IOException {
        return Files.readString(REPO_ROOT.resolve(path));
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
