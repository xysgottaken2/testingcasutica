package dev.comfyfluffy.caustica.rt;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Regression guards for the NVIDIA RTXDI integration, in the style of the other shader-text
 * regression tests: the wiring between the vendored SDK core (shaders/rtxdi), the application
 * bridge (shaders/world/rtxdi.slang), the world push data and the raygen dispatch is easy to
 * re-break with a well-intended refactor, and none of it is exercised without a Vulkan device.
 */
final class RtRtxdiShaderRegressionTest {
    private static final Path REPO_ROOT = repoRoot();
    private static final Path RTXDI_BRIDGE = REPO_ROOT.resolve("shaders/world/rtxdi.slang");
    private static final Path WORLD_RGEN = REPO_ROOT.resolve("shaders/world/world.rgen.slang");
    private static final Path WORLD_COMMON = REPO_ROOT.resolve("shaders/world/world_common.slang");
    private static final Path WORLD_CORE = REPO_ROOT.resolve("shaders/world/world_core.slang");
    private static final Path VENDORED_SDK = REPO_ROOT.resolve("shaders/rtxdi/Rtxdi");
    private static final Path COMPOSITE = REPO_ROOT.resolve(
            "src/main/java/dev/comfyfluffy/caustica/rt/RtComposite.java");

    @Test
    void vendoredSdkCoreIsPresentAndAttributed() {
        String[] vendored = {
                "RtxdiParameters.h", "RtxdiTypes.h",
                "DI/ReSTIRDIParameters.h", "DI/Reservoir.hlsli", "DI/ReservoirStorage.hlsli",
                "DI/PairwiseStreaming.hlsli", "DI/SpatioTemporalResampling.hlsli",
                "DI/InitialSampling.hlsli",
                "LightSampling/LocalLightSelection.hlsli", "LightSampling/UniformSampling.hlsli",
                "LightSampling/RISBufferSegmentParameters.h", "LightSampling/RISBuffer.hlsli",
                "ReGIR/ReGIRParameters.h", "ReGIR/ReGIRSampling.hlsli",
                "Utils/ReservoirAddressing.hlsli", "Utils/Checkerboard.hlsli",
                "Utils/Math.hlsli", "Utils/RandomSamplerState.hlsli",
                "Utils/RandomSamplerPerPassSeeds.hlsli", "Utils/SampledLightData.hlsli"};
        for (String rel : vendored) {
            Path file = VENDORED_SDK.resolve(rel);
            assertTrue(Files.isRegularFile(file), "missing vendored RTXDI file: " + rel);
            try {
                String source = Files.readString(file);
                assertTrue(source.contains("This software contains source code provided by NVIDIA Corporation."),
                        rel + " must carry the NVIDIA source-code attribution notice");
                // The vendored core must keep compiling through includes that are relative to
                // each file — a repo-root include style would not resolve under Slang.
                assertFalse(source.contains("\"Rtxdi/"),
                        rel + " must not keep upstream repo-root #include paths");
            } catch (IOException e) {
                throw new AssertionError("failed to read " + rel, e);
            }
        }
    }

