package dev.comfyfluffy.caustica.rt;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;

import java.util.LinkedHashMap;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** Regression guards for cloud/shadow interactions that are easy to re-break in shader-only changes. */
final class RtCloudShaderRegressionTest {
    private static final Path REPO_ROOT = repoRoot();
    private static final Path CLOUDS = REPO_ROOT.resolve("shaders/world/clouds.slang");
    private static final Path WORLD_RGEN = REPO_ROOT.resolve("shaders/world/world.rgen.slang");
    private static final Path WORLD_RMISS = REPO_ROOT.resolve("shaders/world/world.rmiss.slang");
    private static final Path WORLD_COMMON = REPO_ROOT.resolve("shaders/world/world_common.slang");
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

    // ---- Volumetric deck: procedural shape, genesis-driven depth ---------------------------------
    //
    // The volumetric style is defined by two negative promises as much as by its maths: it reads NO
    // authored shape data, and it takes its depth from NO slider. Both are easy to undo in good faith —
    // the classic deck's clouds.png cell map is right there and is much cheaper than a Worley search,
    // and a "let players tune the volumetric thickness too" change is one line in RtComposite. Each
    // would quietly put the deck back to looking like Minecraft, so each is pinned here.

    /**
     * The volumetric density must be 100% procedural. Not the authored clouds.png bitmap, and not the
     * classic deck's value-noise fallback field either: value noise is precisely what produced the
     * "stretched cubes / bread dough" silhouette this rework exists to remove, because interpolating
     * scalar lattice values gives flat plateaus with the grid visible in the second derivative. Gradient
     * (Perlin) noise gives directional, rounded structure and cellular (Worley) noise gives point
     * extrema — the two together are what a cauliflower crown is made of.
     */
    @Test
    void volumetricDensityIsProceduralGradientAndCellularNoiseOnly() throws IOException {
        String source = Files.readString(CLOUDS);
        String body = slice(source, "// ---- Volumetric cumulus.", "float cloudLightOpticalDepth(");

        assertFalse(body.contains("cloudCellsAddr"),
                "the volumetric deck must not read the authored clouds.png bitmap");
        assertFalse(body.contains("cloudCellOccupied("),
                "the volumetric deck must not read the authored clouds.png bitmap");
        assertFalse(body.contains("cloudCoverageField("),
                "the volumetric deck must not use the classic 12-block value-noise fallback field");
        assertFalse(body.contains("cloudNoise("),
                "value noise is the bread-dough silhouette; the volumetric deck uses gradient noise");
        assertTrue(body.contains("cloudPerlin3("),
                "the cloud body must be 3D gradient noise, or the lobes stay lattice-aligned");
        assertTrue(body.contains("cloudWorley2(") && body.contains("cloudWorley3("),
                "cellular (Worley) erosion is what carves cavities and scalloped edges into the "
                        + "silhouette; without it the deck is a smooth blob");
        assertTrue(body.contains("cloudCoverageVolumetric("),
                "coverage must come from the coarse procedural airmass field");
        assertTrue(body.contains("cloudVariety("),
                "per-cloud variety is what stops every cloud of a genus being the same cloud");
    }

    /**
     * The volumetric deck's depth comes from the genesis model, and the Cloud Thickness slider must not
     * reach it. The classic branch must keep reading the slider — the two styles answer "how deep" from
     * different places by design, and collapsing them back together is the regression this pins.
     */
    @Test
    void volumetricDepthIsGenesisDrivenAndTheThicknessSliderIsClassicOnly() throws IOException {
        String cloudState = slice(Files.readString(RT_COMPOSITE),
                "private CloudPush cloudState(", "private static Float4 cloudColorState(");
        String volumetric = slice(cloudState,
                "cloudStyleIndex() == CLOUD_STYLE_VOLUMETRIC) {", "} else {");
        String classic = slice(cloudState,
                "genesis = RtCloudGenesis.fromDevelopment(", "float deckCentre");

        assertTrue(volumetric.contains("RtCloudGenesis.resolve("),
                "the volumetric deck's depth must come from the genesis model");
        assertFalse(volumetric.contains("CLOUD_THICKNESS"),
                "the Cloud Thickness slider must have no effect on the volumetric deck");
        assertTrue(classic.contains("CLOUD_THICKNESS"),
                "the classic deck must still take its depth from the Cloud Thickness slider");

        // The shader normalises its vertical profile against the SLAB (cloudAnchor.z) and grades crown
        // heights against the DECK (cloudGenus.x), trusting that the slab is deck * tower. Publishing
        // either from anywhere else would clip towers at the top of their own slab.
        assertTrue(volumetric.contains("thickness = genesis.slabDepth();"),
                "the slab pushed as cloudAnchor.z must be RtCloudGenesis.slabDepth()");
        assertInOrder(cloudState,
                "new Float4(genesis.deckDepth(), genesis.towerScale(), genesis.turbulence(),",
                "genesis.genus()));");
        assertTrue(cloudState.contains("sky.sunDir().y()"),
                "insolation must come from the same sun the sky is lit by, not from a hardcoded clock");
    }

