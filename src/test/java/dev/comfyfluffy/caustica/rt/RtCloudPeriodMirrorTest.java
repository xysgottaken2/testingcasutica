package dev.comfyfluffy.caustica.rt;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Guards the cloud field's wrap identity — the one invariant that is invisible until it breaks, and
 * which has broken twice.
 *
 * <p>{@code RtComposite} pushes a cloud sample anchor reduced modulo {@code CLOUD_FIELD_PERIOD_BLOCKS},
 * because the wind scroll grows without bound with world time and because the anchor has to stay a small
 * float far from a world border's 30M-block coordinates. That wrap is only seamless if the period is a
 * whole number of repeats in <em>every</em> space the shader samples its hash lattice in — the coverage
 * octaves, the turbulent displacement, and both 3D erosion octaves, each of which divides the cell size
 * by its own factor. Get one wrong and the entire cloudscape snaps to a different pattern as the anchor
 * rolls over: clouds visibly change shape while the player walks.
 *
 * <p>Both of the previous breaks were a divisor that was not a power of two (0.9 and 0.35), which makes
 * the per-octave repeat a non-integer number of periods, so no wrap distance can ever satisfy it. This
 * reads the shader's constants and the Java formula and re-derives the identity from both sides, so a
 * future tuning pass that changes an octave scale fails CI instead of teleporting the sky.
 */
final class RtCloudPeriodMirrorTest {
    private static final Path REPO_ROOT = repoRoot();
    private static final Path CLOUDS = REPO_ROOT.resolve("shaders/world/clouds.slang");
    private static final Path RT_COMPOSITE =
            REPO_ROOT.resolve("src/main/java/dev/comfyfluffy/caustica/rt/RtComposite.java");

    /** Every octave divisor the volumetric field is sampled through, as named in clouds.slang. */
    private static final String[] DIVISORS = {
            "CLOUD_SHAPE_DIV", "CLOUD_WARP_DIV", "CLOUD_BILLOW_DIV_COARSE", "CLOUD_BILLOW_DIV_FINE",
    };

    @Test
    void fieldPeriodIsAWholeNumberOfRepeatsInEverySampledSpace() throws IOException {
        String slang = Files.readString(CLOUDS);
        String composite = Files.readString(RT_COMPOSITE);

        double cells = slangInt(slang, "CLOUD_PERIOD_CELLS");
        double cellBlocks = slangFloat(slang, "CLOUD_CELL_BLOCKS");
        double scale = slangFloat(slang, "CLOUD_VOLUMETRIC_SCALE");

        double maxDivisor = 0.0;
        for (String name : DIVISORS) {
            double divisor = slangFloat(slang, name);
            assertTrue(divisor > 0.0, name + " must be positive");
            assertTrue(isPowerOfTwo(divisor),
                    name + " = " + divisor + " is not a power of two, so the hash lattice it samples has "
                            + "a repeat that is not a whole number of field periods and NO wrap distance "
                            + "can make the deck seamless — the cloudscape snaps to a different pattern "
                            + "when the anchor rolls over (this is how the 0.9 and 0.35 divisors broke it)");
            maxDivisor = Math.max(maxDivisor, divisor);
        }

        double expected = cells * cellBlocks * maxDivisor / scale;
        double pushed = javaPeriod(composite);
        assertEquals(expected, pushed, 1.0e-9,
                "RtComposite.CLOUD_FIELD_PERIOD_BLOCKS must equal 512 cells * 12 blocks * maxDivisor("
                        + maxDivisor + ") / scale(" + scale + ") = " + expected
                        + "; a shorter period wraps mid-octave and a longer one is wasted precision");

        // The largest divisor's repeat IS the period; every smaller octave must divide it exactly too, or
        // that layer alone desyncs at the wrap (the second break: base field fixed, detail layers not).
        for (String name : DIVISORS) {
            double divisor = slangFloat(slang, name);
            double repeat = cells * cellBlocks * divisor / scale;
            double wraps = pushed / repeat;
            assertEquals(Math.rint(wraps), wraps, 1.0e-9,
                    name + " repeats every " + repeat + " blocks, which does not divide the "
                            + pushed + "-block field period a whole number of times");
        }
    }

