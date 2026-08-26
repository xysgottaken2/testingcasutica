package dev.comfyfluffy.caustica.rt;

import org.junit.jupiter.api.Test;

import java.util.random.RandomGenerator;
import java.util.random.RandomGeneratorFactory;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** CPU reference checks for the bounded reservoir math implemented in lighting.slang. */
final class RestirReservoirMathTest {
    private static final double MAX_M = 16.0;
    private static final double MAX_W = 16.0;
    private static final double MIN_PHAT = 1.0e-4;
    private static final double MAX_SAMPLE_LUMINANCE = 16.0;
    private static final double JACOBIAN_MIN = 0.2;
    private static final double JACOBIAN_MAX = 5.0;

    @Test
    void mergedReservoirCarriesEffectiveSamplesButNeverExceedsHardMCap() {
        Reservoir destination = new Reservoir(8.0, 12.0, 2.0);

        // The source asks to contribute M=16, but only 8 fit below the hard M=16 cap. Its current
        // receiver weight is pHat * W * acceptedM: 3 * 0.5 * 8 = 12.
        merge(destination, 16.0, 0.5, 3.0, 0.0);

        assertEquals(MAX_M, destination.m, 0.0);
        assertEquals(24.0, destination.weightSum, 1.0e-12);
        assertEquals(3.0, destination.selectedTarget, 1.0e-12);
        double finalW = finalizeWeight(destination.weightSum,
                destination.m, destination.selectedTarget);
        assertEquals(destination.weightSum / destination.m,
                finalW * destination.selectedTarget, 1.0e-12);
    }

    @Test
    void historyMAndFinalWeightStayBounded() {
        Reservoir capped = new Reservoir(8.0, 1.0, 1.0);
        for (int i = 0; i < 20; i++) {
            merge(capped, 100.0, 1000.0, 1000.0, 0.5);
        }
        assertEquals(MAX_M, capped.m, 0.0);

        assertEquals(0.0, finalizeWeight(1000.0, MAX_M, MIN_PHAT * 0.5), 0.0,
                "near-zero p-hat must be discarded");
        assertEquals(1.0, finalizeWeight(1.0e9, MAX_M, MAX_SAMPLE_LUMINANCE), 0.0,
                "single-sample luminance clamp must be tighter than MAX_W here");
        assertTrue(finalizeWeight(1.0e9, MAX_M, 0.5) <= MAX_W);
    }

    @Test
    void sameEmitterKeepsTheOlderSampleAndDoesNotStochasticReplace() {
        Reservoir destination = new Reservoir(4.0, 8.0, 2.0);
        destination.packedLe = 0xABCD;
        destination.age = 0;
        Reservoir source = new Reservoir(24.0, 0.0, 2.0);
        source.packedLe = 0xABCD;
        source.age = 12;
        source.w = 0.5;
        mergeSticky(destination, source, 2.0, 0.88, 0.99);
        assertEquals(0xABCD, destination.packedLe);
        assertEquals(13, destination.age);
        assertEquals(MAX_M, destination.m, 0.0);
        assertEquals(2.0, destination.selectedTarget, 1.0e-12);
    }

    @Test
    void stickinessBiasesAgainstSwitchingEmitters() {
        int switches = 0;
        int trials = 20_000;
        for (int i = 0; i < trials; i++) {
            Reservoir destination = new Reservoir(8.0, 48.0, 2.0);
            destination.packedLe = 1;
            Reservoir source = new Reservoir(4.0, 0.0, 2.2);
            source.packedLe = 2;
            source.w = 1.0;
            // Incoming weight 2.2 * 1 * 4 = 8.8 against a destination stream of 48. Without
            // stickiness the switch chance is 8.8/56.8 ≈ 15%; stickiness 0.88 multiplies the keep
            // bar by 8.04, so switches become rare.
            mergeSticky(destination, source, 2.2, 0.88, (i + 0.5) / trials);
            if (destination.packedLe == 2) {
                switches++;
            }
        }
        assertTrue(switches < trials / 20,
                "sticky merge must almost never hop to a slightly brighter different emitter, got "
                        + switches);
    }

    @Test
    void sameLightTemporalWBlendsTowardHistory() {
        double previousW = 4.0;
        double currentW = 6.0;
        double blend = 0.12;
        double blended = previousW * (1.0 - blend) + currentW * blend;
        assertEquals(4.24, blended, 1.0e-12);
        assertTrue(blended < currentW);
        assertTrue(Math.abs(blended - previousW) < Math.abs(currentW - previousW));
    }

