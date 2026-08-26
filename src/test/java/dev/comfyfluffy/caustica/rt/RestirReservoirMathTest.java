package dev.comfyfluffy.caustica.rt;

import org.junit.jupiter.api.Test;

import java.util.random.RandomGenerator;
import java.util.random.RandomGeneratorFactory;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** CPU reference checks for the bounded reservoir math implemented in lighting.slang. */
final class RestirReservoirMathTest {
    private static final double MAX_M = 24.0;
    private static final double MAX_W = 16.0;
    private static final double MIN_PHAT = 1.0e-4;
    private static final double MAX_SAMPLE_LUMINANCE = 24.0;
    private static final double JACOBIAN_MIN = 0.2;
    private static final double JACOBIAN_MAX = 5.0;

    @Test
    void mergedReservoirCarriesEffectiveSamplesButNeverExceedsHardMCap() {
        Reservoir destination = new Reservoir(8.0, 12.0, 2.0);

        // The source contributes all M=16 below the configured M=24 cap. Its current receiver
        // weight is pHat * W * acceptedM: 3 * 0.5 * 16 = 24.
        merge(destination, 16.0, 0.5, 3.0, 0.0);

        assertEquals(MAX_M, destination.m, 0.0);
        assertEquals(36.0, destination.weightSum, 1.0e-12);
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

    @Test
    void sameRepresentativeControlDifferenceSurvivesAChangedFinalWeight() {
        // The final ReSTIR weight doubled from source W=2 to W=4, so a current contribution of 6
        // corresponds to 3 at the source weight. If that same representative contributed 3 at the
        // source, current-minus-source is zero and the accumulated estimate remains exactly 10.
        assertEquals(10.0, controlTransfer(10.0, 3.0, 6.0, 2.0, 4.0), 0.0);

        // A genuine change in the same representative is transferred onto the accumulated estimate.
        assertEquals(12.0, controlTransfer(10.0, 3.0, 10.0, 2.0, 4.0), 0.0);
    }

    @Test
    void confidenceWeightedResolveStaysBetweenCurrentAndTransferredEstimates() {
        assertEquals(8.0, confidenceResolve(4.0, 12.0, 1.0, 1.0), 0.0);
        assertEquals(11.0, confidenceResolve(4.0, 12.0, 7.0, 1.0), 0.0);
        assertEquals(4.0, confidenceResolve(4.0, 12.0, 64.0, 0.0), 0.0,
                "zero ReSTCV strength must reproduce legacy ReSTIR");
    }

    @Test
    void commonContributionBoundAlsoProtectsIndependentRis() {
        assertEquals(24.0, boundContribution(1000.0, 24.0), 0.0);
        assertEquals(7.0, boundContribution(7.0, 24.0), 0.0);
        assertEquals(0.0, boundContribution(Double.NaN, 24.0), 0.0);
        assertEquals(0.0, boundContribution(-4.0, 24.0), 0.0);
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

    private static double finalizeWeight(double weightSum, double m, double selectedTarget) {
        if (!(selectedTarget >= MIN_PHAT && m > 0.0)) {
            return 0.0;
        }
        double rawW = weightSum / (m * selectedTarget);
        return rawW > 0.0
                ? Math.min(rawW, Math.min(MAX_W, MAX_SAMPLE_LUMINANCE / selectedTarget))
                : 0.0;
    }

    private static double controlTransfer(double sourceEstimate, double sourceRepresentative,
                                          double currentAtFinalWeight, double sourceW, double finalW) {
        double currentAtSourceWeight = currentAtFinalWeight * sourceW / finalW;
        return sourceEstimate + currentAtSourceWeight - sourceRepresentative;
    }

    private static double confidenceResolve(double current, double transfer,
                                            double confidence, double strength) {
        double weight = confidence * strength;
        return (current + weight * transfer) / (1.0 + weight);
    }

    private static double boundContribution(double contribution, double limit) {
        if (!Double.isFinite(contribution)) {
            return 0.0;
        }
        return Math.min(Math.max(contribution, 0.0), limit);
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
