package dev.comfyfluffy.caustica.client.gui;

import dev.comfyfluffy.caustica.CausticaConfig;
import dev.comfyfluffy.caustica.client.RtVideoOptions;
import net.minecraft.client.Options;
import net.minecraft.client.gui.components.OptionsList;
import net.minecraft.client.gui.screens.Screen;
import net.minecraft.client.gui.screens.options.OptionsSubScreen;
import net.minecraft.network.chat.Component;

/**
 * Dedicated direct-light reservoir settings screen. Independent RIS, legacy ReSTIR and ReSTCV share
 * the stability section, while candidate budgets, reuse gates and control-variate history remain
 * independently tunable. Every option is shader-only (apart from the existing history allocation
 * toggle) and therefore applies on the next frame.
 */
public final class RtRestirOptionsScreen extends OptionsSubScreen {
    private static final Component TITLE = Component.translatable("caustica.options.restir.title");
    private static final Component MODE_HEADER = Component.translatable("caustica.options.restir.modeHeader");
    private static final Component SAMPLING_HEADER =
            Component.translatable("caustica.options.restir.samplingHeader");
    private static final Component REUSE_HEADER = Component.translatable("caustica.options.restir.reuseHeader");
    private static final Component VALIDATION_HEADER =
            Component.translatable("caustica.options.restir.validationHeader");
    private static final Component STABILITY_HEADER =
            Component.translatable("caustica.options.restir.stabilityHeader");
    private static final Component RESTCV_HEADER = Component.translatable("caustica.options.restir.restcvHeader");

    private final Screen restirParent;
    private final Options restirOptions;

    public RtRestirOptionsScreen(Screen parent, Options options) {
        super(parent, options, TITLE);
        this.restirParent = parent;
        this.restirOptions = options;
    }

    private void rebuildAfterReset() {
        this.minecraft.gui.setScreen(new RtRestirOptionsScreen(restirParent, restirOptions));
    }

    @Override
    protected void addOptions() {
        OptionsList list = ((dev.comfyfluffy.caustica.mixin.OptionsSubScreenAccessor) (Object) this).getList();
        if (list == null) {
            return;
        }

        list.addHeader(MODE_HEADER);
        list.addSmall(RtVideoOptions.restirModeOptions());

        list.addHeader(SAMPLING_HEADER);
        list.addSmall(RtVideoOptions.restirSamplingOptions());

        list.addHeader(REUSE_HEADER);
        list.addSmall(RtVideoOptions.restirReuseOptions());

        list.addHeader(VALIDATION_HEADER);
        list.addSmall(RtVideoOptions.restirValidationOptions());

        list.addHeader(STABILITY_HEADER);
        list.addSmall(RtVideoOptions.restirStabilityOptions());

        list.addHeader(RESTCV_HEADER);
        list.addSmall(RtVideoOptions.restcvOptions());

        list.addBig(RtVideoOptions.restirResetButton(this::rebuildAfterReset));
    }

    @Override
    public void removed() {
        CausticaConfig.save();
        super.removed();
    }
}
