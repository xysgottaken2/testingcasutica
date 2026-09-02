package dev.comfyfluffy.caustica.rt;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** Regression guards for cloud/shadow interactions that are easy to re-break in shader-only changes. */
final class RtCloudShaderRegressionTest {
    private static final Path REPO_ROOT = repoRoot();
    private static final Path CLOUDS = REPO_ROOT.resolve("shaders/world/clouds.slang");
    private static final Path WORLD_RGEN = REPO_ROOT.resolve("shaders/world/world.rgen.slang");
    private static final Path WORLD_RMISS = REPO_ROOT.resolve("shaders/world/world.rmiss.slang");
    private static final Path RT_COMPOSITE =
            REPO_ROOT.resolve("src/main/java/dev/comfyfluffy/caustica/rt/RtComposite.java");

    /**
     * The celestials atlas binding in {@code world.rmiss} must equal the descriptor slot the
     * pipeline actually writes it to: {@code skyBinding = firstExtraBinding(3) + GUIDE_COUNT}
     * (RtPipeline.create layout + RtComposite.ensureWorld wiring). Nothing in the toolchain ties
     * these two numbers together — a drift samples an unwritten binding, which drivers answer with
     * a black texture: the sun and moon discs silently "evaporate" while every other sky term
     * (directions, radiance, fog, god rays) keeps looking perfect. This has happened before; both
     * sides are now parsed instead of trusted, so the next guide-block change that forgets the
     * other fails CI instead of hiding the sun.
     */
    @Test
    void skyAtlasBindingFollowsGuideCount() throws IOException {
        var decl = java.util.regex.Pattern.compile(
                "\\[\\[vk::binding\\((\\d+), 0\\)]] Sampler2D celestialsAtlas")
                .matcher(Files.readString(WORLD_RMISS));
        assertTrue(decl.find(), "world.rmiss must declare the celestialsAtlas binding");
        int atlasBinding = Integer.parseInt(decl.group(1));

        String composite = Files.readString(RT_COMPOSITE);
        var guide = java.util.regex.Pattern.compile("GUIDE_COUNT = (\\d+);").matcher(composite);
        assertTrue(guide.find(), "RtComposite must define GUIDE_COUNT for the world pipeline");
        int guideCount = Integer.parseInt(guide.group(1));

        // firstExtraBinding is 3 whenever the world pipeline carries the block albedo atlas
        // (RtPipeline.create's withBlockAlbedoAtlas ? 3 : 2 — RtComposite passes true).
        assertEquals(3 + guideCount, atlasBinding,
                "world.rmiss celestialsAtlas sampling " + atlasBinding + " while the pipeline "
                        + "binds the atlas at 3 + GUIDE_COUNT(" + guideCount + ") = "
                        + (3 + guideCount) + " renders the sun/moon discs black");
    }

    @Test
    void cloudSunShadowDoesNotReuseVisibleCloudTrace() throws IOException {
        String source = Files.readString(CLOUDS);
        String body = slice(source, "public float cloudSunShadow", "// ---- Classic");

        assertFalse(body.contains("cloudTrace("),
                "sun visibility must not use the visible-cloud query with camera/view fades");
        assertFalse(body.contains("cloudAlpha("),
                "sun visibility must not inherit visible-cloud alpha fades");
        assertTrue(body.contains("float t = deckRel / lightDir.y;"),
                "cloud shadows must intersect the light ray from the receiver");
        assertTrue(body.contains("push.cloudAnchor.xy + pointRel.xz + lightDir.xz * t"),
                "cloud shadows must sample at the receiver/light intersection, not at the camera");
    }