    /**
     * {@code cloudGenus} must be the trailing field of {@code WorldPush}, and {@code clouds.genus()} the
     * trailing argument of the generated {@code WorldPushData} constructor. The serializer is reflected
     * out of the Slang struct, so field order IS the ABI: a lane inserted anywhere but last silently
     * shifts every field after it, and the push then writes each value into its neighbour's slot.
     */
    @Test
    void cloudGenusIsTheTrailingWorldPushLane() throws IOException {
        String common = Files.readString(WORLD_COMMON);
        String genusField = "public float4   cloudGenus;";
        int fogTint = common.indexOf("public float4   fogTint;");
        int genus = common.indexOf(genusField);
        assertTrue(fogTint >= 0, "world_common must still declare the fogTint lane");
        assertTrue(genus >= 0, "world_common must declare the cloudGenus lane");
        assertTrue(genus > fogTint, "cloudGenus must be declared after fogTint");
        // The "nothing after it" scan starts at the END of the declaration. Starting at its first
        // character finds the "public " of cloudGenus itself and reports the lane as never last.
        int afterGenus = genus + genusField.length();
        int endOfStruct = common.indexOf("};", afterGenus);
        assertTrue(endOfStruct > afterGenus, "cloudGenus must be declared inside the WorldPush struct");
        assertFalse(common.substring(afterGenus, endOfStruct).contains("public "),
                "cloudGenus must be the LAST field of WorldPush — the generated serializer is reflected "
                        + "from field order, so anything after it shifts the whole tail of the ABI");

        assertInOrder(Files.readString(RT_COMPOSITE),
                "fogTint(),", "clouds.genus()", ").write(push);");
    }

    // ---- The periodicity contract ------------------------------------------------------------------

    /**
     * The anchor wrap must be a whole number of EVERY period the deck is sampled in, in both styles, at
     * once. This is the bug class the volumetric field has already had twice — a non-power-of-two octave
     * scale, or a new lattice that does not divide the wrap, lands the anchor mid-period and the whole
     * cloudscape snaps to a different pattern while the player walks. It compiles cleanly, it renders
     * cleanly for 786431 blocks, and then the sky teleports.
     *
     * <p>Both sides are parsed rather than trusted, so adding an octave with a bad lattice size fails CI
     * instead of surfacing as a shape pop nobody can reproduce.
     */
    @Test
    void anchorWrapIsAWholeNumberOfEveryFieldPeriod() throws IOException {
        String slang = Files.readString(CLOUDS);
        String composite = Files.readString(RT_COMPOSITE);
        double wrap = productOf(javaConstant(composite, "double", "CLOUD_FIELD_PERIOD_BLOCKS"));
        double viewLimit = Double.parseDouble(
                javaConstant(composite, "float", "CLOUD_VIEW_LIMIT_BLOCKS"));

        int periodCells = intConstant(slang, "CLOUD_PERIOD_CELLS");
        int cellMapCells = intConstant(slang, "CLOUD_CELL_MAP_CELLS");
        double cellBlocks = floatConstant(slang, "CLOUD_CELL_BLOCKS");
        double latticeMax = floatConstant(slang, "CLOUD_LATTICE_MAX_BLOCKS");

        double volumetricPeriod = periodCells * latticeMax;
        assertEquals(0.0, wrap % volumetricPeriod, 1.0e-6,
                "the anchor wrap must be a whole number of the volumetric field's coarsest period");
        assertEquals(0.0, wrap % (cellMapCells * cellBlocks), 1.0e-6,
                "the anchor wrap must be a whole number of the classic cell map's 3072-block period");
        assertEquals(0.0, wrap % (periodCells * cellBlocks), 1.0e-6,
                "the anchor wrap must be a whole number of the classic noise fallback's period");
        assertTrue(wrap >= 64.0 * viewLimit,
                "the wrap (" + wrap + ") must stay far larger than the deck's own view limit ("
                        + viewLimit + "), or the repeat becomes visible inside one frame");

        // Every lattice the field is sampled at must be a power of two dividing the coarsest one. That
        // is what makes a single wrap satisfy all the octaves simultaneously, and what keeps every one
        // of these multiplies exact in binary floating point.
        Map<String, Double> lattices = floatConstants(slang, "LATTICE");
        assertFalse(lattices.isEmpty(), "no CLOUD_*LATTICE* constants found in " + CLOUDS);
        for (Map.Entry<String, Double> entry : lattices.entrySet()) {
            double lattice = entry.getValue();
            long cells = Math.round(lattice);
            assertTrue(lattice > 0.0 && cells == (long) lattice && (cells & (cells - 1)) == 0L,
                    entry.getKey() + " = " + lattice + " must be a power of two, so that every octave's "
                            + "period divides the same anchor wrap exactly");
            assertEquals(0.0, latticeMax % lattice, 1.0e-6,
                    entry.getKey() + " must divide CLOUD_LATTICE_MAX_BLOCKS, or the anchor wrap is not a "
                            + "whole period in that octave and the sky pops at every wrap");
            assertEquals(0.0, wrap % (periodCells * lattice), 1.0e-6,
                    "the anchor wrap must be a whole number of " + entry.getKey() + "'s own period");
        }
    }

