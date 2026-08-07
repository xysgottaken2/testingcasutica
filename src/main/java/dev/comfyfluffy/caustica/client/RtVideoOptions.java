package dev.comfyfluffy.caustica.client;

import com.mojang.serialization.Codec;
import dev.comfyfluffy.caustica.CausticaConfig;
import dev.comfyfluffy.caustica.CausticaConfig.BooleanSetting;
import dev.comfyfluffy.caustica.CausticaConfig.FloatSetting;
import dev.comfyfluffy.caustica.CausticaConfig.IntSetting;
import dev.comfyfluffy.caustica.CausticaConfig.StringSetting;
import java.util.List;
import java.util.Locale;
import dev.comfyfluffy.caustica.compat.DistantHorizonsCompat;
import dev.comfyfluffy.caustica.compat.VoxyCompat;
import dev.comfyfluffy.caustica.rt.terrain.RtDistantHorizonsTerrain;
import net.minecraft.client.Minecraft;
import net.minecraft.client.OptionInstance;
import net.minecraft.client.Options;
import net.minecraft.client.gui.components.Button;
import net.minecraft.network.chat.Component;

/**
 * Builds the {@link OptionInstance} widgets shown in the RT section of the vanilla Video Settings screen
 * (injected by {@code VideoSettingsScreenMixin}). Each option is bound straight to a {@link CausticaConfig}
 * runtime setting: the initial value is read from the current config, and the value-update listener writes
 * back through {@code set(...)} so changes take effect on the next frame.
 *
 * <p>Only settings the renderer re-reads per-frame are exposed here — toggles that would require a device or
 * buffer-pool rebuild (worker threads, OMM, max-entity capacities, PBR material flags) are intentionally
 * left to the {@code -Dcaustica.*} startup surface. DLSS-RR quality is the exception: the render resolution
 * is queried from NGX for the chosen quality mode on every resize (see
 * {@code RtDlssRr.queryOptimalRenderSize}), and the RR feature itself is recreated live whenever
 * {@code quality} changes (see {@code RtDlssRr.ensureFeature}), so it is safe to expose here.
 */
public final class RtVideoOptions {
    private RtVideoOptions() {
    }

    /** General runtime-tunable RT options. Paired two-per-row by {@code OptionsList.addSmall}. */
    public static OptionInstance<?>[] runtimeOptions() {
        return new OptionInstance<?>[] {
            spp(),
            maxBounces(),
            sunSize(),
            entities(),
            particles(),
            weatherParticles(),
            rainDensity(),
            waterWaves(),
            // POM: the on/off toggle followed by its tuning sliders, shader-only and safe live.
            parallaxEnabled(),
            parallaxStrength(),
            parallaxSmoothing(),
            parallaxDistance(),
            // Grouped: the three new effect/quality toggles sit together, and OptionsList.addSmall
            // pairs them two per row, so they read as one block rather than scattered checkboxes.
            subsurfaceScattering(),
            weatherLighting(),
            // Clouds: the on/off toggle followed by its two tuning sliders, so the control that gates
            // the other two reads immediately before them.
            clouds(),
            cloudStyle(),
            cloudHeight(),
            cloudThickness(),
            cloudShadowStrength(),
            cloudOpacity(),
            denoiser(),
            handFov(),
            dlssQuality(),
            hdrEnabled(),
            hdrPaperWhite(),
            hdrPeak(),
            debugView(),
        };
    }

    // ===== Organized groups for the dedicated RT settings screen =====

    public static OptionInstance<?>[] qualityOptions() {
        return new OptionInstance<?>[] {
            spp(),
            maxBounces(),
            dlssQuality(),
            denoiser(),
        };
    }

    public static OptionInstance<?>[] generalOptions() {
        return new OptionInstance<?>[] {
            sunSize(),
            entities(),
            particles(),
            weatherParticles(),
            rainDensity(),
            waterWaves(),
            handFov(),
        };
    }

