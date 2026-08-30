package dev.comfyfluffy.caustica.rt;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Regression guards for the world-space volumetric fog (fog.slang) — the invariants that keep the
 * effect physically honest and stable next to water/glass, each of which is easy to re-break in
 * shader-only changes.
 */
final class RtFogShaderRegressionTest {
    private static final Path REPO_ROOT = repoRoot();
    private static final Path FOG = REPO_ROOT.resolve("shaders/world/fog.slang");
    private static final Path WORLD_RGEN = REPO_ROOT.resolve("shaders/world/world.rgen.slang");

    /**
     * The march must stop at the distance to the nearest scene hit: fog exists only in the open air
     * along a segment, so it can never be painted through a mountain or a wall the ray actually hit.
     */
    @Test
    void fogMarchStopsAtTheSceneHit() throws IOException {
        String fog = Files.readString(FOG);
        String march = slice(fog, "public FogVolume fogSegment", "public float3 fogLayer");

        assertTrue(fog.contains("float t1 = min(maxDistance, FOG_MAX_MARCH_BLOCKS);"),
                "the march interval must be clamped to the caller's hit distance");
        assertTrue(march.contains("density * dt"),
                "optical depth must be integrated per step from the local density");

        String rgen = Files.readString(WORLD_RGEN);
        // Per-segment fog on a hit must hand the march the trace's own hit distance, not a constant.
        String segmentBlock = slice(rgen,
                "FogVolume segFog = fogSegment(worldPush, ro, rd, payload.hitT",
                "// ---- Dielectric interface");
        assertTrue(segmentBlock.contains("throughput *= segFog.transmittance;"),
                "the surface behind the fog must keep the fog's transmittance");
    }

    /**
     * Sun in-scatter must be gated by real occlusion — a scene shadow ray toward the light plus the
     * analytic cloud shadow — with scene visibility resolved FIRST, mirroring the surface NEE rule.
     * This is the god-ray contract: fog a mountain shields stays dark, the gaps become shafts.
     */
    @Test
    void fogSunInscatterIsOcclusionGated() throws IOException {
        String fog = Files.readString(FOG);
        String march = slice(fog, "public FogVolume fogSegment", "public float3 fogLayer");

        assertTrue(march.contains("visibility("),
                "each in-scatter sample must fire a real shadow ray toward the light");
        assertInOrder(march,
                "float3 vis = visibility(",
                "if (max(vis.r, max(vis.g, vis.b)) > 0.0) {",
                "vis *= cloudSunShadow(push, sampleRel, lightDir);",
                "sunTerm = sunRadiance * phase * vis;");
        assertTrue(march.contains("float phase = fogPhase(push, dot(-dir, lightDir));"),
                "the sun term must be phased by the view/light angle inside the march");
        assertTrue(fog.contains("hg(cosT, g)"),
                "god rays come from the Henyey-Greenstein forward lobe, which cannot be dropped");
    }

    /**
     * The fog is LIT, not a veil: block emitters (torches, lava, glowstone) must in-scatter through
     * the same light grid the ReSTIR emitter sampling uses, with each kept emitter's runtime-scaled
     * radiance, a real visibility ray (a torch behind a wall does not halo the fog past it), and the
     * 1/r² point-light falloff that makes a torch nothing like the sun. The held-item light rides
     * the same intensity/tint lanes the surface hand-light NEE reads.
     */
    @Test
    void fogIsLitBySceneEmitters() throws IOException {
        String fog = Files.readString(FOG);
        String march = slice(fog, "public FogVolume fogSegment", "public float3 fogLayer");

        assertTrue(march.contains("findLightGridCell("),
                "emitter gathering must reuse the RIS light grid, not invent its own source");
        assertInOrder(march,
                "float3 flux = lightRadiance(light) * (emitterScale * lightArea(light));",
                "float score = fluxLum / max(r2, 1.0);",
                "lightVis[k] = visibility(midAbs, ldir,");
        assertTrue(march.contains("max(worldPush.lightScales.x, 0.0)"),
                "emitter in-scatter must follow the runtime block-light intensity slider");

        assertInOrder(march,
                "float3 localTerm = float3(0.0, 0.0, 0.0);",
                "localTerm += lightFlux[li] * lightVis[li] * (FOG_INV_4PI / max(r2, 0.25));",
                "localTerm += handColor * (handIntensity * FOG_INV_4PI / max(r2, 0.25));");
        assertTrue(march.contains("push.handLight.w"),
                "the held-item light must contribute its own halo to the medium");
    }

