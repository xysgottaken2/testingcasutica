package dev.comfyfluffy.caustica.rt;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * The cloud-genesis model, pinned numerically.
 *
 * <p>{@link RtCloudGenesis} is pure arithmetic precisely so that this can exist: the volumetric deck's
 * depth used to be a slider, which meant the only way to check "does a storm produce a deeper cloud
 * than a clear noon" was to look at the sky. The model replaced a look with a contract, and a contract
 * can be asserted. These are the properties the shader and the push wiring depend on, not a restatement
 * of the formula — each one names the visible bug its failure would produce.
 *
 * <p>Deliberately NOT tested here: the tuning constants themselves. Whether congestus should be 88 or
 * 96 blocks deep is a look judgement, and pinning it would turn every art pass into a test edit.
 */
final class RtCloudGenesisTest {
    /** Insolation the caller derives from the sun's normalised elevation: night. */
    private static final float NIGHT = 0.0f;
    /** Insolation at local noon. */
    private static final float NOON = 1.0f;

    @Test
    void clearNightIsTheShallowestGenusTheModelProduces() {
        RtCloudGenesis night = RtCloudGenesis.resolve("auto", 0f, 0f, NIGHT);
        assertEquals(RtCloudGenesis.GENUS_HUMILIS, night.genus(), 1.0e-6f,
                "no sun and no weather must mean no convective development at all");
        assertEquals(RtCloudGenesis.HUMILIS_DEPTH, night.deckDepth(), 1.0e-4f);
        assertEquals(RtCloudGenesis.HUMILIS_TOWER, night.towerScale(), 1.0e-4f);
        assertEquals(RtCloudGenesis.HUMILIS_TURBULENCE, night.turbulence(), 1.0e-4f);
    }

    @Test
    void clearNoonDevelopsPastHumilisButStopsShortOfCongestus() {
        RtCloudGenesis noon = RtCloudGenesis.resolve("auto", 0f, 0f, NOON);
        // A clear noon is fair-weather cumulus mediocris: visibly developed, and distinctly NOT a
        // storm. If insolation alone could reach congestus, every sunny afternoon would tower and the
        // weather term would have nothing left to express.
        assertTrue(noon.genus() > RtCloudGenesis.GENUS_HUMILIS,
                "a clear noon must develop past the night's flat deck");
        assertTrue(noon.genus() < RtCloudGenesis.GENUS_CONGESTUS,
                "insolation alone must not reach congestus — that is the weather's job");
        assertTrue(noon.deckDepth() > RtCloudGenesis.HUMILIS_DEPTH
                        && noon.deckDepth() < RtCloudGenesis.CONGESTUS_DEPTH,
                "the deck depth must sit strictly between the two genera");
    }

    @Test
    void aStormTowersAtAnyHourIncludingNight() {
        RtCloudGenesis stormNight = RtCloudGenesis.resolve("auto", 1f, 1f, NIGHT);
        RtCloudGenesis clearNoon = RtCloudGenesis.resolve("auto", 0f, 0f, NOON);
        assertEquals(RtCloudGenesis.GENUS_CONGESTUS, stormNight.genus(), 1.0e-6f,
                "a full thunderstorm must reach congestus even with the sun down — the case a purely "
                        + "diurnal model gets conspicuously wrong");
        assertTrue(stormNight.deckDepth() > clearNoon.deckDepth(),
                "a night storm must be deeper than a clear noon, not shallower");
        assertTrue(stormNight.turbulence() > clearNoon.turbulence(),
                "a storm deck must be more heavily eroded than a fair-weather one");
    }

    @Test
    void developmentIsMonotoneInEveryInput() {
        // Each of the three drivers must only ever ADD development. A non-monotone term would mean
        // more rain producing a shallower deck somewhere in the range, which no one would find without
        // a sweep like this one.
        for (float insolation : new float[] {0f, 0.25f, 0.5f, 0.75f, 1f}) {
            float previousRain = -1f;
            float previousThunder = -1f;
            for (int step = 0; step <= 10; step++) {
                float level = step / 10.0f;
                float withRain = RtCloudGenesis.development("auto", level, 0f, insolation);
                assertTrue(withRain >= previousRain - 1.0e-6f,
                        "development fell as rain rose at insolation " + insolation);
                previousRain = withRain;
                float withThunder = RtCloudGenesis.development("auto", 1f, level, insolation);
                assertTrue(withThunder >= previousThunder - 1.0e-6f,
                        "development fell as thunder rose at insolation " + insolation);
                previousThunder = withThunder;
            }
        }
        float previous = -1f;
        for (int step = 0; step <= 10; step++) {
            float value = RtCloudGenesis.development("auto", 0.3f, 0.1f, step / 10.0f);
            assertTrue(value >= previous - 1.0e-6f, "development fell as the sun rose");
            previous = value;
        }
    }