    public static OptionInstance<?>[] effectsOptions() {
        return new OptionInstance<?>[] {
            subsurfaceScattering(),
            weatherLighting(),
        };
    }

    public static OptionInstance<?>[] pomOptions() {
        return new OptionInstance<?>[] {
            parallaxEnabled(),
            parallaxStrength(),
            parallaxSmoothing(),
            parallaxDistance(),
        };
    }

    public static OptionInstance<?>[] cloudOptions() {
        return new OptionInstance<?>[] {
            clouds(),
            cloudStyle(),
            cloudHeight(),
            cloudThickness(),
            cloudShadowStrength(),
            cloudOpacity(),
        };
    }

    public static OptionInstance<?>[] hdrOptions() {
        return new OptionInstance<?>[] {
            hdrEnabled(),
            hdrPaperWhite(),
            hdrPeak(),
        };
    }

    public static OptionInstance<?>[] debugOptions() {
        return new OptionInstance<?>[] {
            debugView(),
        };
    }

    public static OptionInstance<?>[] exposureOptions() {
        return new OptionInstance<?>[] {
            exposureMode(),
            manualEv(),
        };
    }

    /**
     * Light-emission and sampling options. Held-item dynamic lighting keeps working exactly as Caustica
     * ships it — its multiplier ({@code CausticaConfig.Rt.Lights.DYNAMIC_INTENSITY}) is simply not given a
     * slider here and stays at the config/system-property default.
     */
    public static OptionInstance<?>[] lightOptions() {
        return new OptionInstance<?>[] {
            blockEmissiveIntensity(),
            restirSampling(),
        };
    }

    /** Tonemapping options (without exposure, which now has its own section) */
    public static OptionInstance<?>[] tonemapOptions() {
        return new OptionInstance<?>[] {
            tonemapOperator(),
            tonemapExposure(),
            tonemapGamma(),
            tonemapSaturation(),
            tonemapContrast(),
        };
    }

    /** Legacy combined exposure + tonemap, kept for compatibility if needed */
    public static OptionInstance<?>[] exposureAndTonemapOptions() {
        return new OptionInstance<?>[] {
            exposureMode(),
            manualEv(),
            tonemapOperator(),
            tonemapExposure(),
            tonemapGamma(),
            tonemapSaturation(),
            tonemapContrast(),
        };
    }

    private static OptionInstance<String> exposureMode() {
        StringSetting setting = CausticaConfig.Rt.Exposure.MODE;
        return new OptionInstance<>(
            "caustica.options.rt.exposureMode",
            OptionInstance.cachedConstantTooltip(Component.translatable("caustica.options.rt.exposureMode.tooltip")),
            // CycleButton (used for Enum values) already prepends "caption: " itself (DisplayState.
            // NAME_AND_VALUE), so this must return only the value's text, not caption + value again.
            (caption, value) -> Component.translatable("caustica.options.rt.exposureMode." + value),
            new OptionInstance.Enum<>(List.of("auto", "manual"), Codec.STRING),
            setting.get(),
            setting::set);
    }

    private static OptionInstance<Integer> manualEv() {
        FloatSetting setting = CausticaConfig.Rt.Exposure.MANUAL_EV;
        return new OptionInstance<>(
            "caustica.options.rt.manualEv",
            OptionInstance.cachedConstantTooltip(Component.translatable("caustica.options.rt.manualEv.tooltip")),
            (caption, tenths) -> {
                float ev = tenths / 10.0f;
                String sign = ev > 0.0f ? "+" : "";
                return Options.genericValueLabel(caption,
                        Component.literal(sign + String.format(Locale.ROOT, "%.1f EV", ev)));
            },
            new OptionInstance.IntRange(-50, 50),
            Math.clamp(Math.round(setting.value() * 10.0f), -50, 50),
            tenths -> setting.set(tenths / 10.0f));
    }