    /**
     * Unlit air must stay dark: the sky-ambient in-scatter (the only source that has no emitter
     * record) must be gated by a per-segment sky-visibility probe — one real shadow ray along a
     * jittered upward direction — and carry its own dim, cool tint rather than the near-white that
     * read as a flat Silent-Hill veil. A dark cave therefore holds no fog at all.
     */
    @Test
    void unlitFogStaysDark() throws IOException {
        String fog = Files.readString(FOG);
        String march = slice(fog, "public FogVolume fogSegment", "public float3 fogLayer");

        assertInOrder(march,
                "float3 skyDir = cosineDir(float3(0.0, 1.0, 0.0), seed);",
                "float skyVis = clamp(luminance(visibility(midAbs, skyDir, 1.0e4).transmittance), 0.0, 1.0);");
        assertInOrder(march,
                "float3 ambientTerm = FOG_AMBIENT_TINT * ambient * (FOG_AMBIENT_WEIGHT * 0.5 * skyVis);",
                "float3 inScatter = FOG_TINT * sunTerm + localTerm + ambientTerm;");
        assertTrue(fog.contains("public static const float3 FOG_AMBIENT_TINT"),
                "the ambient floor must carry its own tint lane, separate from the sun's");
        assertTrue(fog.contains("public static const float FOG_AMBIENT_WEIGHT = 0.12;"),
                "the ambient floor must stay a floor — a bright constant here was the white veil");
    }

    /**
     * Fog is an air phenomenon: every fog call in the bounce loop must be gated on the current
     * medium being air (zero extinction), so underwater and inside-glass segments — which already
     * attenuate through their own Beer–Lambert extinction — are never double-dimmed. The
     * camera→dielectric prefix recovery must instead gate on the camera not being submerged,
     * because the prefix lies entirely in the camera's own medium.
     */
    @Test
    void fogOnlyAppliesToAirSegments() throws IOException {
        String rgen = Files.readString(WORLD_RGEN);

        int loopGate = rgen.indexOf("!any(medium.current.extinction > 0.0)");
        assertTrue(loopGate >= 0, "the bounce loop must gate fog on the air medium");
        int nextGate = rgen.indexOf("!any(medium.current.extinction > 0.0)", loopGate + 1);
        assertTrue(nextGate > 0,
                "the sky-miss fog composite must carry the same air-medium gate");
        assertFalse(rgen.indexOf("!any(medium.current.extinction > 0.0)", nextGate + 1) > 0,
                "the air-medium gate belongs to exactly the two in-loop fog composites");

        String prefixBlock = slice(rgen,
                "// World-space fog over the same camera->surface prefix",
                "float rayConeWidth = seg.rayConeWidth;");
        assertTrue(prefixBlock.contains("!cameraSubmerged()"),
                "the prefix fog must be gated on the camera not being submerged");
    }

    /**
     * On a sky escape the fog veil must be composited BEFORE the sky radiance is added, so the
     * horizon and the sun/moon disc behind the fog are attenuated by its transmittance rather than
     * drawn at full brightness over it.
     */
    @Test
    void skyMissCompositesFogBeforeTheSky() throws IOException {
        String rgen = Files.readString(WORLD_RGEN);
        String missBlock = slice(rgen, "if (payload.hitT < 0.0) {", "// SHaRC: the sky is a real light source");

        assertInOrder(missBlock,
                "FogVolume missFog = fogSegment(",
                "throughput *= missFog.transmittance;",
                "L += throughput * sky;");
    }

    /**
     * The dielectric split (water surface, glass) must recover the fog over the camera→surface
     * prefix it consumed in Pass A, on BOTH branches — the F/(1−F) throughputs make that exactly one
     * crossing — which is what keeps a water surface fogged like any other surface at that distance.
     * The march must start at the camera itself (worldPush.camOffset), not at the split's surface
     * origin.
     */
    @Test
    void dielectricPrefixRecoversFogForBothSplitBranches() throws IOException {
        String rgen = Files.readString(WORLD_RGEN);
        String prefixBlock = slice(rgen,
                "// World-space fog over the same camera->surface prefix",
                "float rayConeWidth = seg.rayConeWidth;");

        assertInOrder(prefixBlock,
                "FogVolume preFog = fogSegment(worldPush, worldPush.camOffset,",
                "L += throughput * preFog.scatter;",
                "throughput *= preFog.transmittance;");
        assertTrue(prefixBlock.contains("Lspec += throughput * preFog.scatter;"),
                "the recovered fog must land in the specular lobe like the cloud prefix it mirrors");
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

    /** Same root discovery pattern as RtShaderConstantMirrorTest, kept local to avoid test coupling. */
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
