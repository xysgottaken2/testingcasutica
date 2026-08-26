package dev.comfyfluffy.caustica.client;

import com.mojang.serialization.Codec;
import dev.comfyfluffy.caustica.CausticaConfig;
import dev.comfyfluffy.caustica.CausticaConfig.BooleanSetting;
import dev.comfyfluffy.caustica.CausticaConfig.FloatSetting;
import dev.comfyfluffy.caustica.CausticaConfig.IntSetting;
import dev.comfyfluffy.caustica.CausticaConfig.StringSetting;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import dev.comfyfluffy.caustica.client.gui.RtRestirOptionsScreen;
import dev.comfyfluffy.caustica.client.gui.RtSharcOptionsScreen;
import dev.comfyfluffy.caustica.compat.DistantHorizonsCompat;
import dev.comfyfluffy.caustica.compat.VoxyCompat;
import dev.comfyfluffy.caustica.rt.RtComposite;
import dev.comfyfluffy.caustica.rt.RtSharc;
import dev.comfyfluffy.caustica.rt.terrain.RtDistantHorizonsTerrain;
import dev.comfyfluffy.caustica.rt.terrain.RtTerrain;
import net.minecraft.client.Minecraft;
import net.minecraft.client.OptionInstance;
import net.minecraft.client.Options;
import net.minecraft.client.gui.components.Button;
import net.minecraft.client.gui.components.Tooltip;
import net.minecraft.client.gui.screens.Screen;
import net.minecraft.network.chat.Component;

