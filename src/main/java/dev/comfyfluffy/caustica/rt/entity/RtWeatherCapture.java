package dev.comfyfluffy.caustica.rt.entity;

import dev.comfyfluffy.caustica.CausticaConfig;
import dev.comfyfluffy.caustica.CausticaMod;
import net.minecraft.client.Minecraft;
import net.minecraft.client.renderer.WeatherEffectRenderer;
import net.minecraft.client.renderer.state.level.WeatherRenderState;
import net.minecraft.resources.Identifier;
import net.minecraft.util.ARGB;
import net.minecraft.util.Mth;
import net.minecraft.world.phys.Vec3;

import java.util.List;

/**
 * Vanilla rain/snow columns, captured as real ray-traced geometry.
 *
 * <h2>Why this exists at all</h2>
 * Minecraft's rain is <em>not</em> a {@code ParticleEngine} effect, so {@link RtEntities}' particle path
 * never sees it. It is a dedicated pass — {@code WeatherEffectRenderer} — that lives inside
 * {@code LevelRenderer.render}, which Caustica cancels outright. That is the whole reason rain vanished
 * under the ray-traced renderer: nothing was broken, the pass simply never ran.
 *
 * <p>The fix is deliberately <b>not</b> a new procedural effect. Earlier attempts invented a synthetic
 * streak field (bars that read as falling iron/meteors) and a 2D screen overlay (a panel pasted on the
 * HUD). Both failed for the same reason: they were <em>guesses</em> at what rain looks like instead of
 * the thing the game already computes. This class throws that away and replays vanilla's own geometry.
 *
 * <h2>What is reused verbatim</h2>
 * The columns are read from {@link WeatherRenderState}, which vanilla's {@code LevelExtractor} still
 * fills every frame — extraction happens in {@code GameRenderer.extract}, <em>before</em> and entirely
 * independently of the {@code LevelRenderer.render} call Caustica cancels. So the CPU-side weather
 * simulation, all of it, is already running and correct:
 *
 * <ul>
 *   <li><b>Placement</b> — one column per (x, z) inside the {@code weatherRadius} option, skipping
 *       biomes with no precipitation and unloaded chunks.</li>
 *   <li><b>Vertical extent</b> — {@code bottomY}/{@code topY} are clamped to the {@code MOTION_BLOCKING}
 *       heightmap, which is exactly what makes rain stop at the ground, at leaves, and at a roof instead
 *       of raining through the world. This is the "collides with the 3D world" behaviour, and it is free:
 *       it is baked into the column extents vanilla already computed.</li>
 *   <li><b>Fall animation</b> — the scrolling {@code vOffset} in {@code ColumnInstance} advances with
 *       game time, so the drops genuinely fall rather than sitting still.</li>
 *   <li><b>Rain vs. snow</b> — separate column lists, separate textures, separate max alpha.</li>
 * </ul>
 *
 * <p>The quad construction below is a line-for-line port of {@code WeatherEffectRenderer.renderInstances}
 * — the same {@code columnSizeX/Z} lookup table, the same distance-faded alpha, the same {@code y * 0.25}
 * texture V mapping. Positions come out camera-relative (as vanilla emits them) and are shifted into the
 * renderer's rebased space so the TLAS instance transform stays identity, matching {@link
 * RtParticleCapture}.
 *
 * <h2>How it reaches the screen</h2>
 * The quads are pushed through {@link RtEntityCapture} into the same combined particle mesh/BLAS the
 * {@code ParticleEngine} billboards use, so they inherit {@code PARTICLE_BIT}, the primary-ray-only
 * instance mask, the any-hit cutout bucket, and {@code MATERIAL_PARTICLE} shading in raygen. Because they
 * are ordinary geometry in the acceleration structure, a ray fired at a wall stops at the wall: rain
 * behind terrain is occluded by the depth of the trace itself, with no extra logic.
 *
 * <p>The V coordinate deliberately runs far outside 0..1 ({@code y * 0.25} over a column tens of blocks
 * tall, plus a scroll offset that grows with game time). That is vanilla's design — the sheet is meant to
 * tile — and it works here because the bindless entity sampler is created with {@code REPEAT} addressing
 * in all three axes, so the coordinate wraps instead of clamping the whole column to one stretched texel.
 */
