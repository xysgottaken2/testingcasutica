package dev.comfyfluffy.caustica.mixin;

import net.minecraft.client.renderer.LevelRenderer;
import net.minecraft.client.renderer.WeatherEffectRenderer;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.gen.Accessor;

/** Exposes vanilla's weather renderer so Caustica can replay it after replacing the world view. */
@Mixin(LevelRenderer.class)
public interface LevelRendererWeatherAccessor {
    @Accessor("weatherEffectRenderer")
    WeatherEffectRenderer caustica$weatherEffectRenderer();
}