/**
 * Builds the {@link OptionInstance} widgets shown in the RT section of the vanilla Video Settings screen
 * (injected by {@code VideoSettingsScreenMixin}). Each option is bound straight to a {@link CausticaConfig}
 * runtime setting: the initial value is read from the current config, and the value-update listener writes
 * back through {@code set(...)} so changes take effect on the next frame.
 *
 * <p>Only settings the renderer re-reads per-frame — or can apply through a bounded rebuild — are
 * exposed here. Toggles that would require a device or buffer-pool rebuild (worker threads,
 * max-entity capacities, PBR material flags) are intentionally left to the {@code -Dcaustica.*}
 * startup surface. Two exceptions are handled specially: DLSS-RR quality recreates the RR feature
 * live on change (see {@code RtDlssRr}), and the opacity-micromap toggle is read at section BUILD
 * time and answered with a full terrain rebuild (see {@code omm()}), so both are safe to expose.
 *
 * <p>Upscaling group: {@link #qualityOptions(Runnable)} starts with the upscaler selector
 * (Off / DLSS, plus FSR 3 once its backend lands — see {@code RtUpscalerSupport}), and the rows that
 * depend on that selection — the quality slider and the Frame Generation toggle — are built from the
 * currently selected upscaler. Changing the selector reopens the screen through the supplied refresh
 * callback so those rows switch together with the upscaler instead of lagging one screen behind.
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
            waterOpacity(),
            // POM: the on/off toggle followed by its tuning sliders, shader-only and safe live.
            parallaxEnabled(),
            parallaxStrength(),
            parallaxSmoothing(),
            parallaxDistance(),
            // Grouped: the three new effect/quality toggles sit together, and OptionsList.addSmall
            // pairs them two per row, so they read as one block rather than scattered checkboxes.
            subsurfaceScattering(),
            fog(),
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
            dlssPreset(),
            hdrEnabled(),
            hdrPaperWhite(),
            hdrPeak(),
            debugView(),
        };
    }

    // ===== Organized groups for the dedicated RT settings screen =====

    /**
     * Quality section, headed by the upscaler selector. The selector's dependent rows — the quality
     * slider (DLSS modes today, FSR modes once that backend lands) and, via
     * {@link #frameGenerationButton()}, the Frame Generation toggle — are derived from the currently
     * selected upscaler; {@code upscalerChanged} reopens the screen so they switch together with it.
     * (The old standalone "Denoising Filter" toggle folded into the selector: Off is exactly the raw
     * full-resolution view the toggle used to select.)
     */
    public static OptionInstance<?>[] qualityOptions(Runnable upscalerChanged) {
        List<OptionInstance<?>> options = new ArrayList<>();
        options.add(spp());
        options.add(maxBounces());
        options.add(upscaler(upscalerChanged));
        String mode = RtUpscalerSupport.currentUpscalerMode();
        if (RtUpscalerSupport.MODE_DLSS.equals(mode)) {
            options.add(dlssQuality());
            options.add(dlssPreset());
        } else if (RtUpscalerSupport.MODE_FSR3.equals(mode)) {
            options.add(fsrQuality());
        } else if (RtUpscalerSupport.MODE_XESS.equals(mode)) {
            options.add(xessQuality());
        }
        // Denoiser rows, for every path except DLSS (Ray Reconstruction denoises internally, so it
        // owns the slot and neither row would do anything).
        //
        // The built-in SVGF is the only denoiser offered. REBLUR is no longer exposed: it kept its
        // own temporal history inside the library, so the reprojection fixes that cleaned up the
        // built-in path could not reach it, and it stayed blobby where SVGF is now stable. The
        // integration is left in the tree (the CI still builds the shim) but nothing turns it on.
        if (!RtUpscalerSupport.MODE_DLSS.equals(mode)) {
            options.add(svgfDenoiser());
        }
        options.add(omm());
        return options.toArray(OptionInstance<?>[]::new);
    }

    public static OptionInstance<?>[] generalOptions() {
        return new OptionInstance<?>[] {
            sunSize(),
            entities(),
            particles(),
            weatherParticles(),
            rainDensity(),
            waterWaves(),
            waterOpacity(),
            handFov(),
        };
    }

    public static OptionInstance<?>[] effectsOptions() {
        return new OptionInstance<?>[] {
            subsurfaceScattering(),
            fog(),
            weatherLighting(),
            metallicShininess(),
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
     * Light-emission and sampling options. {@code heldItemLight} toggles the analytic light a luminous
     * held item casts; {@code dynamicIntensity} scales that light and other dynamic emitters. Both take
     * effect the frame after they change.
     */
    public static OptionInstance<?>[] lightOptions() {
        return new OptionInstance<?>[] {
            heldItemLight(),
            blockEmissiveIntensity(),
            dynamicIntensity(),
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

    /** Held-item / dynamic emitter brightness. Same 0x..16x domain as the block-emissive slider. */
    private static OptionInstance<Integer> dynamicIntensity() {
        return multiplier("caustica.options.rt.dynamicIntensity",
                CausticaConfig.Rt.Lights.DYNAMIC_INTENSITY, 0, 160);
    }

    /** Master toggle for the analytic light a luminous held item casts (torch in a cave, ...). */
    private static OptionInstance<Boolean> heldItemLight() {
        return bool("caustica.options.rt.heldItemLight", CausticaConfig.Rt.Lights.HELD_ITEM_LIGHT);
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

    private static OptionInstance<Integer> rainDensity() {
        return percent("caustica.options.rt.rainDensity", CausticaConfig.Rt.Entities.RAIN_DENSITY);
    }

    private static OptionInstance<Boolean> waterWaves() {
        return bool("caustica.options.rt.waterWaves", CausticaConfig.Rt.Composite.WATER_WAVES);
    }

    /**
     * How opaque ray-traced water is, as a percentage. 0% keeps the default near-crystal clarity;
     * 100% makes a one-block column transmit under 2% of what is behind it. Mostly a mitigation
     * control: DLSS Ray Reconstruction can draw a halo around translucent water in dark scenes,
     * and dimming the transmitted light through the water is what removes it.
     */
    private static OptionInstance<Integer> waterOpacity() {
        return percent("caustica.options.rt.waterOpacity", CausticaConfig.Rt.Composite.WATER_OPACITY);
    }

    /**
     * LabPBR subsurface scattering: backlit foliage glow. Only materials that author an SSS channel are
     * affected, but each eligible shading vertex costs an extra shadow ray, so this is a real
     * performance lever in dense vegetation.
     */
    private static OptionInstance<Boolean> subsurfaceScattering() {
        return bool("caustica.options.rt.sss", CausticaConfig.Rt.Composite.SSS);
    }

    /** Selective outdoor distance fog; cave and indoor pixels are excluded by a depth/sky mask. */
    private static OptionInstance<Boolean> fog() {
        return bool("caustica.options.rt.fog", CausticaConfig.Rt.Composite.FOG);
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

    private static final List<Integer> DLSS_PRESET_ORDER = List.of(0, 6);

    private static OptionInstance<Integer> dlssPreset() {
        IntSetting setting = CausticaConfig.Rt.DlssRr.PRESET;
        int initialPreset = DLSS_PRESET_ORDER.contains(setting.value()) ? setting.value() : 0;
        int initialPosition = DLSS_PRESET_ORDER.indexOf(initialPreset);
        return new OptionInstance<>(
            "caustica.options.rt.dlssPreset",
            OptionInstance.cachedConstantTooltip(Component.translatable("caustica.options.rt.dlssPreset.tooltip")),
            (caption, position) -> Options.genericValueLabel(caption,
                    Component.translatable("caustica.options.rt.dlssPreset." + DLSS_PRESET_ORDER.get(position))),
            new OptionInstance.IntRange(0, DLSS_PRESET_ORDER.size() - 1),
            initialPosition,
            position -> setting.set(DLSS_PRESET_ORDER.get(position)));
    }

    /**
     * The upscaler selector: Off (native-resolution trace) / DLSS (Ray Reconstruction denoise + upscale),
     * plus FSR 3 once its backend reports available (see {@code RtUpscalerSupport.fsrUpscalingAvailable}).
     * Selection maps onto the existing backend switches ({@code dlss-rr.enabled} / {@code fsr.enabled})
     * rather than a new setting, so every renderer-side check keeps one source of truth, and the screen
     * rebuilds through {@code onChanged} so the quality slider and Frame Generation toggle switch together
     * with the selected upscaler.
     */
    private static OptionInstance<String> upscaler(Runnable onChanged) {
        List<String> values = RtUpscalerSupport.upscalerValues();
        String initial = RtUpscalerSupport.currentUpscalerMode();
        if (!values.contains(initial)) {
            // e.g. fsr.enabled hand-set in the config while no FSR backend is bundled yet: display the
            // backend that is actually driving the image (DLSS if it is on), not a mode that cannot run.
            initial = CausticaConfig.Rt.DlssRr.ENABLED.value()
                    ? RtUpscalerSupport.MODE_DLSS : RtUpscalerSupport.MODE_NONE;
        }
        return new OptionInstance<>(
            "caustica.options.rt.upscaler",
            OptionInstance.cachedConstantTooltip(Component.translatable("caustica.options.rt.upscaler.tooltip")),
            // CycleButton (used for Enum values) already prepends "caption: " itself, so this must return
            // only the value's text, not caption + value again.
            (caption, value) -> Component.translatable("caustica.options.rt.upscaler." + value),
            new OptionInstance.Enum<>(values, Codec.STRING),
            initial,
            value -> {
                RtUpscalerSupport.applyUpscalerMode(value);
                onChanged.run();
            });
    }

    // Same PerfQuality vocabulary as DLSS (the FSR 3 upscaler uses the same mode scale), so this row
    // reuses the dlssQuality value-name keys. Reachable only once the selector offers FSR 3 —
    // RtUpscalerSupport.fsrUpscalingAvailable() (the bundled FidelityFX runtime) decides that.
    private static final List<Integer> FSR_QUALITY_ORDER = List.of(3, 0, 1, 2, 5);

    private static OptionInstance<Integer> fsrQuality() {
        IntSetting setting = CausticaConfig.Rt.Fsr.QUALITY;
        int initialQuality = FSR_QUALITY_ORDER.contains(setting.value()) ? setting.value() : 2;
        int initialPosition = FSR_QUALITY_ORDER.indexOf(initialQuality);
        return new OptionInstance<>(
            "caustica.options.rt.fsrQuality",
            OptionInstance.cachedConstantTooltip(Component.translatable("caustica.options.rt.fsrQuality.tooltip")),
            (caption, position) -> Options.genericValueLabel(caption,
                    Component.translatable("caustica.options.rt.dlssQuality." + FSR_QUALITY_ORDER.get(position))),
            new OptionInstance.IntRange(0, FSR_QUALITY_ORDER.size() - 1),
            initialPosition,
            position -> setting.set(FSR_QUALITY_ORDER.get(position)));
    }

    // Same shared PerfQuality vocabulary as DLSS/FSR (XeSS maps the same ratios onto its own
    // xess_quality_settings_t). Reachable only once the selector offers XeSS — the bundled Intel
    // runtime + the XeSS device features on the GPU decide that (RtUpscalerSupport).
    private static final List<Integer> XESS_QUALITY_ORDER = List.of(3, 0, 1, 2, 5);

    private static OptionInstance<Integer> xessQuality() {
        IntSetting setting = CausticaConfig.Rt.Xess.QUALITY;
        int initialQuality = XESS_QUALITY_ORDER.contains(setting.value()) ? setting.value() : 2;
        int initialPosition = XESS_QUALITY_ORDER.indexOf(initialQuality);
        return new OptionInstance<>(
            "caustica.options.rt.xessQuality",
            OptionInstance.cachedConstantTooltip(Component.translatable("caustica.options.rt.xessQuality.tooltip")),
            (caption, position) -> Options.genericValueLabel(caption,
                    Component.translatable("caustica.options.rt.dlssQuality." + XESS_QUALITY_ORDER.get(position))),
            new OptionInstance.IntRange(0, XESS_QUALITY_ORDER.size() - 1),
            initialPosition,
            position -> setting.set(XESS_QUALITY_ORDER.get(position)));
    }

    /**
     * The built-in denoiser (SVGF) toggle. Live-safe like the other per-frame toggles: flipping it
     * re-keys {@code RtComposite.ensureOutput}, which allocates or releases the history/moment
     * targets on the rebuild, and the tracer picks the feature flag up on the next frame.
     */
    private static OptionInstance<Boolean> svgfDenoiser() {
        return bool("caustica.options.rt.denoise", CausticaConfig.Rt.Denoise.ENABLED);
    }

    /**
     * The Frame Generation toggle (EXPERIMENTAL). Rides on the selected upscaler: DLSS mode toggles
     * DLSS-G (hardware-gated: unsupported GPUs get a greyed-out button that stays visible so its
     * tooltip can explain the requirement), FSR 3 AND XeSS modes toggle FSR 3.1 FG (no hardware
     * gate beyond the bundled FSR runtime — Intel's own XeSS-FG is D3D12-only, so the FFX engine
     * is the frame-gen for the XeSS path too). Returns null on every other path.
     */
    public static Button frameGenerationButton(Runnable onChanged) {
        String mode = RtUpscalerSupport.currentUpscalerMode();
        if (RtUpscalerSupport.MODE_FSR3.equals(mode) || RtUpscalerSupport.MODE_XESS.equals(mode)) {
            CausticaConfig.BooleanSetting setting = CausticaConfig.Rt.Fg.ENABLED;
            Button button = Button.builder(frameGenerationLabel(), clicked -> {
                setting.set(!setting.value());
                clicked.setMessage(frameGenerationLabel());
                // The multiplier row only exists while FG is on (and the engine's cap changes with
                // the active backend): rebuild the screen around the new state instead of making the
                // player close and reopen the menu to see/hide it.
                onChanged.run();
            }).width(310).build();
            button.setTooltip(Tooltip.create(
                    Component.translatable("caustica.options.rt.frameGeneration.fsr.tooltip")));
            return button;
        }
        if (!RtUpscalerSupport.MODE_DLSS.equals(mode)) {
            return null;
        }
        CausticaConfig.BooleanSetting setting = CausticaConfig.Rt.Fg.ENABLED;
        boolean supported = RtUpscalerSupport.dlssFrameGenerationSupported();
        // DLSS-G hardware (RTX 40/50) uses the vendor engine; every other GPU falls back to the
        // Caustica native engine instead of greying the toggle out (the old "unsupported" state).
        Button button = Button.builder(frameGenerationLabel(), clicked -> {
            setting.set(!setting.value());
            clicked.setMessage(frameGenerationLabel());
            onChanged.run(); // same rebuild reason as above
        }).width(310).build();
        button.setTooltip(Tooltip.create(Component.translatable(supported
                ? "caustica.options.rt.frameGeneration.tooltip"
                : "caustica.options.rt.frameGeneration.nativeFallback.tooltip")));
        return button;
    }

    private static Component frameGenerationLabel() {
        return Options.genericValueLabel(
                Component.translatable("caustica.options.rt.frameGeneration"),
                Component.translatable(CausticaConfig.Rt.Fg.ENABLED.value() ? "options.on" : "options.off"));
    }

    /**
     * Generated-frame counts the ACTIVE backend can really produce. DLSS-G offers 1..driver MFG cap
     * (probed from NGX). The Caustica native engine (default on the FSR 3 / XeSS paths) offers
     * 1..its cap — it interpolates with the tracer's own motion vectors, so every slot is a real
     * frame. The FSR 3.1 runtime fallback offers exactly one: it only ever writes outputs[0] per
     * dispatch (see RtFsrFrameGen.MAX_GENERATED_FRAMES) — offering more there was presenting
     * never-written frames (the black blink + colorful corruption of the 3x+ era).
     */
    private static int[] fgMultiplierOptions() {
        String mode = RtUpscalerSupport.currentUpscalerMode();
        if (RtUpscalerSupport.MODE_DLSS.equals(mode)) {
            int max = dev.comfyfluffy.caustica.rt.pipeline.RtDlssFg.INSTANCE.multiFrameCountMax();
            if (max > 1) {
                int[] options = new int[max];
                for (int i = 0; i < max; i++) {
                    options[i] = i + 1;
                }
                return options;
            }
        }
        if (dev.comfyfluffy.caustica.rt.pipeline.RtNativeFrameGen.enabled()) {
            int max = dev.comfyfluffy.caustica.rt.pipeline.RtNativeFrameGen.MAX_GENERATED_FRAMES;
            int[] options = new int[max];
            for (int i = 0; i < max; i++) {
                options[i] = i + 1;
            }
            return options;
        }
        return new int[] { 1 };
    }

    /**
     * The FG multiplier selector: how many frames the display receives per rendered frame. Visible
     * alongside {@link #frameGenerationButton()} ONLY when the active backend genuinely supports
     * more than one generated frame (DLSS Multi Frame Generation on supporting drivers) — on the
     * FSR 3 / XeSS path the multiplier is fixed at 2x by the engine, so the button is omitted
     * instead of pretending there's a choice.
     */
    public static Button fgMultiplierButton() {
        String mode = RtUpscalerSupport.currentUpscalerMode();
        if (!RtUpscalerSupport.MODE_DLSS.equals(mode) && !RtUpscalerSupport.MODE_FSR3.equals(mode)
                && !RtUpscalerSupport.MODE_XESS.equals(mode)) {
            return null;
        }
        int[] options = fgMultiplierOptions();
        if (options.length < 2) {
            return null; // fixed multiplier on this backend — nothing to cycle through
        }
        CausticaConfig.IntSetting setting = CausticaConfig.Rt.Fg.MULTI_FRAME_COUNT;
        Button button = Button.builder(fgMultiplierLabel(), clicked -> {
            int current = setting.value();
            int idx = 0;
            for (int i = 0; i < options.length; i++) {
                if (options[i] == current) {
                    idx = i;
                    break;
                }
            }
            setting.set(options[(idx + 1) % options.length]);
            clicked.setMessage(fgMultiplierLabel());
        }).width(310).build();
        button.setTooltip(Tooltip.create(Component.translatable("caustica.options.rt.fgMultiplier.tooltip")));
        return button;
    }

    private static Component fgMultiplierLabel() {
        // Show the EFFECTIVE multiplier (config clamped to what the backend can produce), so a stale
        // high config value from a previous build doesn't mislead. Native engine first: it wins
        // wherever it's active (FSR 3 / XeSS default, and the DLSS-path fallback on non-DLSS-G GPUs).
        int effective;
        if (dev.comfyfluffy.caustica.rt.pipeline.RtNativeFrameGen.enabled()) {
            effective = dev.comfyfluffy.caustica.rt.pipeline.RtNativeFrameGen.INSTANCE.effectiveGeneratedCount();
        } else if (RtUpscalerSupport.MODE_DLSS.equals(RtUpscalerSupport.currentUpscalerMode())) {
            effective = dev.comfyfluffy.caustica.rt.pipeline.RtDlssFg.INSTANCE.effectiveMultiFrameCount();
        } else {
            effective = dev.comfyfluffy.caustica.rt.pipeline.RtFsrFrameGen.INSTANCE.effectiveGeneratedCount();
        }
        return Options.genericValueLabel(
                Component.translatable("caustica.options.rt.fgMultiplier"),
                Component.literal((effective + 1) + "x"));
    }

    /**
     * NVIDIA Reflex (VK_NV_low_latency2) toggle: driver-paced frame submission that cuts input
     * latency — the natural pairing with frame generation (FG always costs ~one rendered frame of
     * latency; Reflex removes the rest of the pipeline queue). Greyed out with a tooltip on devices
     * without the extension; engages live (the pacing loop self-applies sleep mode on the next
     * frame), no restart needed.
     */
    public static Button reflexButton() {
        CausticaConfig.BooleanSetting setting = CausticaConfig.Rt.Reflex.ENABLED;
        boolean supported = dev.comfyfluffy.caustica.rt.RtDeviceBringup.reflexEnabled();
        Button button = Button.builder(reflexLabel(), clicked -> {
            setting.set(!setting.value());
            clicked.setMessage(reflexLabel());
        }).width(310).build();
        button.active = supported;
        button.setTooltip(Tooltip.create(Component.translatable(supported
                ? "caustica.options.rt.reflex.tooltip"
                : "caustica.options.rt.reflex.unsupported.tooltip")));
        return button;
    }

    private static Component reflexLabel() {
        return Options.genericValueLabel(
                Component.translatable("caustica.options.rt.reflex"),
                Component.translatable(CausticaConfig.Rt.Reflex.ENABLED.value() ? "options.on" : "options.off"));
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
            // 10-12 inspect the SVGF denoiser's internal state and, unlike 1-7, leave the denoiser
            // running (see RtComposite.SVGF_DEBUG_FIRST). 8/9 are not exposed here. 13 is the SHaRC
            // cache query overlay (see sharc.slang): pass B paints it so it reflects real queries.
            new OptionInstance.Enum<>(List.of(0, 1, 2, 3, 4, 5, 6, 7, 10, 11, 12, 13), Codec.INT),
            Math.clamp(setting.value(), 0, 13),
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
    private static OptionInstance<Integer> metallicShininess() {
        return percent("caustica.options.rt.metallicShininess", CausticaConfig.Rt.Composite.METALLIC_SHININESS);
    }

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

    /**
     * Opacity micromaps for terrain cutout (grass, leaves...). Unlike the plain {@link #bool} toggles,
     * flipping this cannot take effect "next frame": already-built BLASes keep the state they were
     * built with, so the change handler requests a full terrain rebuild and every section re-meshes
     * under the new gate — the same mechanism F3+A uses, so nothing about it is OMM-specific.
     *
     * <p>One asymmetry the tooltip spells out: the underlying Vulkan feature is latched at RT device
     * bring-up, so a toggle that was OFF at launch only gains device support once the device is
     * recreated (re-entering a world). Turning it OFF works immediately in every case.
     */
    private static OptionInstance<Boolean> omm() {
        return OptionInstance.createBoolean(
            "caustica.options.rt.omm",
            OptionInstance.cachedConstantTooltip(Component.translatable("caustica.options.rt.omm.tooltip")),
            CausticaConfig.Rt.Omm.ENABLED.value(),
            value -> {
                CausticaConfig.Rt.Omm.ENABLED.set(value);
                RtTerrain.requestFullClear();
            });
    }

    // ===== Experimental SHaRC (Spatially Hashed Radiance Cache) =====

    /**
     * All SHaRC tuning rows. They ride in the dedicated {@link RtSharcOptionsScreen} so the main RT
     * screen stays compact: the experimental enable toggle + the "SHaRC Settings..." button live there,
     * while this list holds the fine-grained cache knobs.
     */
    public static OptionInstance<?>[] sharcOptions() {
        return new OptionInstance<?>[] {
            sharcCellSize(),
            sharcCacheEntries(),
            sharcUpdateCoverage(),
            sharcTemporalBlend(),
            sharcStartBounce(),
            sharcStrength(),
            sharcFrameLifetime(),
            sharcNormalThreshold(),
            sharcStableFrames(),
            sharcDebug(),
        };
    }

    private static OptionInstance<Boolean> sharcDebug() {
        return bool("caustica.options.sharc.debug", CausticaConfig.Rt.Sharc.DEBUG);
    }

    private static OptionInstance<Integer> sharcCellSize() {
        FloatSetting setting = CausticaConfig.Rt.Sharc.CELL_SIZE;
        return new OptionInstance<>(
            "caustica.options.sharc.cellSize",
            OptionInstance.cachedConstantTooltip(Component.translatable("caustica.options.sharc.cellSize.tooltip")),
            (caption, blocks) -> Options.genericValueLabel(caption, Component.literal(blocks + " blocks")),
            new OptionInstance.IntRange(1, 64),
            Math.clamp(Math.round(setting.value()), 1, 64),
            blocks -> setting.set(blocks.floatValue()));
    }

    private static OptionInstance<Integer> sharcCacheEntries() {
        IntSetting setting = CausticaConfig.Rt.Sharc.CACHE_ENTRIES;
        int minShift = 11; // 2048
        int maxShift = 20; // 1048576
        int initial = Math.clamp(31 - Integer.numberOfLeadingZeros(setting.value()), minShift, maxShift);
        return new OptionInstance<>(
            "caustica.options.sharc.cacheEntries",
            OptionInstance.cachedConstantTooltip(Component.translatable("caustica.options.sharc.cacheEntries.tooltip")),
            (caption, shift) -> Options.genericValueLabel(caption,
                    Component.literal((1 << shift) + " entries")),
            new OptionInstance.IntRange(minShift, maxShift),
            initial,
            shift -> setting.set(1 << shift));
    }

    private static OptionInstance<Integer> sharcUpdateCoverage() {
        return percent("caustica.options.sharc.updateCoverage", CausticaConfig.Rt.Sharc.UPDATE_COVERAGE);
    }

    private static OptionInstance<Integer> sharcTemporalBlend() {
        return percent("caustica.options.sharc.temporalBlend", CausticaConfig.Rt.Sharc.TEMPORAL_BLEND);
    }

    private static OptionInstance<Integer> sharcStartBounce() {
        IntSetting setting = CausticaConfig.Rt.Sharc.START_BOUNCE;
        return new OptionInstance<>(
            "caustica.options.sharc.startBounce",
            OptionInstance.cachedConstantTooltip(Component.translatable("caustica.options.sharc.startBounce.tooltip")),
            (caption, value) -> Options.genericValueLabel(caption, value),
            new OptionInstance.IntRange(1, 6),
            Math.clamp(setting.value(), 1, 6),
            setting::set);
    }

    private static OptionInstance<Integer> sharcStrength() {
        return percent("caustica.options.sharc.strength", CausticaConfig.Rt.Sharc.STRENGTH);
    }

    private static OptionInstance<Integer> sharcFrameLifetime() {
        IntSetting setting = CausticaConfig.Rt.Sharc.FRAME_LIFETIME;
        return new OptionInstance<>(
            "caustica.options.sharc.frameLifetime",
            OptionInstance.cachedConstantTooltip(Component.translatable("caustica.options.sharc.frameLifetime.tooltip")),
            (caption, value) -> Options.genericValueLabel(caption,
                    Component.literal(value + " frames")),
            new OptionInstance.IntRange(1, 240),
            Math.clamp(setting.value(), 1, 240),
            setting::set);
    }

    private static OptionInstance<Integer> sharcNormalThreshold() {
        return percent("caustica.options.sharc.normalThreshold", CausticaConfig.Rt.Sharc.NORMAL_THRESHOLD);
    }

    private static OptionInstance<Integer> sharcStableFrames() {
        IntSetting setting = CausticaConfig.Rt.Sharc.STABLE_FRAMES;
        return new OptionInstance<>(
            "caustica.options.sharc.stableFrames",
            OptionInstance.cachedConstantTooltip(Component.translatable("caustica.options.sharc.stableFrames.tooltip")),
            (caption, value) -> Options.genericValueLabel(caption,
                    Component.literal(value + " samples")),
            new OptionInstance.IntRange(0, 30),
            Math.clamp(setting.value(), 0, 30),
            setting::set);
    }

    /** Big experimental enable/disable toggle, shown on both the RT screen and the SHaRC sub-screen. */
    public static Button sharcToggleButton() {
        return sharcToggleButton(null);
    }

    /**
     * Same toggle with an optional {@code onChanged} callback. The main RT screen passes a rebuild so
     * the button label (and any dependent rows) stay in sync; the SHaRC sub-screen passes nothing and
     * simply updates its own label.
     */
    public static Button sharcToggleButton(Runnable onChanged) {
        Button button = Button.builder(sharcToggleLabel(), clicked -> {
            CausticaConfig.BooleanSetting setting = CausticaConfig.Rt.Sharc.ENABLED;
            setting.set(!setting.value());
            clicked.setMessage(sharcToggleLabel());
            if (onChanged != null) {
                onChanged.run();
            }
        }).width(310).build();
        button.setTooltip(Tooltip.create(
                Component.translatable("caustica.options.sharc.enabled.tooltip")));
        return button;
    }

    private static Component sharcToggleLabel() {
        return Options.genericValueLabel(
                Component.translatable("caustica.options.sharc.enabled"),
                Component.translatable(CausticaConfig.Rt.Sharc.ENABLED.value() ? "options.on" : "options.off"));
    }

    /** Opens the dedicated SHaRC customization sub-screen (same pattern as "Ray Tracing Settings..."). */
    public static Button sharcSettingsButton(Screen parent) {
        return Button.builder(Component.translatable("caustica.options.sharc.settingsButton"), clicked -> {
            Minecraft minecraft = Minecraft.getInstance();
            minecraft.gui.setScreen(new RtSharcOptionsScreen(parent, minecraft.options));
        }).width(310).build();
    }

    /** Drops every cached radiance entry. The shader feature bit simply reads a cleared buffer next frame. */
    public static Button sharcResetButton() {
        Button button = Button.builder(Component.translatable("caustica.options.sharc.reset"), clicked -> {
            RtSharc.INSTANCE.requestClear();
            clicked.setMessage(Component.translatable("caustica.options.sharc.reset.queued"));
        }).width(310).build();
        button.setTooltip(Tooltip.create(
                Component.translatable("caustica.options.sharc.reset.tooltip")));
        return button;
    }

    // ===== ReSTIR DI / GRIS (ultra-stable reservoir reuse) =====

    /**
     * Temporal-reuse knobs for the dedicated {@link RtRestirOptionsScreen}. These are the main
     * anti-flicker levers: a high temporal M-cap so history dominates, stickiness so a torch stays
     * a torch, and a temporal W blend so intensity does not jump every frame.
     */
    public static OptionInstance<?>[] restirTemporalOptions() {
        return new OptionInstance<?>[] {
            restirTemporalReuse(),
            restirFreshCandidates(),
            restirCurrentMCap(),
            restirTemporalMCap(),
            restirMaxM(),
            restirMaxAge(),
            restirStickiness(),
            restirTemporalBlend(),
            restirTemporalPos(),
            restirTemporalNormal(),
        };
    }

    /** Spatial-reuse knobs. Defaults are conservative: small radius, tiny M-cap, hole-filling only. */
    public static OptionInstance<?>[] restirSpatialOptions() {
        return new OptionInstance<?>[] {
            restirSpatialReuse(),
            restirSpatialSamples(),
            restirSpatialRadius(),
            restirSpatialMCap(),
            restirSpatialPos(),
            restirSpatialNormal(),
        };
    }

    /** Safety / estimator bounds and the light-hierarchy invalidation toggle. */
    public static OptionInstance<?>[] restirSafetyOptions() {
        return new OptionInstance<?>[] {
            restirMaxW(),
            restirMaxLuminance(),
            restirJacobianMin(),
            restirJacobianMax(),
            restirInvalidateOnLightChange(),
        };
    }

    public static Button restirToggleButton() {
        Button button = Button.builder(restirToggleLabel(), clicked -> {
            CausticaConfig.BooleanSetting setting = CausticaConfig.Rt.Lights.RESTIR_SAMPLING;
            setting.set(!setting.value());
            clicked.setMessage(restirToggleLabel());
        }).width(310).build();
        button.setTooltip(Tooltip.create(
                Component.translatable("caustica.options.rt.restirSampling.tooltip")));
        return button;
    }

    private static Component restirToggleLabel() {
        return Options.genericValueLabel(
                Component.translatable("caustica.options.rt.restirSampling"),
                Component.translatable(CausticaConfig.Rt.Lights.RESTIR_SAMPLING.value()
                        ? "options.on" : "options.off"));
    }

    /** Opens the dedicated ReSTIR customization sub-screen. */
    public static Button restirSettingsButton(Screen parent) {
        return Button.builder(Component.translatable("caustica.options.restir.settingsButton"), clicked -> {
            Minecraft minecraft = Minecraft.getInstance();
            minecraft.gui.setScreen(new RtRestirOptionsScreen(parent, minecraft.options));
        }).width(310).build();
    }

    /** Zero-fills both ReSTIR ping-pong buffers next frame. */
    public static Button restirResetButton() {
        Button button = Button.builder(Component.translatable("caustica.options.restir.reset"), clicked -> {
            RtComposite.INSTANCE.requestRestirClear();
            clicked.setMessage(Component.translatable("caustica.options.restir.reset.queued"));
        }).width(310).build();
        button.setTooltip(Tooltip.create(
                Component.translatable("caustica.options.restir.reset.tooltip")));
        return button;
    }

    private static OptionInstance<Boolean> restirTemporalReuse() {
        return bool("caustica.options.restir.temporalReuse", CausticaConfig.Rt.Restir.TEMPORAL_REUSE);
    }

    private static OptionInstance<Boolean> restirSpatialReuse() {
        return bool("caustica.options.restir.spatialReuse", CausticaConfig.Rt.Restir.SPATIAL_REUSE);
    }

    private static OptionInstance<Boolean> restirInvalidateOnLightChange() {
        return bool("caustica.options.restir.invalidateOnLightChange",
                CausticaConfig.Rt.Restir.INVALIDATE_ON_LIGHT_CHANGE);
    }

    private static OptionInstance<Integer> restirFreshCandidates() {
        return intTicks("caustica.options.restir.freshCandidates",
                CausticaConfig.Rt.Restir.FRESH_CANDIDATES, 1, 16, null);
    }

    private static OptionInstance<Integer> restirCurrentMCap() {
        return intTicks("caustica.options.restir.currentMCap",
                CausticaConfig.Rt.Restir.CURRENT_M_CAP, 1, 16, null);
    }

    private static OptionInstance<Integer> restirTemporalMCap() {
        return intTicks("caustica.options.restir.temporalMCap",
                CausticaConfig.Rt.Restir.TEMPORAL_M_CAP, 1, 64, null);
    }

    private static OptionInstance<Integer> restirSpatialMCap() {
        return intTicks("caustica.options.restir.spatialMCap",
                CausticaConfig.Rt.Restir.SPATIAL_M_CAP, 0, 16, null);
    }

    private static OptionInstance<Integer> restirMaxM() {
        return intTicks("caustica.options.restir.maxM",
                CausticaConfig.Rt.Restir.MAX_M, 8, 64, null);
    }

    private static OptionInstance<Integer> restirMaxAge() {
        return intTicks("caustica.options.restir.maxAge",
                CausticaConfig.Rt.Restir.MAX_AGE, 1, 120, " frames");
    }

    private static OptionInstance<Integer> restirSpatialSamples() {
        return intTicks("caustica.options.restir.spatialSamples",
                CausticaConfig.Rt.Restir.SPATIAL_SAMPLES, 0, 8, null);
    }

    private static OptionInstance<Integer> restirSpatialRadius() {
        return intTicks("caustica.options.restir.spatialRadius",
                CausticaConfig.Rt.Restir.SPATIAL_RADIUS, 1, 32, " px");
    }

    private static OptionInstance<Integer> restirMaxW() {
        return intTicks("caustica.options.restir.maxW",
                CausticaConfig.Rt.Restir.MAX_W, 1, 64, null);
    }

    private static OptionInstance<Integer> restirMaxLuminance() {
        return intTicks("caustica.options.restir.maxLuminance",
                CausticaConfig.Rt.Restir.MAX_LUMINANCE, 1, 64, null);
    }

    private static OptionInstance<Integer> restirStickiness() {
        return percent("caustica.options.restir.stickiness", CausticaConfig.Rt.Restir.STICKINESS);
    }

    private static OptionInstance<Integer> restirTemporalBlend() {
        return percent("caustica.options.restir.temporalBlend", CausticaConfig.Rt.Restir.TEMPORAL_BLEND);
    }

    private static OptionInstance<Integer> restirTemporalNormal() {
        return percentRange("caustica.options.restir.temporalNormal",
                CausticaConfig.Rt.Restir.TEMPORAL_NORMAL, 50, 100);
    }

    private static OptionInstance<Integer> restirSpatialNormal() {
        return percentRange("caustica.options.restir.spatialNormal",
                CausticaConfig.Rt.Restir.SPATIAL_NORMAL, 50, 100);
    }

    private static OptionInstance<Integer> restirTemporalPos() {
        return hundredths("caustica.options.restir.temporalPos",
                CausticaConfig.Rt.Restir.TEMPORAL_POS, 5, 200);
    }

    private static OptionInstance<Integer> restirSpatialPos() {
        return hundredths("caustica.options.restir.spatialPos",
                CausticaConfig.Rt.Restir.SPATIAL_POS, 25, 800);
    }

    private static OptionInstance<Integer> restirJacobianMin() {
        return hundredths("caustica.options.restir.jacobianMin",
                CausticaConfig.Rt.Restir.JACOBIAN_MIN, 5, 100);
    }

    private static OptionInstance<Integer> restirJacobianMax() {
        return tenths("caustica.options.restir.jacobianMax",
                CausticaConfig.Rt.Restir.JACOBIAN_MAX, 10, 200);
    }

    private static OptionInstance<Integer> intTicks(String captionKey, IntSetting setting,
                                                    int min, int max, String unit) {
        return new OptionInstance<>(
            captionKey,
            OptionInstance.cachedConstantTooltip(Component.translatable(captionKey + ".tooltip")),
            (caption, value) -> Options.genericValueLabel(caption,
                    unit == null ? Component.literal(Integer.toString(value))
                            : Component.literal(value + unit)),
            new OptionInstance.IntRange(min, max),
            Math.clamp(setting.value(), min, max),
            setting::set);
    }

    private static OptionInstance<Integer> percentRange(String captionKey, FloatSetting setting,
                                                        int min, int max) {
        return new OptionInstance<>(
            captionKey,
            OptionInstance.cachedConstantTooltip(Component.translatable(captionKey + ".tooltip")),
            (caption, value) -> Options.genericValueLabel(caption, Component.literal(value + "%")),
            new OptionInstance.IntRange(min, max),
            Math.clamp(Math.round(setting.value() * 100.0f), min, max),
            value -> setting.set(value / 100.0f));
    }

    private static OptionInstance<Integer> tenths(String captionKey, FloatSetting setting, int min, int max) {
        return new OptionInstance<>(
            captionKey,
            OptionInstance.cachedConstantTooltip(Component.translatable(captionKey + ".tooltip")),
            (caption, tenths) -> Options.genericValueLabel(caption,
                    Component.literal(String.format(Locale.ROOT, "%.1f", tenths / 10.0f))),
            new OptionInstance.IntRange(min, max),
            Math.clamp(Math.round(setting.value() * 10.0f), min, max),
            tenths -> setting.set(tenths / 10.0f));
    }
}