    // ---- Volumetric lighting ------------------------------------------------------------------------

    /**
     * The march must integrate Beer-Lambert extinction on BOTH paths (the eye march and the light
     * march), and the light march must return an OPTICAL DEPTH rather than a finished transmittance so
     * each style can apply its own law to it: the classic boxes take a plain exponential and damp it,
     * because vanilla's clouds are opaque and must not grow a translucent rim or an internal gradient,
     * while the volumetric deck takes the multiple-scattering octave and the powder term. Folding the
     * law into the light march — the obvious refactor — would blur the two styles back together.
     *
     * <p>The powder term must read local DENSITY. Reading the step's optical depth instead is the
     * tempting version and is a discretisation bug: the march picks its step length from the path
     * distance, so the same wisp would shade differently depending on how far away it is.
     */
    @Test
    void volumetricLightingIsBeerLambertWithAPowderTermAppliedByTheCaller() throws IOException {
        String source = Files.readString(CLOUDS);
        String light = slice(source, "float cloudLightOpticalDepth(", "public struct CloudVolume {");
        String march = slice(source, "public CloudVolume cloudMarch(", "// ---- Unified entry point");

        assertTrue(light.contains("return optical;"),
                "the light march must return raw optical depth, not a transmittance");
        assertTrue(light.contains("cloudVolumeDensity(") && light.contains(", false)"),
                "the light march must sample the cheap density tier — resolving billows on a "
                        + "low-frequency shadow signal multiplies the cost for nothing visible");
        assertInOrder(march,
                "float sigmaMedium = CLOUD_EXTINCTION",
                "float sigma = sigmaMedium * fade * crossFade;",
                "float sampleTransmittance = exp(-extinction);",
                "lerp(1.0, cloudBeerLambert(tau), 0.4)",
                "cloudBeerLambert(tau * CLOUD_LIGHT_EXTINCTION_SCALE)",
                "cloudPowder(density)");
        assertFalse(light.contains("* fade"),
                "the light march must not carry the view-dependent fades: a cloud's shadow on itself "
                        + "cannot depend on where the camera is");
        assertTrue(march.contains("cloudPowder(density)"),
                "the powder term must read local density, not the step's optical depth — stepLen is "
                        + "chosen from the path length, so shading by it makes a cloud's brightness "
                        + "depend on how far away it is");
        assertTrue(Files.readString(CLOUDS).contains("float cloudBeerLambert(float tau) {\n"
                        + "    return exp(-max(tau, 0.0));"),
                "the light path must be a plain Beer-Lambert exponential: every bell-shaped "
                        + "\"beer's powder\" variant tends to zero at tau=0, which paints a dark band "
                        + "across the sunlit crown of every cloud");
    }

    /** The Java-side value of a {@code NAME = a * b * c;} constant, as a product of literals. */
    private static double productOf(String expression) {
        double product = 1.0;
        boolean any = false;
        for (String part : expression.split("\\*")) {
            String trimmed = part.trim();
            if (trimmed.isEmpty()) {
                continue;
            }
            product *= Double.parseDouble(trimmed);
            any = true;
        }
        assertTrue(any, "no numeric product in constant expression: " + expression);
        return product;
    }

    private static String javaConstant(String java, String type, String name) {
        Matcher matcher = Pattern.compile(
                "static\\s+final\\s+" + type + "\\s+" + name + "\\s*=\\s*([^;]+);").matcher(java);
        assertTrue(matcher.find(), "missing Java constant: " + type + " " + name);
        return matcher.group(1).replace("f", "").trim();
    }

    private static int intConstant(String slang, String name) {
        Matcher matcher = Pattern.compile(
                "static\\s+const\\s+int\\s+" + name + "\\s*=\\s*(\\d+)\\s*;").matcher(slang);
        assertTrue(matcher.find(), "missing Slang int constant: " + name);
        return Integer.parseInt(matcher.group(1));
    }

    private static double floatConstant(String slang, String name) {
        Matcher matcher = Pattern.compile(
                "static\\s+const\\s+float\\s+" + name + "\\s*=\\s*([0-9.]+)\\s*;").matcher(slang);
        assertTrue(matcher.find(), "missing Slang float constant: " + name);
        return Double.parseDouble(matcher.group(1));
    }

    /** Every {@code CLOUD_*LATTICE*} float constant in the shader, keyed by name. */
    private static Map<String, Double> floatConstants(String slang, String nameFragment) {
        Map<String, Double> found = new LinkedHashMap<>();
        Matcher matcher = Pattern.compile(
                "static\\s+const\\s+float\\s+(CLOUD_\\w*" + nameFragment + "\\w*)\\s*=\\s*([0-9.]+)\\s*;")
                .matcher(slang);
        while (matcher.find()) {
            found.put(matcher.group(1), Double.parseDouble(matcher.group(2)));
        }
        return found;
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
