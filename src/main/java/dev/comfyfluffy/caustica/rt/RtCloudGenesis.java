package dev.comfyfluffy.caustica.rt;

/**
 * The volumetric deck's cloud-genesis model: what KIND of cloud the sky is making right now, and
 * therefore how deep that cloud is.
 *
 * <h2>Why this exists</h2>
 * The volumetric deck used to take its depth from the Cloud Thickness slider, which is the wrong shape
 * of control for a photoreal sky. A cloud's thickness is not a preference, it is a consequence of what
 * the atmosphere is doing: a fair-weather cumulus humilis is a shallow, flat-based puff tens of blocks
 * deep, and a storm's cumulus congestus is a tower hundreds of blocks tall. Both are "correct" clouds,
 * and neither is a fraction of a maximum the player picked. Driving depth from a slider meant the same
 * slider value produced a 10-block sheet at one extreme and a slab at the other, and every visual
 * property downstream — how far the light march reaches, how much erosion reads as detail rather than
 * as damage, whether the crown or the base dominates the silhouette — had to be retuned against it.
 *
 * <p>So the slider is retired for this style and the depth is derived instead, from two things the
 * renderer already knows:
 *
 * <ul>
 *   <li><b>Insolation.</b> Cumulus are convective: they exist because the sun heats the surface, and
 *       they grow through the morning, peak in the afternoon and flatten away after sunset. The caller
 *       passes the sun's normalised elevation (see {@code RtComposite.cloudState}, which reads it from
 *       the same {@code SkyPush.sunDir} the sky is lit by), so the deck deepens and shallows on the day
 *       cycle with nothing scheduled and nothing to configure;</li>
 *   <li><b>Forced convection.</b> Rain and thunder are the atmosphere being unstable regardless of the
 *       hour, and vanilla's own interpolated levels drive it — the same two numbers
 *       {@code RtComposite.weatherState} already uses to darken the sky and attenuate the sun. A storm
 *       is therefore dark AND deep AND turbulent, from one state, and the three cannot drift apart.</li>
 * </ul>
 *
 * <h2>What is published</h2>
 * Four numbers, one {@code WorldPush.cloudGenus} lane, consumed only by {@code clouds.slang}'s
 * volumetric branch:
 *
 * <ul>
 *   <li>{@link #deckDepth()} — base to the crown a TYPICAL cloud of this genus reaches, in blocks;</li>
 *   <li>{@link #towerScale()} — how much taller a dense, fully developed core grows than that. The slab
 *       the ray march integrates is {@link #slabDepth()}, so towers have room to exist without the whole
 *       deck being that tall: a shallow humilis layer with a few congestus cores punching through it is
 *       exactly what a convective afternoon looks like;</li>
 *   <li>{@link #turbulence()} — erosion, warp and billow amplitude, 0..1. Smooth and rounded for
 *       humilis, torn and cauliflower-covered in a storm;</li>
 *   <li>{@link #genus()} — the continuous 0..1 development blend the three above were derived from,
 *       pushed so the shader can grade the silhouette's character (how much of the population gets to
 *       develop a tower) rather than re-deriving it.</li>
 * </ul>
 *
 * <p>The classic deck ignores all of it and keeps the thickness slider: its shape is authored data
 * (vanilla's {@code clouds.png} cell map) and its depth is a size the player is scaling, not a physical
 * quantity being simulated. Two styles, two answers to "how deep", by design — see
 * {@code clouds.slang}'s header.
 *
 * <p>Pure arithmetic on primitives with no Minecraft dependency, so {@code RtCloudGenesisTest} can pin
 * the whole model — its ranges, its monotonicity and the slab-budget identity the shader relies on —
 * without a client.
 */
public record RtCloudGenesis(float deckDepth, float towerScale, float turbulence, float genus) {
    /** Deck depth of the shallowest genus: flat-based fair-weather cumulus humilis, in blocks. */
    public static final float HUMILIS_DEPTH = 26.0f;
    /** Deck depth of the deepest genus: cumulus congestus, in blocks. */
    public static final float CONGESTUS_DEPTH = 88.0f;
    /** Tower scale at the shallow end — a humilis puff is barely taller than it is deep. */
    public static final float HUMILIS_TOWER = 1.30f;
    /** Tower scale at the deep end — a congestus core towers over the layer it grew out of. */
    public static final float CONGESTUS_TOWER = 2.35f;
    /** Erosion/turbulence at the shallow end: rounded, soft-edged, almost no torn detail. */
    public static final float HUMILIS_TURBULENCE = 0.30f;
    /** Erosion/turbulence at the deep end: heavily recut, aerated, cauliflower. */
    public static final float CONGESTUS_TURBULENCE = 1.00f;

    /**
     * The slab the march integrates, in blocks, and the ceiling on it. This is a BUDGET, not a look
     * parameter: {@code clouds.slang} caps a single ray's in-slab path in absolute blocks
     * (CLOUD_MAX_MARCH_BLOCKS) so the cost of a horizon ray does not follow the weather, but the step
     * count is still scaled to the slab depth, and a slab twice as deep is a march twice as deep. 208
     * blocks is the deepest deck this model is allowed to build, and the genus ramp is calibrated to
     * reach 206.8 at full development — just inside it, so the reduction below is a guard against a
     * future constant change rather than something that fires today.
     */
    public static final float MAX_SLAB_DEPTH = 208.0f;