    private static OptionInstance<Integer> spp() {
        IntSetting setting = CausticaConfig.Rt.Composite.SPP;
        return new OptionInstance<>(
            "caustica.options.rt.spp",
            OptionInstance.cachedConstantTooltip(Component.translatable("caustica.options.rt.spp.tooltip")),
            (caption, value) -> Options.genericValueLabel(caption, value),
            new OptionInstance.IntRange(1, 8),
            Math.clamp(setting.value(), 1, 8),
            setting::set);
    }

    private static OptionInstance<Integer> maxBounces() {
        IntSetting setting = CausticaConfig.Rt.Composite.MAX_BOUNCES;
        return new OptionInstance<>(
            "caustica.options.rt.maxBounces",
            OptionInstance.cachedConstantTooltip(Component.translatable("caustica.options.rt.maxBounces.tooltip")),
            (caption, value) -> Options.genericValueLabel(caption, value),
            new OptionInstance.IntRange(2, 8),
            Math.clamp(setting.value(), 2, 8),
            setting::set);
    }

    private static OptionInstance<Integer> sunSize() {
        // Stored in radians via the degrees->radians sanitizer; the slider works in tenths of a degree.
        FloatSetting setting = CausticaConfig.Rt.Composite.SUN_ANGULAR_RADIUS;
        int initialTenths = Math.clamp(Math.round((float) Math.toDegrees(setting.value()) * 10.0f), 1, 50);
        return new OptionInstance<>(
            "caustica.options.rt.sunSize",
            OptionInstance.cachedConstantTooltip(Component.translatable("caustica.options.rt.sunSize.tooltip")),
            (caption, tenths) -> Options.genericValueLabel(caption, Component.literal(String.format("%.1f°", tenths / 10.0))),
            new OptionInstance.IntRange(1, 50),
            initialTenths,
            tenths -> setting.set(tenths / 10.0f));
    }


    private static OptionInstance<Integer> blockEmissiveIntensity() {
        return multiplier("caustica.options.rt.blockEmissiveIntensity",
                CausticaConfig.Rt.Lights.BLOCK_INTENSITY, 0, 160);
    }

    private static OptionInstance<Boolean> restirSampling() {
        return bool("caustica.options.rt.restirSampling", CausticaConfig.Rt.Lights.RESTIR_SAMPLING);
    }

    private static final List<String> TONEMAP_OPERATORS =
            List.of("agx", "pbr_neutral", "aces", "filmic", "linear", "psychov");

    private static OptionInstance<String> tonemapOperator() {
        StringSetting setting = CausticaConfig.Rt.Tonemapping.OPERATOR;
        return new OptionInstance<>(
            "caustica.options.rt.tonemapOperator",
            OptionInstance.cachedConstantTooltip(Component.translatable("caustica.options.rt.tonemapOperator.tooltip")),
            (caption, value) -> Component.translatable("caustica.options.rt.tonemapOperator." + value),
            new OptionInstance.Enum<>(TONEMAP_OPERATORS, Codec.STRING),
            TONEMAP_OPERATORS.contains(setting.get()) ? setting.get() : "agx",
            setting::set);
    }

    private static OptionInstance<Integer> tonemapExposure() {
        FloatSetting setting = CausticaConfig.Rt.Tonemapping.EXPOSURE_EV;
        return new OptionInstance<>(
            "caustica.options.rt.tonemapExposure",
            OptionInstance.cachedConstantTooltip(Component.translatable("caustica.options.rt.tonemapExposure.tooltip")),
            (caption, tenths) -> {
                float ev = tenths / 10.0f;
                String sign = ev > 0.0f ? "+" : "";
                return Options.genericValueLabel(caption,
                        Component.literal(sign + String.format(Locale.ROOT, "%.1f EV", ev)));
            },
            new OptionInstance.IntRange(-50, 50),
            Math.clamp(Math.round(setting.value() * 10.0f), -50, 50),
            tenths -> setting.set(tenths / 10.0f));
    }