public final class RtWeatherCapture {
    public static final RtWeatherCapture INSTANCE = new RtWeatherCapture();

    /** Vanilla's rain/snow sheet textures ({@code WeatherEffectRenderer.RAIN_LOCATION}). */
    private static final Identifier RAIN_LOCATION =
            Identifier.withDefaultNamespace("textures/environment/rain.png");
    private static final Identifier SNOW_LOCATION =
            Identifier.withDefaultNamespace("textures/environment/snow.png");

    /** Vanilla's per-column orientation table size ({@code RAIN_TABLE_SIZE} / {@code HALF_...}). */
    private static final int RAIN_TABLE_SIZE = 32;
    private static final int HALF_RAIN_TABLE_SIZE = 16;

    /** Max alpha for rain vs. snow, matching vanilla's two {@code renderInstances} calls. */
    private static final float RAIN_MAX_ALPHA = 1.0f;
    private static final float SNOW_MAX_ALPHA = 0.8f;

    /**
     * Rain level below which no drops are drawn at all — the dead zone in {@link #visualIntensity}.
     *
     * <p>Vanilla's rain level ramps over roughly 5 seconds (it moves ~0.01/tick), so this holds the
     * drops back for about the first second of that ramp and, symmetrically, removes them about a second
     * before it reaches zero. That is enough for the sky to have visibly greyed first and to still look
     * overcast as the last drops go, without a delay long enough to feel like a bug in the other
     * direction.
     */
    private static final float RAIN_ONSET = 0.18f;

    /**
     * Vanilla's per-column billboard orientation table. Each (x, z) offset around the camera gets a fixed
     * horizontal facing, so neighbouring columns fan out instead of all facing the same way — this is what
     * stops the rain from looking like one flat wall. Copied from {@code WeatherEffectRenderer}'s
     * constructor rather than recomputed differently, so orientation matches vanilla exactly.
     */
    private final float[] columnSizeX = new float[RAIN_TABLE_SIZE * RAIN_TABLE_SIZE];
    private final float[] columnSizeZ = new float[RAIN_TABLE_SIZE * RAIN_TABLE_SIZE];

    private boolean loggedFailure;

    private RtWeatherCapture() {
        for (int z = 0; z < RAIN_TABLE_SIZE; z++) {
            for (int x = 0; x < RAIN_TABLE_SIZE; x++) {
                float deltaX = x - HALF_RAIN_TABLE_SIZE;
                float deltaZ = z - HALF_RAIN_TABLE_SIZE;
                float distance = Mth.length(deltaX, deltaZ);
                // The exact table centre is the column the camera is standing in: deltaX == deltaZ == 0,
                // so vanilla's -deltaZ/distance is 0/0 = NaN and its rasteriser simply DROPS the NaN
                // vertex — the column under the camera is never drawn. A NaN corner fed to a BLAS build
                // would instead poison that node's bounding box (every ray testing it degenerates), so
                // the same "don't draw the camera's own column" is reproduced with an explicit skip in
                // captureColumns: the NaN stays here as the marker.
                columnSizeX[z * RAIN_TABLE_SIZE + x] = -deltaZ / distance;
                columnSizeZ[z * RAIN_TABLE_SIZE + x] = deltaX / distance;
            }
        }
    }

    /** Master switch for ray-traced weather columns ({@code caustica.rt.weatherParticles}). */
    public static boolean enabled() {
        return CausticaConfig.Rt.Entities.WEATHER_ENABLED.value();
    }