    @Test
    void verticalLatticeCannotRepeatInsideTheDeck() throws IOException {
        String slang = Files.readString(CLOUDS);
        String composite = Files.readString(RT_COMPOSITE);

        double cells = slangInt(slang, "CLOUD_VERTICAL_CELLS");
        assertTrue(isPowerOfTwo(cells),
                "CLOUD_VERTICAL_CELLS must be a power of two so CLOUD_VERTICAL_MASK is a clean mask");
        double cellBlocks = slangFloat(slang, "CLOUD_CELL_BLOCKS");
        double scale = slangFloat(slang, "CLOUD_VOLUMETRIC_SCALE");

        // The finest octave has the smallest cell in blocks, so it is the one that could repeat first.
        double finest = Double.MAX_VALUE;
        for (String name : DIVISORS) {
            finest = Math.min(finest, slangFloat(slang, name));
        }
        double verticalCellBlocks = cellBlocks * finest / scale;
        double verticalPeriod = cells * verticalCellBlocks;

        Matcher thickness = Pattern
                .compile("CLOUD_MAX_THICKNESS_BLOCKS\\s*=\\s*([0-9.]+)f\\s*;")
                .matcher(composite);
        assertTrue(thickness.find(), "RtComposite must define CLOUD_MAX_THICKNESS_BLOCKS");
        double maxDepth = Double.parseDouble(thickness.group(1));

        // The vertical axis has no anchor to wrap (height is measured from the deck's own base), so the
        // mask exists only to keep the cell index small. It must still be far coarser than the deck, or
        // the erosion pattern would visibly repeat inside one cloud — the same artefact as a bad
        // horizontal wrap, but stacked vertically through the slab.
        assertTrue(verticalPeriod >= maxDepth * 4.0,
                "the vertical hash lattice repeats every " + verticalPeriod + " blocks, which is not at "
                        + "least four times the deepest deck RtComposite can push (" + maxDepth
                        + " blocks): the 3D erosion would tile visibly inside a single cloud");
    }

    @Test
    void hashMasksAreOneLessThanTheirPeriod() throws IOException {
        String slang = Files.readString(CLOUDS);
        // Both masks are written as period-1 rather than as a literal, so the period and the mask cannot
        // drift apart; assert the source says exactly that.
        assertTrue(slang.contains("CLOUD_CELL_MASK = CLOUD_PERIOD_CELLS - 1;"),
                "CLOUD_CELL_MASK must be derived from CLOUD_PERIOD_CELLS, not written as a literal");
        assertTrue(slang.contains("CLOUD_VERTICAL_MASK = CLOUD_VERTICAL_CELLS - 1;"),
                "CLOUD_VERTICAL_MASK must be derived from CLOUD_VERTICAL_CELLS, not written as a literal");
        assertTrue(isPowerOfTwo(slangInt(slang, "CLOUD_PERIOD_CELLS")),
                "CLOUD_PERIOD_CELLS must be a power of two for the mask to be a wrap at all");
    }

    /**
     * Evaluates {@code CLOUD_FIELD_PERIOD_BLOCKS} from its written-out product rather than from a
     * hard-coded expectation, so the test reads the same four numbers the shader's identity is built
     * from and cannot itself go stale.
     */
    private static double javaPeriod(String composite) {
        Matcher m = Pattern.compile(
                "CLOUD_FIELD_PERIOD_BLOCKS\\s*=\\s*([0-9.]+)\\s*\\*\\s*([0-9.]+)\\s*\\*\\s*([0-9.]+)"
                        + "\\s*/\\s*([0-9.]+)\\s*;")
                .matcher(composite);
        assertTrue(m.find(),
                "RtComposite must define CLOUD_FIELD_PERIOD_BLOCKS as cells * cellBlocks * maxDivisor"
                        + " / scale, written out so this test can read each factor");
        return Double.parseDouble(m.group(1)) * Double.parseDouble(m.group(2))
                * Double.parseDouble(m.group(3)) / Double.parseDouble(m.group(4));
    }

    private static double slangFloat(String slang, String name) {
        Matcher m = Pattern.compile("static\\s+const\\s+float\\s+" + name + "\\s*=\\s*([0-9.]+)\\s*;")
                .matcher(slang);
        assertTrue(m.find(), "clouds.slang must define float " + name);
        return Double.parseDouble(m.group(1));
    }

    private static double slangInt(String slang, String name) {
        Matcher m = Pattern.compile("static\\s+const\\s+int\\s+" + name + "\\s*=\\s*([0-9]+)\\s*;")
                .matcher(slang);
        assertTrue(m.find(), "clouds.slang must define int " + name);
        return Double.parseDouble(m.group(1));
    }

    /** True for exactly the values whose binary representation is a single 1 bit, fractions included. */
    private static boolean isPowerOfTwo(double value) {
        if (value <= 0.0 || !Double.isFinite(value)) {
            return false;
        }
        // Scale by the value's own exponent: a power of two lands exactly on 1.0, anything with a
        // mantissa (0.9 -> 1.8, 0.35 -> 1.4, 12.0 -> 1.5) does not.
        return Math.scalb(value, -Math.getExponent(value)) == 1.0;
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