    private static OptionInstance<Integer> tonemapGamma() {
        return hundredths("caustica.options.rt.tonemapGamma",
                CausticaConfig.Rt.Tonemapping.GAMMA, 50, 300);
    }

    private static OptionInstance<Integer> tonemapSaturation() {
        return hundredths("caustica.options.rt.tonemapSaturation",
                CausticaConfig.Rt.Tonemapping.SATURATION, 0, 300);
    }

    private static OptionInstance<Integer> tonemapContrast() {
        return hundredths("caustica.options.rt.tonemapContrast",
                CausticaConfig.Rt.Tonemapping.CONTRAST, 0, 300);
    }

    private static OptionInstance<Boolean> entities() {
        return bool("caustica.options.rt.entities", CausticaConfig.Rt.Entities.ENABLED);
    }

    private static OptionInstance<Boolean> particles() {
        return bool("caustica.options.rt.particles", CausticaConfig.Rt.Entities.PARTICLES_ENABLED);
    }

    /**
     * Ray-traced rain and snow. Caustica cancels vanilla's world renderer, and vanilla draws weather
     * inside it, so this switch is what puts precipitation in the world at all — the same relationship
     * the clouds toggle has. Weather shares the particle mesh, so it also needs Ray Traced Particles on.
     */
    private static OptionInstance<Boolean> weatherParticles() {
        return bool("caustica.options.rt.weatherParticles", CausticaConfig.Rt.Entities.WEATHER_ENABLED);
    }

    /**
     * Rain/snow density, as a percentage of vanilla's column density. 100% is exactly vanilla; lower
     * values thin the precipitation out so fewer drops fall. Does not change the weather simulation —
     * only how much of it is drawn.
     */
    private static OptionInstance<Integer> rainDensity() {
        return percent("caustica.options.rt.rainDensity", CausticaConfig.Rt.Entities.RAIN_DENSITY);
    }

    private static OptionInstance<Boolean> waterWaves() {
        return bool("caustica.options.rt.waterWaves", CausticaConfig.Rt.Composite.WATER_WAVES);
    }

    /**
     * LabPBR subsurface scattering: backlit foliage glow. Only materials that author an SSS channel are
     * affected, but each eligible shading vertex costs an extra shadow ray, so this is a real
     * performance lever in dense vegetation.
     */
    private static OptionInstance<Boolean> subsurfaceScattering() {
        return bool("caustica.options.rt.sss", CausticaConfig.Rt.Composite.SSS);
    }

    /** Rain/thunderstorm sun-and-sky dimming. Off keeps clear-sky lighting in every weather state. */
    private static OptionInstance<Boolean> weatherLighting() {
        return bool("caustica.options.rt.weatherLighting", CausticaConfig.Rt.Composite.WEATHER_LIGHTING);
    }

    /**
     * The ray-traced cloud deck. Caustica cancels vanilla's world renderer, and vanilla's clouds are
     * drawn inside it, so this switch is what puts clouds in the sky at all.
     */
    private static OptionInstance<Boolean> clouds() {
        return bool("caustica.options.rt.clouds", CausticaConfig.Rt.Composite.CLOUDS);
    }

    private static final List<String> CLOUD_STYLES = List.of("classic", "volumetric");

    // Cloud-height slider bounds, in world Y. Must stay inside CausticaConfig's own clamp on
    // CLOUD_HEIGHT, which is what actually guards the value.
    private static final int CLOUD_HEIGHT_MIN = 128;
    private static final int CLOUD_HEIGHT_MAX = 1024;
    private static final int CLOUD_HEIGHT_STEP = 8;

