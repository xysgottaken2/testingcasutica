package dev.comfyfluffy.caustica.mixin;

import dev.comfyfluffy.caustica.CausticaConfig;
import dev.comfyfluffy.caustica.client.RtSettingsScreen;
import java.util.ArrayList;
import java.util.List;
import net.minecraft.client.Minecraft;
import net.minecraft.client.OptionInstance;
import net.minecraft.client.Options;
import net.minecraft.client.gui.components.Button;
import net.minecraft.client.gui.components.OptionsList;
import net.minecraft.client.gui.screens.Screen;
import net.minecraft.client.gui.screens.options.VideoSettingsScreen;
import net.minecraft.network.chat.Component;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Shadow;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.Redirect;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

/**
 * Surfaces a single "Ray Tracing Settings..." button inside the vanilla Video Settings screen when the
 * RT renderer is enabled, gated on {@link CausticaConfig.Rt#ENABLED}:
 *
 * <ul>
 *   <li>The Quality section drops the vanilla options the path tracer supersedes (Ambient Occlusion and
 *       Entity Shadows are computed by RT global illumination / RT shadows).</li>
 *   <li>A trailing button opens {@link RtSettingsScreen}, the dedicated RT sub-menu, instead of
 *       injecting every individual RT toggle/slider straight into this already-busy screen.</li>
 * </ul>
 *
 * When RT is disabled the screen is left exactly as vanilla built it.
 */
@Mixin(VideoSettingsScreen.class)
public abstract class VideoSettingsScreenMixin {
    @Shadow
    private static OptionInstance<?>[] qualityOptions(Options options) {
        throw new AssertionError("mixin stub");
    }

    private static final Component CAUSTICA$RT_SETTINGS_BUTTON =
            Component.translatable("caustica.options.rt.settingsButton");

    @Redirect(
        method = "addOptions",
        at = @At(
            value = "INVOKE",
            target = "Lnet/minecraft/client/gui/screens/options/VideoSettingsScreen;qualityOptions(Lnet/minecraft/client/Options;)[Lnet/minecraft/client/OptionInstance;"))
    private OptionInstance<?>[] caustica$filterQualityOptions(Options options) {
        OptionInstance<?>[] base = qualityOptions(options);
        if (!CausticaConfig.Rt.ENABLED.value()) {
            return base;
        }
        List<OptionInstance<?>> kept = new ArrayList<>(base.length);
        for (OptionInstance<?> option : base) {
            // Path-traced GI + RT shadows make these vanilla raster controls inert under RT.
            if (option == options.ambientOcclusion() || option == options.entityShadows()) {
                continue;
            }
            kept.add(option);
        }
        return kept.toArray(OptionInstance<?>[]::new);
    }

    @Inject(method = "addOptions", at = @At("HEAD"))
    private void caustica$addRtSettingsButton(CallbackInfo ci) {
        if (!CausticaConfig.Rt.ENABLED.value()) {
            return;
        }
        OptionsList list = ((OptionsSubScreenAccessor) (Object) this).getList();
        if (list == null) {
            return;
        }
        Screen self = (Screen) (Object) this;
        Minecraft minecraft = Minecraft.getInstance();
        Button button = Button.builder(CAUSTICA$RT_SETTINGS_BUTTON,
                        b -> minecraft.setScreen(new RtSettingsScreen(self, minecraft.options)))
                .build();
        list.addSmall(List.of(button));
    }

    @Inject(method = "removed", at = @At("TAIL"))
    private void caustica$saveConfig(CallbackInfo ci) {
        // Persist any RT settings the player changed on this screen (e.g. the vanilla options RT
        // suppresses above) to the TOML config.
        CausticaConfig.save();
    }
}