    /** Development of the three forced genera, for the override setting. {@code auto} is not listed. */
    public static final float GENUS_HUMILIS = 0.0f;
    public static final float GENUS_MEDIOCRIS = 0.5f;
    public static final float GENUS_CONGESTUS = 1.0f;

    /**
     * Resolve this frame's genus from the weather and the sun.
     *
     * @param override   the Cloud Development setting: {@code auto} derives it, anything else pins the
     *                   genus (see {@link #GENUS_HUMILIS} and friends). An unrecognised value is auto,
     *                   so a hand-edited config can never leave the deck without a depth;
     * @param rain       vanilla's interpolated rain level, 0 clear .. 1 fully raining
     * @param thunder    vanilla's interpolated thunder level, 0 .. 1 (non-zero only while raining)
     * @param insolation the sun's elevation normalised to its own noon value, 0 at or below the horizon
     *                   .. 1 at local noon. The caller derives it from {@code SkyPush.sunDir}
     * @return the resolved genesis, with {@link #slabDepth()} guaranteed to sit inside the march budget
     */
    public static RtCloudGenesis resolve(String override, float rain, float thunder, float insolation) {
        return fromDevelopment(development(override, rain, thunder, insolation));
    }

    /**
     * The 0..1 development blend: 0 is a shallow humilis deck, 1 a towering congestus one.
     *
     * <p>Two contributions, and they are NOT symmetric. Insolation is scaled down (0.55) because even a
     * clear noon should only reach mediocris: fair-weather cumulus do not tower without a reason, and a
     * model that let the sun alone reach congestus would have nothing left to express in a storm. The
     * weather term enters at full weight, so it can reach 1.0 on its own at any hour — including a night
     * thunderstorm, which is exactly the case a purely diurnal model gets conspicuously wrong. Within
     * it, rain carries 0.60 and thunder the remaining 0.40: vanilla only ever raises thunder while it is
     * already raining, so a full storm is rain 1 + thunder 1 = 1.0 while a steady rain with no lightning
     * settles at 0.60, a deep overcast deck rather than a towering one.
     *
     * <p>Every input is clamped into 0..1 first, so a datapack or a mod driving vanilla's levels out of
     * range cannot push the deck past its budget, and the sum is monotone non-decreasing in all three
     * drivers — more sun, more rain and more thunder each only ever ADD development.
     */
    public static float development(String override, float rain, float thunder, float insolation) {
        float pinned = pinnedDevelopment(override);
        if (pinned >= 0.0f) {
            return pinned;
        }
        float heating = Math.clamp(insolation, 0.0f, 1.0f);
        float forced = Math.clamp(rain, 0.0f, 1.0f) * 0.60f
                + Math.clamp(thunder, 0.0f, 1.0f) * 0.40f;
        return Math.clamp(0.55f * heating + forced, 0.0f, 1.0f);
    }

    /** Map a development blend onto the four published numbers, honouring the slab budget. */
    public static RtCloudGenesis fromDevelopment(float development) {
        float d = Math.clamp(development, 0.0f, 1.0f);
        float deckDepth = mix(HUMILIS_DEPTH, CONGESTUS_DEPTH, d);
        float towerScale = mix(HUMILIS_TOWER, CONGESTUS_TOWER, d);
        float turbulence = mix(HUMILIS_TURBULENCE, CONGESTUS_TURBULENCE, d);
        // Never let the slab outgrow the march budget. Scaling the TOWER down rather than the deck keeps
        // the layer a typical cloud occupies intact, so a clamped deck loses its tallest towers instead
        // of becoming a shallow sheet — the visible consequence of exceeding the budget would be a cost
        // spike, and of clamping the deck would be clouds that changed shape with the weather twice.
        if (deckDepth * towerScale > MAX_SLAB_DEPTH) {
            towerScale = MAX_SLAB_DEPTH / deckDepth;
        }
        return new RtCloudGenesis(deckDepth, towerScale, turbulence, d);
    }

    /**
     * The depth of the slab the shader marches: {@code cloudAnchor.z}, and by construction
     * {@code cloudGenus.x * cloudGenus.y}. The two are published together precisely so the shader can
     * trust that identity — the profile normalises against the slab while the crown heights grade
     * against the deck, and a mismatch between them would clip every tower at the top of its own slab.
     */
    public float slabDepth() {
        return deckDepth * towerScale;
    }

    /** The pinned development for a non-auto override, or -1 when the value means "derive it". */
    private static float pinnedDevelopment(String override) {
        if (override == null) {
            return -1.0f;
        }
        return switch (override.toLowerCase(java.util.Locale.ROOT).replace('-', '_')) {
            case "humilis", "flat", "shallow" -> GENUS_HUMILIS;
            case "mediocris", "medium", "mediumm" -> GENUS_MEDIOCRIS;
            case "congestus", "towering", "tall", "storm" -> GENUS_CONGESTUS;
            default -> -1.0f; // "auto", empty, or anything unrecognised
        };
    }

    private static float mix(float from, float to, float t) {
        return from + (to - from) * t;
    }
}