    @Test
    void directLightingAppliesCloudShadowOnlyAfterSceneVisibilitySurvives() throws IOException {
        String source = Files.readString(WORLD_RGEN);
        String frontNeeBlock = slice(source, "float cloudShadow = 1.0;", "float activeSss");
        String sssBlock = slice(source, "VisibilityResult shadowBack", "// Preserve all local lighting");

        assertInOrder(frontNeeBlock,
                "float3 vis = shadow.transmittance;",
                "if (max(vis.r, max(vis.g, vis.b)) > 0.0) {",
                "cloudShadow = cloudSunShadow(worldPush, hitPos - worldPush.camOffset, lightDir);");
        assertInOrder(sssBlock,
                "float3 visB = shadowBack.transmittance;",
                "if (max(visB.r, max(visB.g, visB.b)) > 0.0) {",
                "if (!cloudShadowReady) {");
    }

    // ---- Volumetric deck model (docs/realistic-volumetric-clouds.md).
    //
    // These guard the parts of the light-transport model that are cheap to lose in a tuning pass and
    // expensive to notice: each one names the artefact that comes back if the assertion fails.

    /**
     * The visible deck and the shadow it casts must read ONE coverage function.
     *
     * <p>They used to be evaluated twice with different inputs — the shadow merged the weather fill in,
     * the density did not — so in rain the deck stayed at the slider's coverage while its shadow closed
     * the sky completely. Nothing but this test stops that from being reintroduced by a "small" edit to
     * either side.
     */
    @Test
    void volumetricDensityAndCloudShadowReadOneCoverageField() throws IOException {
        String source = Files.readString(CLOUDS);
        assertEquals(1, count(source, "float cloudVolumetricCoverage("),
                "the volumetric coverage ramp must be defined exactly once, so the deck and its shadow "
                        + "cannot drift apart");
        assertTrue(slice(source, "float cloudVolumeDensity(WorldPush push", "float cloudSunOpticalDepth(")
                        .contains("cloudVolumetricCoverage(w.coverage, samplePos)"),
                "the visible density must read the shared coverage ramp");
        assertTrue(slice(source, "public float cloudCoverage(WorldPush push", "/** Where a ray meets the deck")
                        .contains("return cloudVolumetricCoverage(retain + (1.0 - retain) * fill, samplePos);"),
                "the shadow query must read the same ramp, weather fill included");
    }

    /**
     * Erosion is sampled from a 3D lattice, and its vertical coordinate is measured from the DECK'S base.
     *
     * <p>Two separate regressions in one test. A 2D pattern times a height profile extrudes one flat
     * picture through the whole depth, so the lobes line up vertically and the crown never breaks into
     * individual heads — the single biggest tell of a procedural deck. And sampling the vertical axis
     * from {@code posRel.y} (camera-relative) instead of from the slab base pins the cloud's internal
     * structure to the EYE, so the deck swims as the camera rises or falls.
     */
    @Test
    void erosionIsThreeDimensionalAndAnchoredToTheDeckBase() throws IOException {
        String source = Files.readString(CLOUDS);
        String density = slice(source, "float cloudVolumeDensity(WorldPush push", "float cloudSunOpticalDepth(");

        assertTrue(source.contains("float cloudHash3(int3 cell)"),
                "the module needs its own 3D lattice hash (math.slang is not imported: it pulls in "
                        + "world_core's bindings)");
        assertTrue(density.contains("cloudBillow3(cloudDetailCoord(warpedXZ, warpedHeight"),
                "erosion must be sampled from the 3D lattice at the displaced position, or the crown "
                        + "stops breaking into cauliflower heads");
        assertTrue(density.contains("float height = hf * slabDepth;"),
                "the vertical noise coordinate must be height above the deck's own base");
        assertFalse(density.contains("posRel.y"),
                "the vertical noise coordinate must never be camera-relative, or the cloud's internal "
                        + "structure swims past the eye as the camera changes altitude");
    }

