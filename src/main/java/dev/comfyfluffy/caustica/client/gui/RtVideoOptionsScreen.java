package dev.comfyfluffy.caustica.client.gui;

import dev.comfyfluffy.caustica.CausticaConfig;
import dev.comfyfluffy.caustica.client.RtVideoOptions;
import dev.comfyfluffy.caustica.compat.DistantHorizonsCompat;
import dev.comfyfluffy.caustica.compat.VoxyCompat;
import net.minecraft.client.Options;
import net.minecraft.client.gui.components.OptionsList;
import net.minecraft.client.gui.screens.Screen;
import net.minecraft.client.gui.screens.options.OptionsSubScreen;
import net.minecraft.network.chat.Component;

/**
 * Dedicated Ray Tracing settings sub-screen, opened from Video Settings via a single
 * "Ray Tracing Settings..." button. Keeps Video Settings clean and groups all Caustica controls
 * in one organized place.
 *
 * <p>Layout: Quality / General / Effects / Parallax / Clouds / HDR / Debug / DH / Voxy / Lighting / Tonemapping
 * Each section is a header + small options, with big buttons for refresh actions.
 *
 * <p>The Quality section starts with the upscaler selector, whose dependent rows (the quality slider and
 * the Frame Generation toggle) are rebuilt around the selected upscaler: changing the selector reopens
 * this screen ({@link #rebuildForUpscalerChange}) instead of leaving stale rows behind.
 *
 * <p>Config persistence: on removed() we call CausticaConfig.save() (same as VideoSettingsScreenMixin did).
 */
public class RtVideoOptionsScreen extends OptionsSubScreen {

    // Held locally (instead of relying on the superclass fields) so the screen can reopen itself with
    // the same parent/options when the upscaler selection rebuilds the option rows.
    private final Screen rtParent;
    private final Options rtOptions;

    // Title + section headers
    private static final Component TITLE = Component.translatable("caustica.options.rt.title");
    private static final Component QUALITY_HEADER = Component.translatable("caustica.options.rt.qualityHeader");
    private static final Component GENERAL_HEADER = Component.translatable("caustica.options.rt.generalHeader");
    private static final Component EFFECTS_HEADER = Component.translatable("caustica.options.rt.effectsHeader");
    private static final Component POM_HEADER = Component.translatable("caustica.options.rt.pomHeader");
    private static final Component CLOUDS_HEADER = Component.translatable("caustica.options.rt.cloudsHeader");
    private static final Component HDR_HEADER = Component.translatable("caustica.options.rt.hdrHeader");
    private static final Component DEBUG_HEADER = Component.translatable("caustica.options.rt.debugHeader");
    private static final Component DH_HEADER = Component.translatable("caustica.options.rt.dhHeader");
    private static final Component VOXY_HEADER = Component.translatable("caustica.options.voxy.header");
    private static final Component LIGHTS_HEADER = Component.translatable("caustica.options.rt.lightsHeader");
    private static final Component TONEMAP_HEADER = Component.translatable("caustica.options.rt.tonemapHeader");
    private static final Component EXPOSURE_HEADER = Component.translatable("caustica.options.rt.exposureHeader");
    private static final Component SHARC_HEADER = Component.translatable("caustica.options.sharc.header");

    public RtVideoOptionsScreen(Screen parent, Options options) {
        super(parent, options, TITLE);
        this.rtParent = parent;
        this.rtOptions = options;
    }

    /**
     * The upscaler selection changes which dependent rows exist (quality slider, Frame Generation
     * toggle): reopen this screen so the OptionsList rebuilds around the new mode. Config persistence
     * rides on removed(), which the reopen triggers, so the new selection is saved as well.
     */
    private void rebuildForUpscalerChange() {
        // In 26.2, setScreen moved from Minecraft to Gui (same call VideoSettingsScreenMixin uses).
        this.minecraft.gui.setScreen(new RtVideoOptionsScreen(this.rtParent, this.rtOptions));
    }

    @Override
    protected void addOptions() {
        if (!CausticaConfig.Rt.ENABLED.value()) {
            return;
        }
        OptionsList list = ((dev.comfyfluffy.caustica.mixin.OptionsSubScreenAccessor) (Object) this).getList();
        if (list == null) {
            return;
        }

        // --- Quality / Performance ---
        // The upscaler selector heads this section; the DLSS Frame Generation toggle (experimental,
        // greyed out with a tooltip on unsupported GPUs) follows it only while DLSS is selected —
        // it rides on the selected upscaler and switches together with it.
        list.addHeader(QUALITY_HEADER);
        list.addSmall(RtVideoOptions.qualityOptions(this::rebuildForUpscalerChange));
        net.minecraft.client.gui.components.Button frameGeneration =
                RtVideoOptions.frameGenerationButton(this::rebuildForUpscalerChange);
        if (frameGeneration != null) {
            list.addBig(frameGeneration);
        }
        net.minecraft.client.gui.components.Button fgMultiplier = RtVideoOptions.fgMultiplierButton();
        if (fgMultiplier != null) {
            list.addBig(fgMultiplier);
        }
        list.addBig(RtVideoOptions.reflexButton());

        // --- SHaRC (experimental) ---
        // Two big buttons: one to flip the experimental SHaRC on/off, one to open the full tuning
        // sub-screen. This mirrors how "Ray Tracing Settings..." opens this screen from Video Settings.
        list.addHeader(SHARC_HEADER);
        list.addBig(RtVideoOptions.sharcToggleButton(this::rebuildForUpscalerChange));
        list.addBig(RtVideoOptions.sharcSettingsButton(this));

        // --- General ---
        list.addHeader(GENERAL_HEADER);
        list.addSmall(RtVideoOptions.generalOptions());

        // --- Effects ---
        list.addHeader(EFFECTS_HEADER);
        list.addSmall(RtVideoOptions.effectsOptions());

        // --- Parallax / POM ---
        list.addHeader(POM_HEADER);
        list.addSmall(RtVideoOptions.pomOptions());

        // --- Clouds ---
        list.addHeader(CLOUDS_HEADER);
        list.addSmall(RtVideoOptions.cloudOptions());

        // --- HDR ---
        list.addHeader(HDR_HEADER);
        list.addSmall(RtVideoOptions.hdrOptions());

        // --- Debug ---
        list.addHeader(DEBUG_HEADER);
        list.addSmall(RtVideoOptions.debugOptions());

        // --- Distant Horizons (if present) ---
        if (DistantHorizonsCompat.enabled()) {
            list.addHeader(DH_HEADER);
            list.addBig(RtVideoOptions.distantHorizonsRefreshButton());
        }

        // --- Voxy LODs (if present) ---
        if (VoxyCompat.enabled()) {
            list.addHeader(VOXY_HEADER);
            list.addSmall(RtVideoOptions.voxyOptions());
            list.addBig(RtVideoOptions.voxyRefreshButton());
        }

        // --- Lighting ---
        list.addHeader(LIGHTS_HEADER);
        list.addSmall(RtVideoOptions.lightOptions());
        list.addBig(RtVideoOptions.restirSettingsButton(this));

        // --- Exposure + Tonemapping ---
        list.addHeader(EXPOSURE_HEADER);
        list.addSmall(RtVideoOptions.exposureOptions());

        list.addHeader(TONEMAP_HEADER);
        list.addSmall(RtVideoOptions.tonemapOptions());
    }

    @Override
    public void removed() {
        CausticaConfig.save();
        super.removed();
    }
}