    @Test
    void bridgeImplementsTheSdkApplicationContract() throws IOException {
        String bridge = Files.readString(RTXDI_BRIDGE);
        // The RAB_* functions the vendored DI core references; if one disappears the Slang build
        // fails with an unresolved symbol, but this pins the intent right next to the cause.
        for (String rab : new String[]{
                "RAB_Surface RAB_EmptySurface", "bool RAB_IsSurfaceValid",
                "RAB_Surface RAB_GetGBufferSurface", "RAB_LightInfo RAB_LoadLightInfo",
                "RAB_LightInfo RAB_EmptyLightInfo", "int RAB_TranslateLightIndex",
                "RAB_LightSample RAB_SamplePolymorphicLight", "RAB_LightSample RAB_EmptyLightSample",
                "float RAB_GetLightSampleTargetPdfForSurface", "float RAB_LightSampleSolidAnglePdf",
                "bool RAB_IsAnalyticLightSample", "float3 RAB_LightSamplePosition",
                "RAB_Material RAB_GetMaterial", "bool RAB_AreMaterialsSimilar",
                "int2 RAB_ClampSamplePositionIntoView", "float RAB_GetSurfaceLinearDepth",
                "float3 RAB_GetSurfaceNormal", "float3 RAB_GetSurfaceWorldPos",
                "void RAB_GetLightDirDistance", "bool RAB_GetConservativeVisibility",
                "bool RAB_GetTemporalConservativeVisibility",
                "bool RAB_TraceRayForLocalLight", "float RAB_EvaluateEnvironmentMapSamplingPdf",
                "float RAB_EvaluateLocalLightSourcePdf"}) {
            assertTrue(bridge.contains(rab), "the bridge must define " + rab);
        }
        // The SDK resource macros must bind the reservoir buffer, the neighbor offsets and the
        // pairwise bias-correction mode this integration is configured for.
        assertTrue(bridge.contains("#define RTXDI_LIGHT_RESERVOIR_BUFFER"),
                "the bridge must bind the SDK reservoir buffer macro");
        assertTrue(bridge.contains("#define RTXDI_NEIGHBOR_OFFSETS_BUFFER"),
                "the bridge must bind the SDK neighbor-offset buffer macro");
        assertTrue(bridge.contains("#define RTXDI_ENABLE_PRESAMPLING 0"),
                "presampling is compiled out in this integration");
        assertTrue(bridge.contains("RTXDI_BIAS_CORRECTION_PAIRWISE"),
                "resampling must stay on the fused pairwise-MIS path");
        // The DI core expects the application bridge to pre-include the random sampler state —
        // it references RTXDI_RandomSamplerState and the per-pass seed constants without
        // including their file itself.
        assertTrue(bridge.contains("#include \"../rtxdi/Rtxdi/Utils/RandomSamplerState.hlsli\""),
                "the bridge must include the SDK random sampler state before the DI core");
        // The SDK entry point the raygen integration calls for reuse, plus the bridge's own
        // initial-candidate sampler: it must propose from the SAME light-grid power mixture the
        // built-in engines use (not the SDK's uniform-over-the-whole-buffer lottery, whose
        // variance was the RTXDI flicker) and must leave the reservoir in the canonical form the
        // fused pairwise pass assumes (weight normalized by the candidate count, then M = 1).
        assertTrue(bridge.contains("rtxdiSampleInitialCandidates"));
        assertTrue(bridge.contains("selectLightGridLight(gridCell, useLocal, proposalSeed, lightIndex);"));
        assertTrue(bridge.contains("RTXDI_StreamSample(state, lightIndex, uv, risRnd, targetPdf, invSourcePdf)"));
        assertTrue(bridge.contains("RTXDI_FinalizeResampling(state, 1.0, float(candidateCount));"));
        assertFalse(bridge.contains("RTXDI_SampleLightsForSurface(rng"),
                "initial candidates must not come from the SDK's whole-buffer uniform draw");
        assertTrue(bridge.contains("RTXDI_DISpatioTemporalResamplingWithPairwiseMIS"));
    }

    @Test
    void raygenDispatchesTheRtxdiEngineAtTheReservoirReceiver() throws IOException {
        String rgen = Files.readString(WORLD_RGEN);
        // Mode 2 selects RTXDI at the same first-stable-receiver slot as the built-in ReSTIR, on
        // terrain and particle receivers alike, with the identical NRD lobe split.
        assertTrue(rgen.contains("rtxdiEnabled()"), "raygen must gate the RTXDI path");
        assertTrue(rgen.contains("(restirEnabled() || rtxdiEnabled())"),
                "the reservoir receiver must engage for either engine");
        assertTrue(rgen.contains("rtxdiDirectLighting(pix, dimensions, hitPos, n, v, rd, diffAlb, F0, rough,"),
                "the main receiver must shade through the RTXDI entry point");
        assertTrue(rgen.contains("rtxdiDirectLighting(pix, dimensions, hitPos, n, v, rd, albedo,"),
                "particle (two-sided) receivers must shade through the RTXDI entry point");
        // The built-in ReSTIR must never run off a null history buffer when RTXDI owns the mode.
        assertTrue(rgen.contains("if (shadeWithReservoir && restirEnabled())"),
                "the built-in restirSpatiotemporal must additionally check restirEnabled()");
    }

