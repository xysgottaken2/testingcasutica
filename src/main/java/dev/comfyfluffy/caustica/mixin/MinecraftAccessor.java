package dev.comfyfluffy.caustica.mixin;

import net.minecraft.client.Minecraft;
import net.minecraft.client.renderer.LevelRenderer;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.gen.Accessor;

/** Exposes the level renderer so Caustica can invoke vanilla weather after replacing the world view. */
@Mixin(Minecraft.class)
public interface MinecraftAccessor {
    @Accessor("levelRenderer")
    LevelRenderer caustica$levelRenderer();
}