    /**
     * Cloud rendering style: vanilla's flat blocky deck, or a ray-marched volumetric slab.
     *
     * <p>Both styles are two readings of one shared coverage field, so switching does not move the
     * clouds — the same cloud is simply drawn flat or with depth — and the cloud shadows are unchanged
     * between them. Volumetric costs real GPU time (it marches the slab and light-marches for
     * self-shadowing); classic is nearly free.
     */
    private static OptionInstance<String> cloudStyle() {
        StringSetting setting = CausticaConfig.Rt.Composite.CLOUD_STYLE;
        return new OptionInstance<>(
            "caustica.options.rt.cloudStyle",
            OptionInstance.cachedConstantTooltip(Component.translatable("caustica.options.rt.cloudStyle.tooltip")),
            // CycleButton (used for Enum values) already prepends "caption: " itself, so this must
            // return only the value's text, not caption + value again.
            (caption, value) -> Component.translatable("caustica.options.rt.cloudStyle." + value),
            new OptionInstance.Enum<>(CLOUD_STYLES, Codec.STRING),
            CLOUD_STYLES.contains(setting.get()) ? setting.get() : "classic",
            setting::set);
    }

    /**
     * World Y the base of the cloud deck sits at, in blocks.
     *
     * <p>Stepped in 8-block increments: the slider spans nearly 900 blocks, and single-block precision
     * on a deck hundreds of blocks overhead is below what the eye can resolve, so coarser steps make it
     * far easier to land on a value.
     */
    private static OptionInstance<Integer> cloudHeight() {
        FloatSetting setting = CausticaConfig.Rt.Composite.CLOUD_HEIGHT;
        int steps = (CLOUD_HEIGHT_MAX - CLOUD_HEIGHT_MIN) / CLOUD_HEIGHT_STEP;
        int initial = Math.clamp(
                Math.round((setting.value() - CLOUD_HEIGHT_MIN) / CLOUD_HEIGHT_STEP), 0, steps);
        return new OptionInstance<>(
            "caustica.options.rt.cloudHeight",
            OptionInstance.cachedConstantTooltip(
                    Component.translatable("caustica.options.rt.cloudHeight.tooltip")),
            (caption, step) -> Options.genericValueLabel(caption,
                    Component.literal("Y " + (CLOUD_HEIGHT_MIN + step * CLOUD_HEIGHT_STEP))),
            new OptionInstance.IntRange(0, steps),
            initial,
            step -> setting.set((float) (CLOUD_HEIGHT_MIN + step * CLOUD_HEIGHT_STEP)));
    }

    /**
     * Cloud thickness, as a percentage of the maximum deck depth. Applies to both styles: 0% is a flat
     * sheet, 100% is a deep bank you can fly into. Classic clouds become real boxes with lit tops and
     * darker sides, the way vanilla's cloud geometry looks; volumetric clouds gain the depth their
     * shading needs. Thicker clouds cost more to march.
     */
    private static OptionInstance<Integer> cloudThickness() {
        return percent("caustica.options.rt.cloudThickness",
                CausticaConfig.Rt.Composite.CLOUD_THICKNESS);
    }

    /**
     * How strongly the cloud deck shadows the world beneath it, as a percentage. 0% draws clouds that
     * cast nothing; 100% lets a solid cloud block the sun outright.
     */
    private static OptionInstance<Integer> cloudShadowStrength() {
        return percent("caustica.options.rt.cloudShadowStrength",
                CausticaConfig.Rt.Composite.CLOUD_SHADOW_STRENGTH);
    }

    /**
     * How opaque the deck is, as a percentage: 0% is fully transparent (invisible, and the cloud path is
     * skipped entirely), 100% completely hides the sky behind it.
     */
    private static OptionInstance<Integer> cloudOpacity() {
        return percent("caustica.options.rt.cloudOpacity", CausticaConfig.Rt.Composite.CLOUD_OPACITY);
    }