    /**
     * The identity the shader is built on: {@code cloudAnchor.z == cloudGenus.x * cloudGenus.y}.
     *
     * <p>{@code clouds.slang} normalises its vertical profile against the SLAB (cloudAnchor.z) while it
     * grades crown heights against the DECK (cloudGenus.x), and assumes the slab is exactly deck times
     * tower. A clamp or a rounding step inserted between the two would silently clip every tower at the
     * top of its own slab — the crown of a congestus sliced flat, which reads as a ceiling rather than
     * as a cloud.
     */
    @Test
    void slabDepthIsExactlyDeckDepthTimesTowerScaleEverywhere() {
        for (int step = 0; step <= 100; step++) {
            float development = step / 100.0f;
            RtCloudGenesis genus = RtCloudGenesis.fromDevelopment(development);
            assertEquals(genus.deckDepth() * genus.towerScale(), genus.slabDepth(), 0.0f,
                    "slabDepth() must be the bare product at development " + development
                            + " — the push writes both and the shader trusts they agree");
        }
    }

    @Test
    void slabDepthStaysInsideTheMarchBudgetForEveryInput() {
        for (int rain = 0; rain <= 10; rain++) {
            for (int thunder = 0; thunder <= 10; thunder++) {
                for (int sun = 0; sun <= 10; sun++) {
                    RtCloudGenesis genus = RtCloudGenesis.resolve("auto", rain / 10.0f,
                            thunder / 10.0f, sun / 10.0f);
                    assertTrue(genus.slabDepth() <= RtCloudGenesis.MAX_SLAB_DEPTH + 1.0e-3f,
                            "slab " + genus.slabDepth() + " exceeds the march budget at rain=" + rain
                                    + " thunder=" + thunder + " sun=" + sun);
                    assertTrue(genus.slabDepth() > 0.0f, "a deck must have some depth");
                }
            }
        }
        // A budget overflow must be absorbed by the TOWERS, not by the layer: reducing the deck would
        // make clouds change shape with the weather twice over, once from the genus and once from the
        // clamp.
        RtCloudGenesis overflowing =
                RtCloudGenesis.fromDevelopment(RtCloudGenesis.GENUS_CONGESTUS);
        assertEquals(RtCloudGenesis.CONGESTUS_DEPTH, overflowing.deckDepth(), 1.0e-4f,
                "the deepest genus must reach its deck depth without being clamped down");
    }

    @Test
    void towersNeverShrinkBelowTheDeckTheyGrowOutOf() {
        for (int step = 0; step <= 100; step++) {
            RtCloudGenesis genus = RtCloudGenesis.fromDevelopment(step / 100.0f);
            assertTrue(genus.towerScale() >= 1.0f,
                    "a tower scale below 1 would put the crown BELOW the deck depth it grades against");
            assertTrue(genus.turbulence() >= 0.0f && genus.turbulence() <= 1.0f,
                    "turbulence is read as a 0..1 blend in the shader");
            assertTrue(genus.genus() >= 0.0f && genus.genus() <= 1.0f);
        }
    }

    @Test
    void anOverridePinsTheGenusRegardlessOfWeather() {
        RtCloudGenesis pinnedNight = RtCloudGenesis.resolve("humilis", 1f, 1f, NOON);
        RtCloudGenesis derived = RtCloudGenesis.fromDevelopment(RtCloudGenesis.GENUS_HUMILIS);
        assertEquals(derived, pinnedNight,
                "a pinned genus must ignore rain, thunder and the sun alike");

        assertEquals(RtCloudGenesis.GENUS_MEDIOCRIS,
                RtCloudGenesis.resolve("mediocris", 0f, 0f, NOON).genus(), 1.0e-6f);
        assertEquals(RtCloudGenesis.GENUS_CONGESTUS,
                RtCloudGenesis.resolve("congestus", 0f, 0f, NIGHT).genus(), 1.0e-6f);
        assertNotEquals(RtCloudGenesis.resolve("congestus", 0f, 0f, NIGHT).deckDepth(),
                RtCloudGenesis.resolve("humilis", 0f, 0f, NIGHT).deckDepth(), 1.0e-4f,
                "the three pinned genera must actually differ, or the setting is decoration");
    }

    @Test
    void anythingUnrecognisedMeansAutoRatherThanAFrozenSky() {
        RtCloudGenesis auto = RtCloudGenesis.resolve("auto", 0.4f, 0f, 0.7f);
        for (String junk : new String[] {null, "", "AUTO", "nonsense", "cumulus", "0"}) {
            assertEquals(auto, RtCloudGenesis.resolve(junk, 0.4f, 0f, 0.7f),
                    "\"" + junk + "\" must fall back to the derived genus, not pin one");
        }
        // The sanitiser the setting is registered with already maps the documented aliases, and the
        // model accepts the same spellings, so a hand-edited config works either way round.
        assertEquals(auto, RtCloudGenesis.resolve("Auto", 0.4f, 0f, 0.7f));
        assertEquals(RtCloudGenesis.resolve("congestus", 0f, 0f, 0f),
                RtCloudGenesis.resolve("towering", 0f, 0f, 0f));
        assertEquals(RtCloudGenesis.resolve("humilis", 0f, 0f, 0f),
                RtCloudGenesis.resolve("flat", 0f, 0f, 0f));
    }
}