    /**
     * The fine octave of the erosion FBM must be CELLULAR (Worley F1), not a second billow.
     *
     * <p>Every texture-based cloud implementation erodes with the Perlin-Worley pair: value/billow
     * noise carries the soft rounded lobes while cellular noise carves the crisp scoops between them.
     * Billow-only erosion has smooth boundaries everywhere, which is precisely the "aerated cotton
     * wool" read that separates a procedural deck from a cumulus crown — it is the one asset the
     * technique's write-ups all name, and this module generates it at runtime (an exact 3x3x3 F1 over
     * a jittered lattice, one hash per neighbour) so the mod still ships no 3D texture.
     *
     * <p>Three guards, because all three break silently:
     * <ul>
     *   <li>the fine octave calls it at the fine divisor — otherwise the crown stays billowy;</li>
     *   <li>the jitter stays under one cell — above it the nearest feature point escapes the 3x3x3
     *       neighbourhood and F1 quietly degrades into an approximation with cell-boundary seams;</li>
     *   <li>the raw F1 goes through the fitted remap — the SHAPE tier substitutes this octave's
     *       expected value (0.5) for it, and those two constants are what make 0.5 true. A hand-guessed
     *       pair biases every light probe and drifts the deck's self-shadowing with no compile error.</li>
     * </ul>
     */
    @Test
    void detailErosionIsCellularWorleyWithAMeanMatchedRemap() throws IOException {
        String source = Files.readString(CLOUDS);
        String density =
                slice(source, "float cloudVolumeDensity(WorldPush push", "float cloudSunOpticalDepth(");
        String worley = slice(source, "float cloudWorley3(float3 p) {",
                "// One noise octave's sample coordinate");

        assertTrue(source.contains("uint cloudHash3Bits(int3 cell)"),
                "the Worley lattice needs three jitter components out of ONE hash per neighbour; three "
                        + "hashes per neighbour would triple the most expensive octave in the density");
        assertTrue(density.contains("cloudWorley3(cloudDetailCoord(warpedXZ, warpedHeight"),
                "the fine erosion octave must be the cellular field sampled at the fine divisor, or the "
                        + "crown keeps billow's soft boundaries and never reads as aerated cauliflower");
        assertEquals(3, count(worley, "for (int"),
                "F1 needs the full 3x3x3 neighbourhood, and no more than that");
        assertTrue(worley.contains("+ 0.5 + j - f"),
                "each feature point is its cell's centre plus the jitter, measured against the sample");

        var jitter = java.util.regex.Pattern.compile("CLOUD_WORLEY_JITTER = ([\\d.]+);").matcher(source);
        assertTrue(jitter.find(), "clouds.slang must declare CLOUD_WORLEY_JITTER");
        assertTrue(Double.parseDouble(jitter.group(1)) < 1.0,
                "jitter must stay under one cell per axis, or the nearest feature point escapes the "
                        + "3x3x3 neighbourhood and F1 silently becomes an approximation with seams "
                        + "along the cell boundaries");

        assertTrue(density.contains("* CLOUD_WORLEY_REMAP_SCALE + CLOUD_WORLEY_REMAP_BIAS"),
                "raw F1 averages ~0.51 on this lattice and must be remapped to average 0.5: the SHAPE "
                        + "tier substitutes that octave's expected value for it, so an unfitted remap "
                        + "biases every light probe");
    }

