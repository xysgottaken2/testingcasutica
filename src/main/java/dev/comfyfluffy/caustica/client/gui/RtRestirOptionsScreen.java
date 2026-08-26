package dev.comfyfluffy.caustica.client.gui;

import dev.comfyfluffy.caustica.CausticaConfig;
import dev.comfyfluffy.caustica.client.RtVideoOptions;
import net.minecraft.client.Options;
import net.minecraft.client.gui.components.OptionsList;
import net.minecraft.client.gui.screens.Screen;
import net.minecraft.client.gui.screens.options.OptionsSubScreen;
import net.minecraft.network.chat.Component;

/**
 * Dedicated ReSTIR DI / GRIS settings sub-screen, opened from the main Ray Tracing Settings screen
 * by the "ReSTIR Settings..." button (the same nested-sub-screen pattern Video Settings uses to open
 * Ray Tracing Settings, and that the RT screen uses for SHaRC).
 *
 * <p>Layout: master enable toggle, then the ultra-stable temporal/spatial reuse knobs, plus a reset
 * button that clears both reservoir history buffers. Every control writes straight into
 * {@link CausticaConfig.Rt.Restir} (the master enable stays {@link CausticaConfig.Rt.Lights#RESTIR_SAMPLING})
 * and applies on the next frame.
 */
public final class RtRestirOptionsScreen extends OptionsSubScreen {
    private static final Component TITLE = Component.translatable("caustica.options.restir.title");
    private static final Component HEADER = Component.translatable("caustica.options.restir.header");
    private static final Component TEMPORAL_HEADER = Component.translatable("caustica.options.restir.temporalHeader");
    private static final Component SPATIAL_HEADER = Component.translatable("caustica.options.restir.spatialHeader");
    private static final Component SAFETY_HEADER = Component.translatable("caustica.options.restir.safetyHeader");

    public RtRestirOptionsScreen(Screen parent, Options options) {
        super(parent, options, TITLE);
    }

    @Override
    protected void addOptions() {
        OptionsList list = ((dev.comfyfluffy.caustica.mixin.OptionsSubScreenAccessor) (Object) this).getList();
        if (list == null) {
            return;
        }

        list.addHeader(HEADER);
        list.addBig(RtVideoOptions.restirToggleButton());

        list.addHeader(TEMPORAL_HEADER);
        list.addSmall(RtVideoOptions.restirTemporalOptions());

        list.addHeader(SPATIAL_HEADER);
        list.addSmall(RtVideoOptions.restirSpatialOptions());

        list.addHeader(SAFETY_HEADER);
        list.addSmall(RtVideoOptions.restirSafetyOptions());

        list.addBig(RtVideoOptions.restirResetButton());
    }

    @Override
    public void removed() {
        CausticaConfig.save();
        super.removed();
    }
}