    /**
     * Append this frame's rain and snow columns to {@code capture} (a particle-mode capture: the caller
     * has already set the any-hit alpha bucket and the camera-relative → rebased offset on
     * {@code out}).
     *
     * <p>Returns the number of columns captured, or 0 when it is not raining, the feature is off, or the
     * weather render state has not been populated (menus, dimension without precipitation).
     *
     * @param capture the shared entity/particle mesh accumulator
     * @param out     the {@link RtParticleCapture} adapter feeding {@code capture}, offset already set
     * @param camPos  this frame's camera position (columns are emitted relative to it, as vanilla does)
     * @param budget  max columns to capture, so weather cannot exhaust the particle budget on its own
     */
    public int capture(RtEntityCapture capture, RtParticleCapture out, Vec3 camPos, int budget) {
        if (!enabled() || budget <= 0) {
            return 0;
        }
        WeatherRenderState state = weatherState();
        if (state == null || state.intensity <= 0.0f || state.radius <= 0) {
            return 0;
        }
        float intensity = visualIntensity(state.intensity);
        if (intensity <= 0.0f) {
            return 0;
        }
        int captured = 0;
        try {
            captured += captureColumns(capture, out, state.rainColumns, camPos, RAIN_MAX_ALPHA,
                    state.radius, intensity, RAIN_LOCATION, budget - captured);
            captured += captureColumns(capture, out, state.snowColumns, camPos, SNOW_MAX_ALPHA,
                    state.radius, intensity, SNOW_LOCATION, budget - captured);
        } catch (Throwable t) {
            // Never take the whole RT frame down over weather: log once and render this frame dry.
            if (!loggedFailure) {
                loggedFailure = true;
                CausticaMod.LOGGER.warn("RT weather capture failed; rain/snow will not be ray traced", t);
            }
            return captured;
        }
        return captured;
    }

    /**
     * Reshape vanilla's raw rain level into the curve the <em>drops</em> should follow, so precipitation
     * and the overcast sky arrive and leave together.
     *
     * <p>Minecraft ramps {@code rainLevel} linearly from 0 to 1 over a few seconds when weather starts or
     * stops, and everything visual is driven from it. But the two things being driven have very different
     * perceptual responses to a small value:
     *
     * <ul>
     *   <li>the sky's overcast blend is <em>proportional</em> — at rain 0.05 it is 5% grey over blue,
     *       which is invisible. The sky still reads as a clear blue day.</li>
     *   <li>rain columns are <em>presence</em> — at rain 0.05 the sheets are faint but unmistakably
     *       there, because a thin streak against a bright sky is high contrast.</li>
     * </ul>
     *
     * <p>So with both fed the same number, the drops appear while the sky is still blue and linger after
     * it has cleared — the reported "starts early, ends late". The fix is to hold the drops back until
     * the sky has visibly committed to the storm, then bring them in quickly: a smoothstep with a dead
     * zone at the bottom. Rain now starts a beat <em>after</em> the sky begins to grey and is gone a beat
     * <em>before</em> it finishes clearing, which is the order the eye expects (clouds gather, then it
     * rains; it stops raining, then the sky opens).
     *
     * <p>Deliberately applied here rather than to {@code weather.x}: that lane also drives the sun/moon
     * attenuation and the fog, and delaying <em>those</em> is what would make the sky lag the storm.
     */
    private static float visualIntensity(float rainLevel) {
        float t = Mth.clamp((rainLevel - RAIN_ONSET) / (1.0f - RAIN_ONSET), 0.0f, 1.0f);
        return t * t * (3.0f - 2.0f * t); // smoothstep
    }

    /**
     * Vanilla's live weather columns for this frame, or null when unavailable.
     *
     * <p>Read from the shared {@code LevelRenderState} that {@code LevelExtractor.extract} fills each
     * frame. That extraction runs from {@code GameRenderer.extract}, which Caustica does not touch — only
     * {@code LevelRenderer.render} (the consumer) is cancelled. So this state is fully simulated and
     * current even though vanilla never drew it.
     */
    private static WeatherRenderState weatherState() {
        Minecraft mc = Minecraft.getInstance();
        if (mc == null || mc.level == null || mc.gameRenderer == null) {
            return null;
        }
        return mc.gameRenderer.gameRenderState().levelRenderState.weatherRenderState;
    }

