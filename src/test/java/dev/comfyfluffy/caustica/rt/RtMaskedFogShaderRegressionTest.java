package dev.comfyfluffy.caustica.rt;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Regression guards for masked fog — the properties that make it a fix rather than a second fog model,
 * and that a later shader-only edit could quietly undo.
 *
 * <p>The effect scales the ambient fog's DENSITY by an estimate of how open to the sky the segment's
 * air is, so enclosed spaces stop picking up daylight-coloured in-scatter. Four things have to hold for
 * that to stay true, and none of them would fail to compile if they stopped holding.
 */
final class RtMaskedFogShaderRegressionTest {
    private static final Path REPO_ROOT = repoRoot();
    private static final Path MEDIUM = REPO_ROOT.resolve("shaders/world/medium.slang");
    private static final Path WORLD_CORE = REPO_ROOT.resolve("shaders/world/world_core.slang");
    private static final Path WORLD_RGEN = REPO_ROOT.resolve("shaders/world/world.rgen.slang");
    private static final Path COMMON = REPO_ROOT.resolve("shaders/world/world_common.slang");
    private static final Path COMPOSITE =
            REPO_ROOT.resolve("src/main/java/dev/comfyfluffy/caustica/rt/RtComposite.java");
    private static final Path CONFIG =
            REPO_ROOT.resolve("src/main/java/dev/comfyfluffy/caustica/CausticaConfig.java");
    private static final Path VIDEO_OPTIONS =
            REPO_ROOT.resolve("src/main/java/dev/comfyfluffy/caustica/client/RtVideoOptions.java");
    private static final Path EN_US =
            REPO_ROOT.resolve("src/main/resources/assets/caustica/lang/en_us.json");

    /**
     * The mask must scale the density, not the in-scatter colour. Masking the colour alone would stop
     * enclosed air glowing but leave it absorbing with distance — swapping one artefact for another
     * instead of removing it.
     */
    @Test
    void maskScalesDensitySoInScatterAndExtinctionMoveTogether() throws IOException {
        String source = Files.readString(MEDIUM);
        String body = slice(source, "public AmbientFog evalAmbientFog(float4 ambientFog, float distance, float mask)",
                "// ---- Masked fog");

        assertTrue(body.contains("float density = ambientFog.w * clamp(mask, 0.0, 1.0);"),
                "the mask must scale the fog density, so in-scatter and extinction stay coherent");
        assertFalse(body.contains("ambientFog.xyz * (1.0 - t) * mask")
                        || body.contains("mask * ambientFog.xyz"),
                "the mask must not be applied to the in-scatter colour on its own");
        // mask == 1 has to reproduce the original uniform integral exactly, or enabling the option
        // would shift every open-air scene as well.
        assertTrue(body.contains("float t = exp(-min(density * distance, 32.0));")
                        && body.contains("result.inScatter = ambientFog.xyz * (1.0 - t);"),
                "the masked integral must remain the original Beer-Lambert emissive-medium form");
    }

    /**
     * The probe point is drawn from the in-scatter distribution along the segment, and must stay
     * strictly inside it: sampling the far end would re-hit the surface the segment just landed on and
     * report open air as sealed.
     */
    @Test
    void skyProbeSamplesInsideTheSegmentByTheInScatterDistribution() throws IOException {
        String source = Files.readString(MEDIUM);
        String body = slice(source, "public float fogSkyAccess(", "// Per-path cached sky-access mask");

        assertTrue(body.contains("-log(max(1.0 - u * (1.0 - exp(-opticalDepth)), 1.0e-6)) / safeDensity"),
                "the probe distance must invert the single-scatter CDF, not use a fixed point");
        assertTrue(body.contains("clamp(t, 0.0, max(distance - SURF_BIAS, 0.0))"),
                "the probe origin must stay strictly inside the segment it is masking");
        assertTrue(body.contains("visibility(probeOrigin, probeDir, FOG_MASK_PROBE_DISTANCE)"),
                "sky access must use the shadow-class visibility query, so glass and cutout pass through");
        assertTrue(body.contains("float3(radius * cos(phi), 1.0, radius * sin(phi))"),
                "the probe must aim into a cone about +Y so cave mouths fade instead of snapping");
    }