    /**
     * The volumetric deck's depth is the GENUS model's, and the thickness slider is a classic knob.
     *
     * <p>A cloud's own shape deciding how far it develops is most of what separates a cloud from a
     * rectangular slab: a fair-weather cumulus is a few hundred blocks wide and half that deep, an
     * overcast sheet is a shallow lid, a storm tower fills the convective layer. A global thickness
     * fights that at every setting — it is the knob that made the deck read as "a rectangle whose
     * look depends on the slider" — so the volumetric march derives its slab from the same
     * coverage/weather reading that picks the profile, and the classic boxes keep the slider because
     * their extrusion genuinely is it.
     *
     * <p>Four guards: the march overrides the pushed thickness with {@code cloudDeckDepth} before any
     * consumer of it (slab bounds, crossing fade, sigma normalisation) runs; the segment gate can no
     * longer collapse the volumetric deck into the flat sheet at zero thickness; the three genus
     * depths exist and are ordered sheet &lt; heap &lt; tower; and the classic path still reads the
     * pushed value, so the slider did not lose its one real consumer.
     */
    @Test
    void volumetricDepthIsGenusDrivenAndClassicKeepsTheSlider() throws IOException {
        String source = Files.readString(CLOUDS);
        String march = slice(source, "public CloudVolume cloudMarch(",
                "// ---- Opacity as a genuine ceiling");
        String boxes = slice(source, "CloudVolume cloudClassicBoxes(", "// Slab entry/exit along the ray");

        assertTrue(march.contains("thickness = cloudDeckDepth(weather);"),
                "the volumetric march must replace the pushed thickness with the genus depth BEFORE "
                        + "the slab bounds, the crossing fade and the sigma normalisation derive from "
                        + "it, or those four consumers disagree about how deep the deck is");
        assertTrue(source.contains("float cloudDeckDepth(CloudWeather w)"),
                "the deck depth must be one function of the genus state, shared by every consumer");
        double sheet = slangConst(source, "CLOUD_DECK_DEPTH_SHEET");
        double heap = slangConst(source, "CLOUD_DECK_DEPTH_HEAP");
        double tower = slangConst(source, "CLOUD_DECK_DEPTH_TOWER");
        assertTrue(sheet < heap && heap < tower,
                "genus depths must order sheet < heap < tower (got " + sheet + ", " + heap + ", "
                        + tower + "): inverting them makes a storm shallower than fair weather");
        assertTrue(source.contains("if (push.cloudAnchor.z > CLOUD_FLAT_EPSILON || !classic)"),
                "a zero thickness must not collapse the volumetric deck into the flat sheet: the "
                        + "sheet is what the classic slider's zero asks for, and only that");
        assertTrue(boxes.contains("float thickness = max(push.cloudAnchor.z, 1.0);"),
                "the classic boxes are extruded by exactly the pushed thickness — the slider keeps "
                        + "its one real consumer");

        String density =
                slice(source, "float cloudVolumeDensity(WorldPush push", "float cloudSunOpticalDepth(");
        assertTrue(density.contains("hf = hf * lerp(stretch, 1.0, w.sheet);"),
                "each cloud must draw its own vertical development from a low-frequency field, or "
                        + "every cloud in the sky closes its dome at the same fraction of the slab and "
                        + "the deck reads as one population of identical puffs");
        String coverage = slice(source, "float cloudVolumetricCoverage(", "/**\n * Coverage resolved");
        assertTrue(coverage.contains("(mask - 0.5) * CLOUD_COVERAGE_CLUSTER"),
                "the coverage threshold must wander across the sky, so neighbours merge into big "
                        + "masses in one region and shrink to fragments in the next: a single global "
                        + "threshold gives every cloud the same size");
    }

    /**
     * One sample is lit by THREE optical depths through a multi-scattering expansion.
     *
     * <p>Self-shadowing, ambient occlusion and ground bounce are three questions about three different
     * directions; dropping any of them leaves the deck looking like lit cotton wool with a black
     * underside. And without the octave expansion (each bounce order re-evaluating the same light terms
     * with scattering, extinction and phase all relaxed toward isotropic) an optically thick medium
     * renders as a flat grey silhouette — measured cloud optical depth is 12..92, so a photon really does
     * scatter tens of times before it escapes.
     */
    @Test
    void sampleLightingIntegratesThreeOpticalDepthsThroughTheOctaveExpansion() throws IOException {
        String source = Files.readString(CLOUDS);
        String scatter = slice(source, "float3 cloudSampleScatter(WorldPush push",
                "/** Result of a volumetric march");

        assertInOrder(scatter,
                "float sunOD = cloudSunOpticalDepth(",
                "float skyOD = cloudSkyOpticalDepth(",
                "float groundOD = cloudGroundOpticalDepth(",
                "for (int order = 0; order < light.octaves; order++)",
                "CLOUD_MULTI_SCATTER_FALLOFF",
                "CLOUD_MULTI_SCATTER_EXTINCT_FALLOFF",
                "CLOUD_MULTI_SCATTER_PHASE_FALLOFF");
        for (String probe : new String[] {"float cloudSunOpticalDepth(", "float cloudSkyOpticalDepth(",
                "float cloudGroundOpticalDepth("}) {
            assertEquals(1, count(source, probe), probe + " must be defined exactly once");
        }
    }