    /**
     * Emit one quad per column, exactly as {@code WeatherEffectRenderer.renderInstances} does.
     *
     * <p>Each column is a vertical sheet spanning {@code bottomY..topY} — the range vanilla already
     * clipped against the {@code MOTION_BLOCKING} heightmap — oriented by the {@code columnSize} table and
     * faded by squared horizontal distance. The V coordinate is {@code y * 0.25 + vOffset}, so the texture
     * tiles four blocks per repeat and scrolls downward with {@code vOffset} as game time advances: that
     * scroll is the falling motion.
     */
    private int captureColumns(RtEntityCapture capture, RtParticleCapture out,
                               List<WeatherEffectRenderer.ColumnInstance> columns, Vec3 camPos,
                               float maxAlpha, int radius, float intensity, Identifier texture, int budget) {
        if (columns == null || columns.isEmpty() || budget <= 0) {
            return 0;
        }
        // One bindless slot for the whole sheet: rain.png / snow.png are standalone textures, resolved
        // through the same registry entity textures use.
        capture.currentTexSlot = RtEntityTextures.INSTANCE.slotForTexture(texture);

        float radiusSq = (float) radius * radius;
        int camFloorX = Mth.floor(camPos.x);
        int camFloorZ = Mth.floor(camPos.z);
        int emitted = 0;

        for (WeatherEffectRenderer.ColumnInstance column : columns) {
            if (emitted >= budget) {
                break;
            }
            float relativeX = (float) (column.x() + 0.5 - camPos.x);
            float relativeZ = (float) (column.z() + 0.5 - camPos.z);
            float distanceSq = (float) Mth.lengthSquared(relativeX, relativeZ);
            float alpha = Mth.lerp(Math.min(distanceSq / radiusSq, 1.0f), maxAlpha, 0.5f) * intensity;
            if (alpha <= 0.0f) {
                continue;
            }
            // Vanilla's per-column alpha is a raster blend weight. The RT particle path has no blend
            // stage, so it goes into the ALPHA lane only: RtEntityCapture stores it as the primitive
            // coverage multiplier (aux0) and world.rahit folds it into the stochastic cutout together
            // with the sheet texel's own alpha. Fading by *coverage* is what a blend weight actually
            // means — fewer drop samples survive with distance — so the far columns thin out instead of
            // changing colour.
            //
            // The RGB stays WHITE on purpose. An earlier version also scaled RGB by the same factor to
            // reproduce the fade, but tint is not opacity: world.rchit multiplies it straight into the
            // albedo, so it *darkened* the drops rather than thinning them. That is what produced the
            // patch of rain that looked brighter than the rest — near columns kept a bright tint while
            // columns a few blocks further out were shaded progressively darker, and the boundary
            // between two adjacent alpha steps read as a visible seam across the sheet.
            int color = ARGB.white(alpha);

            // The orientation table is indexed by the column's offset from the camera, biased to the
            // table centre. Columns beyond the table (a radius option larger than 16) would index out of
            // bounds, so clamp — vanilla's radius maxes at 10 and never hits this, but a modded/config
            // value must not crash the renderer.
            int tableX = Mth.clamp(column.x() - camFloorX + HALF_RAIN_TABLE_SIZE, 0, RAIN_TABLE_SIZE - 1);
            int tableZ = Mth.clamp(column.z() - camFloorZ + HALF_RAIN_TABLE_SIZE, 0, RAIN_TABLE_SIZE - 1);
            int index = tableZ * RAIN_TABLE_SIZE + tableX;

            float halfSizeX = columnSizeX[index] / 2.0f;
            float halfSizeZ = columnSizeZ[index] / 2.0f;
            if (Float.isNaN(halfSizeX + halfSizeZ)) {
                // The column under the camera: vanilla's 0/0 orientation is NaN and its rasteriser
                // drops the quad, so the camera's own column is never drawn there either. Drawing it
                // with any fixed facing makes a thin vertical sliver appear exactly when the player
                // stands still (the quad is seen edge-on half the time and does not move with the
                // camera), so reproduce vanilla: skip it.
                continue;
            }
            float x0 = relativeX - halfSizeX;
            float x1 = relativeX + halfSizeX;
            float y1 = (float) (column.topY() - camPos.y);
            float y0 = (float) (column.bottomY() - camPos.y);
            float z0 = relativeZ - halfSizeZ;
            float z1 = relativeZ + halfSizeZ;
            float u0 = column.uOffset();
            float u1 = column.uOffset() + 1.0f;
            float v0 = column.bottomY() * 0.25f + column.vOffset();
            float v1 = column.topY() * 0.25f + column.vOffset();

            // Same winding vanilla uses. The adapter buffers a vertex until the next addVertex, so the
            // final vertex of each quad is committed by flush() below.
            out.addVertex(x0, y1, z0).setUv(u0, v0).setColor(color);
            out.addVertex(x1, y1, z1).setUv(u1, v0).setColor(color);
            out.addVertex(x1, y0, z1).setUv(u1, v1).setColor(color);
            out.addVertex(x0, y0, z0).setUv(u0, v1).setColor(color);
            out.flush();
            emitted++;
        }
        return emitted;
    }
}
