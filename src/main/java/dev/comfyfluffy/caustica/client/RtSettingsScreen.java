package dev.comfyfluffy.caustica.client;

import dev.comfyfluffy.caustica.CausticaConfig;
import net.minecraft.client.Options;
import net.minecraft.client.gui.components.OptionsList;
import net.minecraft.client.gui.screens.Screen;
import net.minecraft.client.gui.screens.options.OptionsSubScreen;
import net.minecraft.network.chat.Component;

public class RtSettingsScreen extends OptionsSubScreen {
    public RtSettingsScreen(Screen parent, Options options) {
        super(parent, options, Component.translatable("caustica.options.rt.title"));
    }

    @Override
    protected void addOptions() {
        if (this.list != null) {
            this.list.addHeader(Component.translatable("caustica.options.rt.header"));
            this.list.addSmall(RtVideoOptions.runtimeOptions());
            this.list.addHeader(Component.translatable("caustica.options.rt.lightsHeader"));
            this.list.addSmall(RtVideoOptions.lightOptions());
            this.list.addHeader(Component.translatable("caustica.options.rt.tonemapHeader"));
            this.list.addSmall(RtVideoOptions.tonemapOptions());
        }
    }

    @Override
    public void removed() {
        CausticaConfig.save();
    }
}