    @Test
    void jacobianValidationRejectsDisocclusionAndNonFiniteTransfers() {
        assertTrue(validJacobian(1.0, 1.0));
        assertTrue(validJacobian(1.0, JACOBIAN_MIN));
        assertTrue(validJacobian(1.0, JACOBIAN_MAX));
        assertFalse(validJacobian(1.0, 0.19));
        assertFalse(validJacobian(1.0, 5.01));
        assertFalse(validJacobian(0.0, 1.0));
        assertFalse(validJacobian(1.0, Double.NaN));
        assertFalse(validJacobian(1.0, Double.POSITIVE_INFINITY));
    }

    @Test
    void streamingSelectionStillMatchesBoundedResamplingWeights() {
        RandomGenerator random = RandomGeneratorFactory.of("L64X128MixRandom").create(0x5eedL);
        int sourceWins = 0;
        int trials = 200_000;
        for (int i = 0; i < trials; i++) {
            // Existing stream weight 2, incoming bounded source weight 6 -> probability 6 / 8.
            Reservoir r = new Reservoir(1.0, 2.0, 2.0);
            merge(r, 1.0, 2.0, 3.0, random.nextDouble());
            if (r.selectedTarget == 3.0) {
                sourceWins++;
            }
        }
        assertTrue(Math.abs(sourceWins / (double) trials - 0.75) < 0.005);
    }

    private static void merge(Reservoir destination, double sourceM, double sourceW,
                              double targetAtCurrentReceiver, double uniformRandom) {
        double acceptedM = Math.min(sourceM, Math.max(0.0, MAX_M - destination.m));
        double safeW = Math.min(sourceW, MAX_W);
        if (!(acceptedM > 0.0 && safeW > 0.0)
                || !(targetAtCurrentReceiver >= MIN_PHAT)) {
            return;
        }
        double safeTarget = Math.min(targetAtCurrentReceiver, MAX_SAMPLE_LUMINANCE);
        double weight = safeTarget * safeW * acceptedM;
        destination.m = Math.min(destination.m + acceptedM, MAX_M);
        destination.weightSum += weight;
        if (uniformRandom * destination.weightSum < weight) {
            destination.selectedTarget = safeTarget;
        }
    }

    /**
     * CPU mirror of lighting.slang restirMerge with stickiness. {@code source.w} is the finalized
     * source W; {@code source.m} is the source M (before the destination's remaining-M cap).
     */
    private static void mergeSticky(Reservoir destination, Reservoir source,
                                    double targetAtCurrentReceiver, double stickiness,
                                    double uniformRandom) {
        double acceptedM = Math.min(source.m, Math.max(0.0, MAX_M - destination.m));
        double safeW = Math.min(source.w, MAX_W);
        if (!(acceptedM > 0.0 && safeW > 0.0)
                || !(targetAtCurrentReceiver >= MIN_PHAT)) {
            return;
        }
        double safeTarget = Math.min(targetAtCurrentReceiver, MAX_SAMPLE_LUMINANCE);
        double weight = safeTarget * safeW * acceptedM;
        boolean same = destination.packedLe != 0 && destination.packedLe == source.packedLe;
        destination.m = Math.min(destination.m + acceptedM, MAX_M);
        destination.weightSum += weight;
        if (same) {
            if (source.age >= destination.age) {
                destination.selectedTarget = safeTarget;
                destination.packedLe = source.packedLe;
                destination.age = Math.min(source.age + 1, 60);
            } else {
                destination.age = Math.min(destination.age + 1, 60);
            }
            return;
        }
        double keepBias = 1.0 + Math.min(1.0, Math.max(0.0, stickiness)) * 8.0;
        if (uniformRandom * destination.weightSum * keepBias < weight) {
            destination.selectedTarget = safeTarget;
            destination.packedLe = source.packedLe;
            destination.age = Math.min(source.age + 1, 60);
        }
    }

    private static double finalizeWeight(double weightSum, double m, double selectedTarget) {
        if (!(selectedTarget >= MIN_PHAT && m > 0.0)) {
            return 0.0;
        }
        double rawW = weightSum / (m * selectedTarget);
        return rawW > 0.0
                ? Math.min(rawW, Math.min(MAX_W, MAX_SAMPLE_LUMINANCE / selectedTarget))
                : 0.0;
    }

    private static boolean validJacobian(double sourceGeometry, double currentGeometry) {
        if (!(sourceGeometry > 0.0 && currentGeometry > 0.0)) {
            return false;
        }
        double jacobian = currentGeometry / sourceGeometry;
        return jacobian >= JACOBIAN_MIN && jacobian <= JACOBIAN_MAX;
    }

    private static final class Reservoir {
        private double m;
        private double weightSum;
        private double selectedTarget;

        private Reservoir(double m, double weightSum, double selectedTarget) {
            this.m = m;
            this.weightSum = weightSum;
            this.selectedTarget = selectedTarget;
        }
    }
}
