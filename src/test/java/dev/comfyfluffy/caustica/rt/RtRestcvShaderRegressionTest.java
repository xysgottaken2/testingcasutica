package dev.comfyfluffy.caustica.rt;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** Pins the stability and no-extra-ray contracts of the compact ReSTCV adaptation. */
final class RtRestcvShaderRegressionTest {
    private static final Path ROOT = repoRoot();
    private static final Path LIGHTING = ROOT.resolve("shaders/world/lighting.slang");
    private static final Path COMMON = ROOT.resolve("shaders/world/world_common.slang");
    private static final Path RAYGEN = ROOT.resolve("shaders/world/world.rgen.slang");
    private static final Path VIDEO_SCREEN = ROOT.resolve(
            "src/main/java/dev/comfyfluffy/caustica/client/gui/RtVideoOptionsScreen.java");

    @Test
    void independentRisUsesTheSameEarlyHistorySafeBounds() throws IOException {
        String lighting = Files.readString(LIGHTING);
        String shade = method(lighting, "public float3 shadeReservoir(",
                "public float3 shadeRestirReservoir(");

        assertTrue(shade.contains("float appliedW = min(s.W, restirMaxW());"));
        assertTrue(shade.contains("restirBoundContribution(contrib * vis * appliedW"));
        assertTrue(lighting.contains("if (!(target > 0.0)) return;"),
                "zero-contribution history must not be promoted by the emissive p-hat floor");
        assertFalse(shade.contains("s.restir != 0u"),
                "the anti-flash guard must not disappear when ReSTIR is disabled");
    }

    @Test
    void restcvCarriesTheMatchingRepresentativeAndStoresOnlyAfterVisibility() throws IOException {
        String lighting = Files.readString(LIGHTING);
        String merge = method(lighting, "public void restirMerge(", "public bool restirPreviousPixel(");
        String reuse = method(lighting, "public Reservoir restirSpatiotemporal(",
                "public float3 shadeReservoir(");
        String resolve = method(lighting, "public float3 shadeRestirReservoir(",
                "public void shadeReservoirSplit(");

        assertTrue(merge.contains("dst.cvEstimate = source.cvEstimate;")
                && merge.contains("dst.cvRepresentative = source.cvRepresentative;")
                && merge.contains("dst.sourceW = source.W;"));
        assertFalse(reuse.contains("restirStore("),
                "unshadowed reservoir selection must not be persisted as a ReSTCV estimate");
        assertTrue(resolve.contains("standardEstimate = shadeReservoir(")
                && resolve.contains("standardEstimate * sourceToFinal")
                && resolve.contains("s.cvEstimate + currentAtSourceWeight - s.cvRepresentative")
                && resolve.contains("fallbackWeight = strength * clamp(worldPush.restcvParams.y")
                && resolve.contains("* fallbackConfidence;")
                && resolve.contains("restirStore("));
        assertFalse(resolve.contains("visibility("),
                "ReSTCV must reuse shadeReservoir's one visibility ray rather than trace another");
    }

    @Test
    void persistentRecordIsExplicitlyCacheAlignedAndIntensityIndependent() throws IOException {
        String common = Files.readString(COMMON);
        String lighting = Files.readString(LIGHTING);

        assertTrue(common.contains("public uint packedCvEstimate;")
                && common.contains("public uint packedCvRepresentative;")
                && common.contains("public uint cvMeta;")
                && common.contains("public uint reserved;"));
        assertTrue(lighting.contains("safeEstimate = restirBoundContribution(cvEstimate, contributionLimit) / blockScale")
                && lighting.contains("restcvUnpackPositiveHdr(record.packedCvEstimate) * blockScale"));
    }

    @Test
    void spatialPatternNoLongerMovesForeverInAStaticScene() throws IOException {
        String lighting = Files.readString(LIGHTING);
        String disk = method(lighting, "public float2 restirDiskOffset(", "public int2 restirSpatialOffset(");
        String spatialOffset = method(lighting, "public int2 restirSpatialOffset(", "public void restirStore(");

        assertFalse(disk.contains("frameIndex"));
        assertFalse(spatialOffset.contains("frameIndex"));
        assertTrue(disk.contains("restirSpatialRadius()"));
        assertTrue(lighting.contains("maximumAge > 0u && age >= maximumAge"));
        assertTrue(lighting.contains("dst.age = min(source.age + 1u, 0xffu);"),
                "finite age must really expire while zero leaves static convergence uninterrupted");
    }

    @Test
    void raygenUsesTheResolvedEstimateAndUiExposesTheSubmenu() throws IOException {
        String raygen = Files.readString(RAYGEN);
        String screen = Files.readString(VIDEO_SCREEN);

        assertTrue(raygen.contains("shadeRestirReservoir(r")
                && raygen.contains("restirMatchSplitToResolved(transportedEstimate")
                && raygen.contains("throughput * reservoirEstimate, restirContributionLimit()"));
        assertTrue(screen.contains("RtVideoOptions.restirSettingsButton(this)"));
    }

    private static String method(String source, String start, String end) {
        int from = source.indexOf(start);
        int to = source.indexOf(end, from + start.length());
        if (from < 0 || to < 0) {
            throw new AssertionError("could not isolate shader method between " + start + " and " + end);
        }
        return source.substring(from, to);
    }

    private static Path repoRoot() {
        Path dir = Path.of("").toAbsolutePath();
        for (Path candidate = dir; candidate != null; candidate = candidate.getParent()) {
            if (Files.isDirectory(candidate.resolve("shaders/world"))
                    && Files.isDirectory(candidate.resolve("src/test/java"))) {
                return candidate;
            }
        }
        throw new IllegalStateException("could not locate repository root from " + dir);
    }
}
