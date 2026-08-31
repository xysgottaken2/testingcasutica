package dev.comfyfluffy.caustica;

import org.junit.jupiter.api.Test;

import java.nio.file.Files;
import java.nio.file.Path;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Guards the semantics the settings UI's "Reset to Defaults" buttons are built on.
 *
 * <p>Every Caustica sub-screen starts with a per-page reset row and the hub with a global one, all of
 * them implemented as {@link CausticaConfig.RuntimeSetting#resetToDefault()} over a settings list. If a
 * future setting quietly stopped snapping back to its factory value — especially an angle setting whose
 * {@code set()} consumes degrees while the stored default is already radians — every Reset button would
 * lie to the player, so the contract is pinned here for every registered setting.
 */
final class RtConfigDefaultsTest {

    @Test
    void settingsRegistryIsPopulated() {
        assertFalse(CausticaConfig.settings().isEmpty(),
                "the settings registry must not be empty: the UI resets iterate it");
    }

    /**
     * The config file outlives any single build: a leftover entry of the wrong type (a numeric fog
     * amount under {@code composite.fog} written by an experimental build, say) must never crash
     * startup with a {@link ClassCastException}. The file readers interpret foreign types (a
     * non-zero number is true, a boolean is 0/1) and let the next save rewrite the entry — this
     * pins that contract so the blind casts cannot quietly come back.
     */
    @Test
    void configFileReadersTolerateForeignTypedEntries() throws Exception {
        String source = Files.readString(repoRoot().resolve(
                "src/main/java/dev/comfyfluffy/caustica/CausticaConfig.java"));

        assertFalse(source.contains("FILE.<Boolean>get(") || source.contains("FILE.<Number>get(")
                        || source.contains("FILE.<String>get("),
                "config file reads must go through the type-tolerant readers, not blind casts");
        assertTrue(source.contains("number.doubleValue() != 0.0"),
                "a numeric entry under a boolean path reads as non-zero-is-true instead of crashing");
        assertTrue(source.contains("bool ? 1 : 0"),
                "a boolean entry under a numeric path reads as 0/1 instead of crashing");
    }

    /**
     * Walk up from the working directory to the directory that holds both {@code shaders} and
     * {@code src}, so the test works whether Gradle runs it from the project directory or the root.
     */
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

    @Test
    void everySettingRestoresItsExactDefaultAfterAChange() {
        for (CausticaConfig.RuntimeSetting<?> setting : CausticaConfig.settings()) {
            Object factoryDefault = setting.defaultValue();
            perturb(setting);
            setting.resetToDefault();
            assertEquals(factoryDefault, setting.get(),
                    setting.key() + " did not snap back to its factory default after a change");
        }
    }

    @Test
    void radiansSettingsResetWithoutReapplyingTheInputTransform() {
        // Sun angular radius: stored in radians, but set() consumes degrees. A naive
        // set(defaultValue()) would convert the radian default a second time and pin the sun at
        // ~0.01 degrees — exactly the trap the custom resetToDefault() exists to avoid.
        CausticaConfig.FloatSetting sun = CausticaConfig.Rt.Composite.SUN_ANGULAR_RADIUS;
        float def = sun.value();
        sun.set(5.0f);
        assertNotEquals(def, sun.value(), 1.0e-9f, "perturbing the slider must change the value");
        sun.resetToDefault();
        assertEquals(def, sun.value(), "reset must restore the stored default verbatim");
        sun.set(0.6f); // the stock value written back through the public degrees path
        assertEquals(def, sun.value(), 1.0e-7f,
                "writing the stock degrees through set() must reproduce the stored radians");
    }

    @SuppressWarnings("unchecked")
    private static <T> void perturb(CausticaConfig.RuntimeSetting<T> setting) {
        T factoryDefault = setting.defaultValue();
        if (factoryDefault instanceof Boolean b) {
            ((CausticaConfig.RuntimeSetting<Boolean>) setting).set(!b);
        } else if (factoryDefault instanceof Integer i) {
            ((CausticaConfig.RuntimeSetting<Integer>) setting).set(i + 1);
        } else if (factoryDefault instanceof Float f) {
            ((CausticaConfig.RuntimeSetting<Float>) setting).set(f + 0.5f);
        } else {
            // String mode pickers (exposure/cloud style/tonemap) and the optional NGX path setting,
            // whose default is null. Sanitizers may map the junk value anywhere; the reset must still
            // land on the exact default.
            ((CausticaConfig.RuntimeSetting<String>) setting).set("perturbed-test-value");
        }
    }
}