    /**
     * The denoising filter (DLSS Ray Reconstruction). Turning it off shows the raw path-traced image —
     * a correct but noisy reference view — and, because RR also owns the upscale, moves the trace to
     * full display resolution. Safe to toggle live: {@code RtComposite.ensureOutput} re-sizes the trace
     * targets on the next frame.
     */
    private static OptionInstance<Boolean> denoiser() {
        return bool("caustica.options.rt.denoiser", CausticaConfig.Rt.Composite.DENOISER);
    }

    /**
     * ON makes the first-person viewmodel share the camera's FOV (raising FOV pushes the arm away, lowering
     * it pulls the arm closer); OFF restores vanilla's fixed, FOV-isolated hand projection.
     */
    private static OptionInstance<Boolean> handFov() {
        return bool("caustica.options.rt.handFov", CausticaConfig.Rt.Hand.FOV_FOLLOWS_CAMERA);
    }

    // NVSDK_NGX_PerfQuality_Value, ordered performance -> quality for the slider. Per NVIDIA's DLSS-RR
    // programming guide, Ray Reconstruction only supports Performance(0), Balanced(1), Quality(2),
    // Ultra-Performance(3), and DLAA(5) — Ultra Quality(4) is not a valid PerfQualityValue for RR (its
    // optimal-settings query returns a zeroed render size for it) and is deliberately excluded here.
    private static final List<Integer> DLSS_QUALITY_ORDER = List.of(3, 0, 1, 2, 5);

    private static OptionInstance<Integer> dlssQuality() {
        IntSetting setting = CausticaConfig.Rt.DlssRr.QUALITY;
        int initialQuality = DLSS_QUALITY_ORDER.contains(setting.value()) ? setting.value() : 0;
        int initialPosition = DLSS_QUALITY_ORDER.indexOf(initialQuality);
        return new OptionInstance<>(
            "caustica.options.rt.dlssQuality",
            OptionInstance.cachedConstantTooltip(Component.translatable("caustica.options.rt.dlssQuality.tooltip")),
            (caption, position) -> Options.genericValueLabel(caption,
                    Component.translatable("caustica.options.rt.dlssQuality." + DLSS_QUALITY_ORDER.get(position))),
            new OptionInstance.IntRange(0, DLSS_QUALITY_ORDER.size() - 1),
            initialPosition,
            position -> setting.set(DLSS_QUALITY_ORDER.get(position)));
    }

    private static OptionInstance<Boolean> hdrEnabled() {
        return bool("caustica.options.rt.hdr", CausticaConfig.Rt.Hdr.ENABLED);
    }

    private static OptionInstance<Integer> hdrPaperWhite() {
        FloatSetting setting = CausticaConfig.Rt.Hdr.PAPER_WHITE_NITS;
        return new OptionInstance<>(
            "caustica.options.rt.hdrPaperWhite",
            OptionInstance.cachedConstantTooltip(Component.translatable("caustica.options.rt.hdrPaperWhite.tooltip")),
            (caption, nits) -> Options.genericValueLabel(caption, Component.literal(nits + " nits")),
            new OptionInstance.IntRange(80, 1000),
            Math.clamp(Math.round(setting.value()), 80, 1000),
            nits -> setting.set(nits.floatValue()));
    }

    private static OptionInstance<Integer> hdrPeak() {
        FloatSetting setting = CausticaConfig.Rt.Hdr.PEAK_NITS;
        return new OptionInstance<>(
            "caustica.options.rt.hdrPeak",
            OptionInstance.cachedConstantTooltip(Component.translatable("caustica.options.rt.hdrPeak.tooltip")),
            (caption, nits) -> Options.genericValueLabel(caption, Component.literal(nits + " nits")),
            new OptionInstance.IntRange(80, 10000),
            Math.clamp(Math.round(setting.value()), 80, 10000),
            nits -> setting.set(nits.floatValue()));
    }

