package dev.comfyfluffy.caustica.client;

import dev.comfyfluffy.caustica.CausticaConfig;
import dev.comfyfluffy.caustica.compat.VoxyCompat;
import net.minecraft.client.Options;
import net.minecraft.client.gui.components.Button;
import net.minecraft.client.gui.components.OptionsList;
import net.minecraft.client.gui.screens.Screen;
import net.minecraft.network.chat.Component;

/**
 * Dedicated screen for all Caustica Ray Tracing settings, organized by category.
 * Opened from the Video Settings screen via the single "Ray Tracing Settings..." button.
 */
public class CausticaRtScreen extends Screen {
    private static final Component TITLE = Component.translatable("caustica.options.rt.screenTitle");
    private static final Component RT_HEADER = Component.translatable("caustica.options.rt.header");
    private static final Component RT_LIGHTS_HEADER = Component.translatable("caustica.options.rt.lightsHeader");
    private static final Component RT_TONEMAP_HEADER = Component.translatable("caustica.options.rt.tonemapHeader");
    private static final Component VOXY_HEADER = Component.translatable("caustica.options.voxy.header");

    public CausticaRtScreen(Screen parent, Options options) {
        super(TITLE);
    }

    @Override
    protected void init() {
        super.init();
    }

    @Override
    public void removed() {
        super.removed();
        CausticaConfig.save();
    }
}