    /**
     * The thickness slider adds BULK, not opacity.
     *
     * <p>Extinction is per unit length, so without the slab-depth normalisation the total optical depth
     * grows with the deck's depth and the thickness control silently doubles as a second opacity slider
     * — a deep deck goes solid white at the horizon while the opacity slider still says 20%. This is the
     * shader half of the "thickness means grossura, not distance from the ground" requirement.
     */
    @Test
    void thicknessControlsBulkRatherThanOpacity() throws IOException {
        String march = slice(Files.readString(CLOUDS), "public CloudVolume cloudMarch(",
                "// ---- Unified entry point");
        assertTrue(march.contains("* (CLOUD_REFERENCE_THICKNESS / max(thickness, 1.0)) *"),
                "extinction must be normalised by the slab depth, so raising the thickness slider adds "
                        + "volume without making the deck more opaque");
    }

    /**
     * The march start is dithered per pixel AND per frame.
     *
     * <p>A fixed sample pattern puts the truncation error at a fixed place: bands across the deck, rings
     * at its edge, a step in every shadow terminator. Offsetting the start by a hash of the pixel index
     * and the frame counter moves that error somewhere different every frame, which is what lets the
     * temporal denoiser resolve it. Dropping either half of the seed is the usual mistake — pixel-only
     * dither freezes the pattern into static, frame-only dither bands across the screen.
     */
    @Test
    void marchIsDitheredPerPixelAndPerFrame() throws IOException {
        String source = Files.readString(CLOUDS);
        String dither = slice(source, "float cloudDither(WorldPush push)", "float cloudVolumeDensity(");
        assertTrue(dither.contains("DispatchRaysIndex().xy"),
                "the dither must vary per pixel");
        assertTrue(dither.contains("push.frameIndex"),
                "the dither must rotate per frame, or it freezes into visible static");
        assertTrue(slice(source, "public CloudVolume cloudMarch(", "// ---- Unified entry point")
                        .contains("float marchStart = t0 + stepLen * dither;"),
                "the march must actually start at the dithered offset");
    }

    /**
     * Each step deposits the single-scattering albedo times the light the step ABSORBED.
     *
     * <p>For a homogeneous stride the exact integral is {@code S * (sigma_s/sigma_t) * (1 - e^-tau)},
     * which is independent of the stride length. Accumulating {@code S * (1 - T)} without the albedo
     * ratio instead makes the deck's brightness a property of the march resolution, so raising the step
     * count brightens the clouds and a coarse step through thin cloud disagrees with a fine one through
     * thick cloud — the fixed-count version banded for exactly this reason.
     */
    @Test
    void stepIntegralIsEnergyConserving() throws IOException {
        assertInOrder(slice(Files.readString(CLOUDS), "public CloudVolume cloudMarch(",
                        "// ---- Unified entry point"),
                "float sampleTransmittance = exp(-sigmaStep * stepLen);",
                "(sigmaS / max(light.sigmaT, 1.0e-6))",
                "* (1.0 - sampleTransmittance);");
    }