    private static OptionInstance<Integer> debugView() {
        IntSetting setting = CausticaConfig.Rt.Composite.DEBUG_VIEW;
        return new OptionInstance<>(
            "caustica.options.rt.debugView",
            OptionInstance.cachedConstantTooltip(Component.translatable("caustica.options.rt.debugView.tooltip")),
            // CycleButton (used for Enum values) already prepends "caption: " itself (DisplayState.
            // NAME_AND_VALUE), so this must return only the value's text, not caption + value again.
            (caption, value) -> Component.translatable("caustica.options.rt.debugView." + value),
            new OptionInstance.Enum<>(List.of(0, 1, 2, 3, 4, 5, 6, 7), Codec.INT),
            Math.clamp(setting.value(), 0, 7),
            setting::set);
    }

    private static OptionInstance<Integer> multiplier(String captionKey, FloatSetting setting, int minTenths, int maxTenths) {
        return new OptionInstance<>(
            captionKey,
            OptionInstance.cachedConstantTooltip(Component.translatable(captionKey + ".tooltip")),
            (caption, tenths) -> Options.genericValueLabel(caption,
                    Component.literal(String.format(Locale.ROOT, "%.1fx", tenths / 10.0f))),
            new OptionInstance.IntRange(minTenths, maxTenths),
            Math.clamp(Math.round(setting.value() * 10.0f), minTenths, maxTenths),
            tenths -> setting.set(tenths / 10.0f));
    }

    /**
     * A 0..1 float exposed as a 0..100% slider. The setting itself is clamped to [0,1] in the config, so
     * the slider range and the stored domain are the same thing expressed in different units.
     */
    private static OptionInstance<Integer> percent(String captionKey, FloatSetting setting) {
        return new OptionInstance<>(
            captionKey,
            OptionInstance.cachedConstantTooltip(Component.translatable(captionKey + ".tooltip")),
            (caption, value) -> Options.genericValueLabel(caption, Component.literal(value + "%")),
            new OptionInstance.IntRange(0, 100),
            Math.clamp(Math.round(setting.value() * 100.0f), 0, 100),
            value -> setting.set(value / 100.0f));
    }

    private static OptionInstance<Integer> hundredths(String captionKey, FloatSetting setting, int min, int max) {
        return new OptionInstance<>(
            captionKey,
            OptionInstance.cachedConstantTooltip(Component.translatable(captionKey + ".tooltip")),
            (caption, hundredths) -> Options.genericValueLabel(caption,
                    Component.literal(String.format(Locale.ROOT, "%.2f", hundredths / 100.0f))),
            new OptionInstance.IntRange(min, max),
            Math.clamp(Math.round(setting.value() * 100.0f), min, max),
            value -> setting.set(value / 100.0f));
    }

    private static OptionInstance<Boolean> parallaxEnabled() {
        return bool("caustica.options.rt.parallax", CausticaConfig.Rt.Composite.PARALLAX_ENABLED);
    }

    private static OptionInstance<Integer> parallaxStrength() {
        FloatSetting setting = CausticaConfig.Rt.Composite.PARALLAX_STRENGTH;
        return new OptionInstance<>(
            "caustica.options.rt.parallaxStrength",
            OptionInstance.cachedConstantTooltip(Component.translatable("caustica.options.rt.parallaxStrength.tooltip")),
            (caption, percent) -> Options.genericValueLabel(caption, Component.literal(percent + "%")),
            new OptionInstance.IntRange(0, 400),
            Math.clamp(Math.round(setting.value() * 100.0f), 0, 400),
            percent -> setting.set(percent / 100.0f));
    }

    private static OptionInstance<Boolean> parallaxSmoothing() {
        return bool("caustica.options.rt.parallaxSmoothing",
                CausticaConfig.Rt.Composite.PARALLAX_SMOOTHING);
    }