    /** One probe per path, and none at all for segments whose fog is negligible. */
    @Test
    void theProbeIsCachedPerPathAndSkippedWhenTheFogIsNegligible() throws IOException {
        String source = Files.readString(MEDIUM);
        String body = slice(source, "public float ambientFogMask(", "\n}\n");

        assertInOrder(body,
                "if (cachedValid) {",
                "return cachedMask;",
                "density * distance < FOG_MASK_MIN_OPTICAL_DEPTH",
                "return 1.0;",
                "float mask = fogSkyAccess(",
                "cachedValid = true;");
        // A skipped segment must not populate the cache, or one negligible segment would pin the whole
        // path to the unmasked value.
        int skipReturn = body.indexOf("return 1.0;");
        int firstCacheWrite = body.indexOf("cachedMask = mask;");
        assertTrue(skipReturn > 0 && firstCacheWrite > skipReturn,
                "the negligible-fog early out must not fill the per-path cache");
    }

    /**
     * Every fog segment in the path tracer goes through the mask, and the feature is Overworld-only:
     * the Nether's haze and the End's dust are self-illuminated media, not reflected sky.
     */
    @Test
    void everyFogSegmentIsMaskedAndOnlyTheOverworldIsAffected() throws IOException {
        String raygen = Files.readString(WORLD_RGEN);
        String core = Files.readString(WORLD_CORE);

        assertTrue(core.contains("worldFeature(worldPush, FEATURE_MASKED_FOG)")
                        && core.contains("worldPush.dimension == DIMENSION_OVERWORLD"),
                "masked fog must be gated on both the option and the Overworld");

        // Both fog integrations in the raygen — the dielectric prefix and the per-segment one — must
        // pass a mask, so a reflection or refraction cannot escape into the unmasked path.
        assertTrue(raygen.contains("evalAmbientFog(worldPush.ambientFog, prefixDist, prefixMask)"),
                "the dielectric prefix segment must apply the mask");
        assertTrue(raygen.contains("evalAmbientFog(worldPush.ambientFog, payload.hitT, segMask)"),
                "the per-bounce segment must apply the mask");
        assertFalse(raygen.contains("evalAmbientFog(worldPush.ambientFog, prefixDist)")
                        || raygen.contains("evalAmbientFog(worldPush.ambientFog, payload.hitT)"),
                "no fog segment may bypass the mask");
        // The shared per-path cache is what keeps this to one ray; both call sites must use it.
        assertTrue(raygen.contains("fogMask, fogMaskValid, seed"),
                "both call sites must share the one per-path probe");
    }

    /** The option has to reach the shader and the player: flag bit, push, config setting and UI row. */
    @Test
    void theOptionIsWiredFromConfigThroughToTheShaderAndTheMenu() throws IOException {
        assertTrue(Files.readString(COMMON).contains("public static const uint FEATURE_MASKED_FOG = 256u;"),
                "the feature bit must exist in the shader ABI");
        assertTrue(Files.readString(COMPOSITE).contains("flags |= FEATURE_MASKED_FOG;"),
                "RtComposite must push the feature bit");
        assertTrue(Files.readString(CONFIG).contains("\"caustica.rt.maskedFog\", \"composite.masked-fog\""),
                "the config setting must exist with its documented keys");
        String options = Files.readString(VIDEO_OPTIONS);
        assertTrue(options.contains("CausticaConfig.Rt.Composite.MASKED_FOG")
                        && options.contains("maskedFog(),"),
                "the toggle must appear in the RT options screen");
        String lang = Files.readString(EN_US);
        assertTrue(lang.contains("\"caustica.options.rt.maskedFog\"")
                        && lang.contains("\"caustica.options.rt.maskedFog.tooltip\""),
                "the toggle needs a caption and a tooltip");
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

    /** Same root discovery pattern as the other shader regression tests, kept local by design. */
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