    @Test
    void worldPushPublishesTheRtxdiLanesAndMode() throws IOException {
        String common = Files.readString(WORLD_COMMON);
        for (String lane : new String[]{
                "uint64_t rtxdiReservoirAddr", "uint64_t rtxdiSurfacePrevAddr",
                "uint64_t rtxdiSurfaceCurAddr", "uint64_t rtxdiNeighborOffsetsAddr",
                "uint4    rtxdiParams", "float4   rtxdiSampling", "float4   rtxdiReuse"}) {
            assertTrue(common.contains(lane), "WorldPush must declare " + lane);
        }
        assertTrue(common.contains("2=RTXDI SDK resampling"),
                "pc.restirMode must document mode 2 as RTXDI");

        String core = Files.readString(WORLD_CORE);
        assertTrue(core.contains("pc.restirMode == 2u"),
                "rtxdiEnabled must key on the explicit mode uniform");
        assertTrue(core.contains("pc.restirMode == 1u"),
                "the built-in restirEnabled must be exclusive with RTXDI mode");
    }

    @Test
    void hostPublishesHistoryAndAllocatesOnToggle() throws IOException {
        String composite = Files.readString(COMPOSITE);
        assertTrue(composite.contains("private void syncRtxdiResources(RtContext ctx)"),
                "RTXDI history must be allocated/released with the toggle like ReSTIR's");
        assertTrue(composite.contains("RtRtxdiLayout.reservoirBufferBytes(renderW, renderH)"),
                "the reservoir buffer must be sized with the SDK block-linear layout");
        assertTrue(composite.contains("RtRtxdiLayout.neighborOffsets()"),
                "the SDK neighbor-offset table must back the spatial pass");
        assertTrue(composite.contains("return 2; // NVIDIA RTXDI engine"),
                "restirMode must publish 2 while RTXDI owns direct lighting");
        assertTrue(composite.contains("rtxdiWriteIndex ^= 1;"),
                "the reservoir layers must ping-pong at frame end");
        assertTrue(composite.contains("rtxdiFrameGeneration = terrain.lightGeneration();"),
                "the frame's light generation must be captured exactly once, at push-constant time");
        assertTrue(composite.contains("rtxdiPrevLightGeneration = rtxdiFrameGeneration;"),
                "the next frame must validate history against the generation this frame's trace"
                        + " actually used (captured once at push time, not re-read at frame end)");
    }

    @Test
    void temporalBackprojectionIsClampedBeforeTheReservoirLoad() throws IOException {
        String st = Files.readString(VENDORED_SDK.resolve("DI/SpatioTemporalResampling.hlsli"));
        // The reservoir buffer is reached through raw device pointers, which have none of the
        // descriptor-based bounds robustness the SDK's sample app leans on: the fused pairwise
        // pass loads the temporal reservoir UNCONDITIONALLY at the backprojected position, and an
        // offscreen backprojection (first frame after a world load, camera cut, fast pan) wraps
        // to a giant uint2 index and device-losts the GPU. That position must be clamped into
        // the view first, exactly the idiom the spatial loop already uses.
        assertTrue(st.contains("centralIdx = RAB_ClampSamplePositionIntoView(centralIdx, true);"),
                "the temporal central load must clamp its backprojected position into the view");
    }

    private static Path repoRoot() {
        Path dir = Path.of("").toAbsolutePath();
        while (dir != null && !Files.isDirectory(dir.resolve("shaders/world"))) {
            dir = dir.getParent();
        }
        assertTrue(dir != null, "could not locate the repository root from " + Path.of("").toAbsolutePath());
        return dir;
    }
}