    private static OptionInstance<Integer> parallaxDistance() {
        FloatSetting setting = CausticaConfig.Rt.Composite.PARALLAX_DISTANCE;
        return new OptionInstance<>(
            "caustica.options.rt.parallaxDistance",
            OptionInstance.cachedConstantTooltip(
                    Component.translatable("caustica.options.rt.parallaxDistance.tooltip")),
            (caption, blocks) -> Options.genericValueLabel(caption, Component.literal(blocks + " blocks")),
            new OptionInstance.IntRange(16, 256),
            Math.clamp(Math.round(setting.value()), 16, 256),
            blocks -> setting.set(blocks.floatValue()));
    }

    /** Rebuild DH's render cache and Caustica's RT proxy after changing DH quality settings. */
    public static Button distantHorizonsRefreshButton() {
        Button button = Button.builder(Component.translatable("caustica.options.rt.dhRefresh"), clicked -> {
            boolean dhReloaded = DistantHorizonsCompat.reloadRenderDataCache();
            RtDistantHorizonsTerrain.INSTANCE.requestFullRefresh();
            clicked.setMessage(Component.translatable(dhReloaded
                    ? "caustica.options.rt.dhRefresh.queued"
                    : "caustica.options.rt.dhRefresh.rtOnly"));
        }).width(310).build();
        button.active = DistantHorizonsCompat.enabled() && Minecraft.getInstance().level != null;
        return button;
    }

    /** Live settings supplied by the bundled no-Sodium Voxy bridge. */
    public static OptionInstance<?>[] voxyOptions() {
        return new OptionInstance<?>[] {
            OptionInstance.createBoolean(
                    "caustica.options.voxy.enabled",
                    OptionInstance.cachedConstantTooltip(
                            Component.translatable("caustica.options.voxy.enabled.tooltip")),
                    VoxyCompat.active(),
                    enabled -> {
                        if (VoxyCompat.setActive(enabled)) {
                            RtDistantHorizonsTerrain.INSTANCE.requestFullRefresh();
                        }
                    }),
            OptionInstance.createBoolean(
                    "caustica.options.voxy.ingest",
                    OptionInstance.cachedConstantTooltip(
                            Component.translatable("caustica.options.voxy.ingest.tooltip")),
                    VoxyCompat.ingestEnabled(),
                    VoxyCompat::setIngestEnabled),
            new OptionInstance<>(
                    "caustica.options.voxy.distance",
                    OptionInstance.cachedConstantTooltip(
                            Component.translatable("caustica.options.voxy.distance.tooltip")),
                    (caption, sections) -> Options.genericValueLabel(caption,
                            Component.translatable("caustica.options.voxy.chunks", sections * 32)),
                    // Voxy stores this value in 32-block sections. Exposing the native steps avoids
                    // hundreds of config writes and full desired-set recalculations during one drag.
                    new OptionInstance.IntRange(1, 16),
                    Math.clamp(VoxyCompat.configuredRenderDistanceChunks() / 32, 1, 16),
                    sections -> VoxyCompat.setConfiguredRenderDistanceChunks(sections * 32))
        };
    }

    /** Drop Voxy's generated proxy cache and start a bounded rebuild around the current camera. */
    public static Button voxyRefreshButton() {
        Button button = Button.builder(Component.translatable("caustica.options.voxy.refresh"), clicked -> {
            boolean reset = VoxyCompat.reset();
            RtDistantHorizonsTerrain.INSTANCE.requestFullRefresh();
            clicked.setMessage(Component.translatable(reset
                    ? "caustica.options.voxy.refresh.queued"
                    : "caustica.options.voxy.refresh.unavailable"));
        }).width(310).build();
        button.active = VoxyCompat.enabled() && Minecraft.getInstance().level != null;
        return button;
    }

    private static OptionInstance<Boolean> bool(String captionKey, BooleanSetting setting) {
        return OptionInstance.createBoolean(
            captionKey,
            OptionInstance.cachedConstantTooltip(Component.translatable(captionKey + ".tooltip")),
            setting.value(),
            setting::set);
    }
}