    /**
     * Distant cloud fades INTO the sky rather than being deleted at the view limit.
     *
     * <p>The air between the eye and the deck dims the deck's own scatter and puts sky radiance in its
     * place, which is why real distant clouds lose contrast and take on the horizon's colour. Without
     * this the deck's cutoff is a visible line where cloud stops existing.
     */
    @Test
    void distantDeckFadesIntoTheSkyInsteadOfBeingDeleted() throws IOException {
        assertInOrder(slice(Files.readString(CLOUDS), "public CloudVolume cloudMarch(",
                        "// ---- Unified entry point"),
                "float aerial = CLOUD_AERIAL_STRENGTH",
                "skyBehind * (1.0 - result.transmittance)");
    }

    /**
     * The genus comes from lanes the frame ALREADY pushes, and only when weather lighting is on.
     *
     * <p>A storm's deep grey tower cloud, its dimmed sun and its thickened air must be one reading of one
     * state. Reading the rain lanes unconditionally would make the deck change shape in dimensions and
     * configurations where the rest of the renderer ignores weather, and hand-rolling a separate
     * "storminess" would guarantee the two disagree.
     */
    @Test
    void weatherPicksTheGenusFromTheLanesTheFrameAlreadyPushes() throws IOException {
        String source = Files.readString(CLOUDS);
        String weather = slice(source, "public CloudWeather cloudWeather(WorldPush push)",
                "public float cloudCoverageField(");
        assertInOrder(weather,
                "push.clouds.x",
                "push.cloudColor.w",
                "FEATURE_WEATHER_LIGHTING",
                "push.weather.x",
                "push.weather.y");
        String density = slice(source, "float cloudVolumeDensity(WorldPush push", "float cloudSunOpticalDepth(");
        assertTrue(density.contains("w.sheet") && density.contains("w.convection"),
                "the height profile must be chosen by the genus, or every sky gets the same cloud shape");
    }

    /**
     * The classic style keeps vanilla's flat face shading, and keeps the storm absorption out of it.
     *
     * <p>Classic clouds are meant to look like Minecraft's boxes, not like clouds, so the rework must not
     * leak the volumetric light model into them. The absorption guard is the subtle half: classic already
     * greys in rain through {@code push.cloudColor} (vanilla's own CLOUD_COLOR), so applying the
     * volumetric storm extinction as well would darken the boxes twice for the same weather.
     */
    @Test
    void classicStyleKeepsItsFlatVanillaShading() throws IOException {
        String source = Files.readString(CLOUDS);
        String march = slice(source, "public CloudVolume cloudMarch(", "// ---- Unified entry point");
        assertInOrder(march,
                "float classicFace = 1.0;",
                "inScatter = push.cloudColor.xyz * CLOUD_INV_PI",
                "(sunRadiance * classicFace * shade * 3.0 + skyBehind * 1.4);");
        assertTrue(march.contains(
                        "light.sigmaT = sigma * (classic ? 1.0 : 1.0 + weather.absorbing * CLOUD_STORM_ABSORPTION);"),
                "storm absorption must stay volumetric-only or classic boxes darken twice in rain");
        assertTrue(source.contains("cloudClassicBoxes(push, originRel, dir, maxDistance, ambient)"),
                "the analytic classic box path must still be the one classic clouds take");
    }

    private static String slice(String source, String startNeedle, String endNeedle) {
        int start = source.indexOf(startNeedle);
        assertTrue(start >= 0, "missing shader snippet start: " + startNeedle);
        int end = source.indexOf(endNeedle, start);
        assertTrue(end > start, "missing shader snippet end: " + endNeedle);
        return source.substring(start, end);
    }

    /** Parses a {@code public static const float NAME = ...;} out of clouds.slang. */
    private static double slangConst(String source, String name) {
        var m = java.util.regex.Pattern.compile("static const float " + name + " = ([\\d.]+);")
                .matcher(source);
        assertTrue(m.find(), "clouds.slang must define float " + name);
        return Double.parseDouble(m.group(1));
    }

    private static int count(String source, String needle) {
        int occurrences = 0;
        for (int at = source.indexOf(needle); at >= 0; at = source.indexOf(needle, at + 1)) {
            occurrences++;
        }
        return occurrences;
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
