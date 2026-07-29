package dev.comfyfluffy.caustica.client;

import dev.comfyfluffy.caustica.CausticaConfig;
import dev.comfyfluffy.caustica.mixin.OptionsSubScreenAccessor;
import net.minecraft.client.Options;
import net.minecraft.client.gui.components.OptionsList;
import net.minecraft.client.gui.screens.Screen;
import net.minecraft.client.gui.screens.options.OptionsSubScreen;
import net.minecraft.network.chat.Component;

/**
 * Dedicated "Ray Tracing Settings..." sub-screen, reached from a single button in the vanilla Video
 * Settings screen (see {@code VideoSettingsScreenMixin}).
 *
 * <p>Every toggle/slider that used to be injected straight into Video Settings — the general
 * path-tracing controls, Parallax Occlusion Mapping, clouds, ReSTIR lighting and tonemapping — lives
 * here instead, grouped under its own header. This keeps the vanilla screen at its normal length and
 * gives the (much larger) RT surface room to breathe.
 *
 * <p>{@link CausticaConfig#save()} on {@link #removed()} mirrors {@code VideoSettingsScreenMixin}'s own
 * save-on-close, so any setting changed here is persisted the same way whether the player reached it
 * through this screen or (for the handful of controls that remain there) Video Settings directly.
 */
public final class RtSettingsScreen extends OptionsSubScreen {
    private static final Component TITLE = Component.translatable("caustica.options.rt.settingsTitle");
    private static final Component GENERAL_HEADER = Component.translatable("caustica.options.rt.header");
    private static final Component POM_HEADER = Component.translatable("caustica.options.rt.pomHeader");
    private static final Component CLOUDS_HEADER = Component.translatable("caustica.options.rt.cloudsHeader");
    private static final Component LIGHTS_HEADER = Component.translatable("caustica.options.rt.lightsHeader");
    private static final Component TONEMAP_HEADER = Component.translatable("caustica.options.rt.tonemapHeader");

    public RtSettingsScreen(Screen parent, Options options) {
        super(parent, options, TITLE);
    }

    @Override
    protected void addOptions() {
        OptionsList list = ((OptionsSubScreenAccessor) (Object) this).getList();
        list.addHeader(GENERAL_HEADER);
        list.addSmall(RtVideoOptions.runtimeOptions());
        list.addHeader(POM_HEADER);
        list.addSmall(RtVideoOptions.pomOptions());
        list.addHeader(CLOUDS_HEADER);
        list.addSmall(RtVideoOptions.cloudOptions());
        list.addHeader(LIGHTS_HEADER);
        list.addSmall(RtVideoOptions.lightOptions());
        list.addHeader(TONEMAP_HEADER);
        list.addSmall(RtVideoOptions.tonemapOptions());
    }

    @Override
    public void removed() {
        super.removed();
        // Persist any RT settings the player changed in this screen to the TOML config, mirroring
        // VideoSettingsScreenMixin's own save-on-close for the controls left in the vanilla screen.
        CausticaConfig.save();
    }
}
