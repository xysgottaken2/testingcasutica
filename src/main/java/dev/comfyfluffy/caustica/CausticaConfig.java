package dev.comfyfluffy.caustica;

import com.electronwill.nightconfig.core.CommentedConfig;
import com.electronwill.nightconfig.core.file.CommentedFileConfig;
import com.electronwill.nightconfig.core.file.FileNotFoundAction;
import com.electronwill.nightconfig.toml.TomlFormat;
import java.nio.file.Path;
import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.function.DoubleUnaryOperator;
import java.util.function.IntUnaryOperator;
import java.util.function.UnaryOperator;
import net.fabricmc.loader.api.FabricLoader;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/**
 * Central mutable runtime configuration. Each setting resolves its value, in order of precedence, from a
 * {@code -Dcaustica.*} system property, then the {@code config/caustica.toml} file, then a hardcoded
 * default. The settings UI and any other code call the same {@code set(...)} methods, and {@link #save()}
 * writes the current values back to the TOML file.
 *
 * <p>The system property namespace ({@code caustica.rt.foo}) and the TOML layout are independent: the file
 * uses real nested tables (e.g. {@code [omm]} with a {@code subdivision} key) grouped for readability, while
 * the property namespace stays flat and dotted for convenient one-off {@code -D} overrides.
 */
public final class CausticaConfig {
    private static final Logger LOGGER = LoggerFactory.getLogger("Caustica");
    private static final List<RuntimeSetting<?>> SETTINGS = new CopyOnWriteArrayList<>();

    private static final Path CONFIG_PATH = resolveConfigPath();
    private static final CommentedFileConfig FILE = loadFile(CONFIG_PATH);

    private CausticaConfig() {
    }

    public static List<RuntimeSetting<?>> settings() {
        return List.copyOf(SETTINGS);
    }

    public static Path configPath() {
        return CONFIG_PATH;
    }

    public static void reloadFromSystemProperties() {
        for (RuntimeSetting<?> setting : SETTINGS) {
            setting.reloadFromSystemProperties();
        }
    }

    /**
     * Forces every settings holder to class-initialize so all settings are registered (and have applied
     * their file values). Call before {@link #save()} to write a complete file, and once at startup so the
     * file round-trips the full surface even for settings the renderer has not touched yet.
     */
    public static void ensureRegistered() {
        @SuppressWarnings("unused")
        Object[] touch = {
            Rt.ENABLED, Rt.Composite.SPP, Rt.Composite.MAX_BOUNCES, Rt.Composite.SSS,
            Rt.Composite.WEATHER_LIGHTING, Rt.Composite.DENOISER,
            Rt.Terrain.ASYNC_DISPATCH_PER_PASS, Rt.Omm.ENABLED,
            Rt.Entities.ENABLED, Rt.Entities.GLOW_ENABLED, Rt.EntityTextures.MAX_TEXTURES, Rt.DlssRr.ENABLED, Rt.Fg.ENABLED,
            Rt.Reflex.ENABLED, Rt.Lights.DYNAMIC_INTENSITY, Rt.Lights.BLOCK_INTENSITY,
            Rt.Lights.RESTIR_SAMPLING, Rt.Hand.FOV_FOLLOWS_CAMERA,
            Rt.Exposure.MODE, Rt.Tonemapping.OPERATOR, Rt.FrameStats.ENABLED, Rt.Hdr.ENABLED, Ngx.PATH,
            Rt.DistantHorizons.ENABLED, Rt.DistantHorizons.LOD_CHUNK_RADIUS,
            Rt.DistantHorizons.SCAN_INTERVAL_TICKS, Rt.DistantHorizons.LOD_QUAD_SIZE,
        };
    }

    /** Writes the default config file if it does not exist yet. */
    public static void saveIfMissing() {
        ensureRegistered();
        if (FILE.valueMap().isEmpty()) {
            save();
        }
    }

    /** Serializes all registered settings to the TOML config file. */
    public static synchronized void save() {
        ensureRegistered();
        writeComments();
        for (RuntimeSetting<?> setting : SETTINGS) {
            setting.writeToFile(FILE);
        }
        FILE.save();
    }

    private static void writeComments() {
        FILE.setComment("enabled",
                " Caustica RT renderer configuration.\n"
                        + " A matching -Dcaustica.* system property overrides the value below.");
        FILE.setComment("composite",
                " Per-frame path-tracing controls.\n"
                        + " subsurface-scattering: LabPBR SSS (backlit foliage). Costs one extra shadow ray per\n"
                        + " eligible vertex; off disables the effect entirely.\n"
                        + " weather-lighting: attenuate sun/moon light and darken the sky during rain and\n"
                        + " thunderstorms. Off keeps clear-sky lighting in all weather.\n"
                        + " denoiser: the DLSS Ray Reconstruction denoise+upscale filter. Off presents the raw\n"
                        + " path-traced image at full resolution (noisy reference view). Requires dlss-rr.enabled.");
        FILE.setComment("terrain",
                " Render-thread terrain work is bounded by dispatch/result counts per streaming pass.\n"
                        + " Buffer fill and BLAS/OMM preparation run on workers. max-inflight-sections bounds\n"
                        + " the complete snapshot -> worker -> GPU build -> publication lifecycle.");
        FILE.setComment("frame-generation",
                " DLSS Frame Generation. Default off; gated additionally by hardware/driver availability.\n"
                        + " multi-frame-count: frames generated per rendered frame (1 = 2x, 2 = 3x, ...), clamped\n"
                        + " at runtime to the driver's reported DLSSG.MultiFrameCountMax.");
        FILE.setComment("reflex",
                " NVIDIA Reflex (VK_NV_low_latency2). Default off; gated additionally by device support.\n"
                        + " minimum-interval-us: 0 = no framerate cap (Reflex just paces submission).");
        FILE.setComment("hand",
                " First-person viewmodel (held item / arm) controls.\n"
                        + " fov-follows-camera: false (vanilla) renders the hand through its own fixed 70-degree\n"
                        + " projection, isolated from the FOV setting. true scales that projection to the\n"
                        + " configured FOV instead, so raising the FOV pushes the arm away and lowering it pulls\n"
                        + " the arm closer, the way the rest of the scene reacts.");
        FILE.setComment("lights",
                " Direct lighting controls. dynamic-intensity scales analytic lights created from luminous\n"
                        + " held items (torches, lanterns, lava buckets, ...) and is config-only — the Video\n"
                        + " Settings screen exposes block-emissive-intensity and ReSTIR sampling.\n"
                        + " block-emissive-intensity scales emissive blocks placed in the world, both their\n"
                        + " direct-hit emission and sampled area-light contribution. restir-sampling reuses\n"
                        + " validated light reservoirs across frames and nearby pixels; off keeps the original\n"
                        + " independent RIS estimator. ris-candidates = 0 disables emitter NEE entirely\n"
                        + " (emitters just gather on direct hit). min-fill-ratio drops sparse emissive\n"
                        + " footprints from the light buffer. stats/dump/dump-radius are debug logging.");
        FILE.setComment("tonemap",
                " Scene tonemapping after exposure and before writing the vanilla SDR target. operator selects\n"
                        + " the curve; exposure-ev is an extra post-exposure bias; gamma/saturation/contrast\n"
                        + " are final look controls shared by all operators.");
        FILE.setComment("hdr",
                " HDR display output (ST.2084/PQ). When enabled the swapchain is created in PQ automatically\n"
                        + " (falls back to SDR if the surface doesn't advertise it). paper-white-nits / peak-nits\n"
                        + " drive the scene-HDR -> display mapping.");
    }

    private static Path resolveConfigPath() {
        try {
            return FabricLoader.getInstance().getConfigDir().resolve("caustica.toml");
        } catch (Throwable t) {
            return Path.of("config", "caustica.toml");
        }
    }

    private static CommentedFileConfig loadFile(Path path) {
        CommentedFileConfig config = CommentedFileConfig.builder(path, TomlFormat.instance())
                .onFileNotFound(FileNotFoundAction.CREATE_EMPTY)
                .preserveInsertionOrder()
                .sync()
                .build();
        try {
            config.load();
        } catch (Exception e) {
            LOGGER.warn("Failed to read Caustica config {}: {}", path, e.toString());
        }
        return config;
    }

    private static Boolean fileBoolean(String tomlPath) {
        return FILE.contains(tomlPath) ? FILE.<Boolean>get(tomlPath) : null;
    }

    private static Number fileNumber(String tomlPath) {
        return FILE.contains(tomlPath) ? FILE.<Number>get(tomlPath) : null;
    }

    private static String fileString(String tomlPath) {
        return FILE.contains(tomlPath) ? FILE.<String>get(tomlPath) : null;
    }

    public interface RuntimeSetting<T> {
        /** The {@code -Dcaustica.*} system property name that overrides this setting. */
        String key();

        /** The dotted path of this setting inside the nested {@code config/caustica.toml} tables. */
        String tomlPath();

        T defaultValue();

        T get();

        void set(T value);

        void reloadFromSystemProperties();

        /** Writes this setting's current value into the given config at {@link #tomlPath()}. */
        void writeToFile(CommentedConfig config);
    }

    public static final class BooleanSetting implements RuntimeSetting<Boolean> {
        private final String key;
        private final String tomlPath;
        private final boolean defaultValue;
        private volatile boolean value;

        private BooleanSetting(String key, String tomlPath, boolean defaultValue) {
            this.key = key;
            this.tomlPath = tomlPath;
            this.defaultValue = defaultValue;
            this.value = resolveInitial();
            SETTINGS.add(this);
        }

        @Override
        public String key() {
            return key;
        }

        @Override
        public String tomlPath() {
            return tomlPath;
        }

        @Override
        public Boolean defaultValue() {
            return defaultValue;
        }

        @Override
        public Boolean get() {
            return value;
        }

        public boolean value() {
            return value;
        }

        @Override
        public void set(Boolean value) {
            this.value = value != null ? value : defaultValue;
        }

        @Override
        public void reloadFromSystemProperties() {
            set(Boolean.parseBoolean(System.getProperty(key, Boolean.toString(defaultValue))));
        }

        @Override
        public void writeToFile(CommentedConfig config) {
            config.set(tomlPath, value);
        }

        private boolean resolveInitial() {
            String prop = System.getProperty(key);
            if (prop != null) {
                return Boolean.parseBoolean(prop.trim());
            }
            Boolean fromFile = fileBoolean(tomlPath);
            return fromFile != null ? fromFile : defaultValue;
        }
    }

    public static final class IntSetting implements RuntimeSetting<Integer> {
        private final String key;
        private final String tomlPath;
        private final int defaultValue;
        private final IntUnaryOperator sanitize;
        private volatile int value;

        private IntSetting(String key, String tomlPath, int defaultValue, IntUnaryOperator sanitize) {
            this.key = key;
            this.tomlPath = tomlPath;
            this.defaultValue = sanitize.applyAsInt(defaultValue);
            this.sanitize = sanitize;
            this.value = resolveInitial();
            SETTINGS.add(this);
        }

        @Override
        public String key() {
            return key;
        }

        @Override
        public String tomlPath() {
            return tomlPath;
        }

        @Override
        public Integer defaultValue() {
            return defaultValue;
        }

        @Override
        public Integer get() {
            return value;
        }

        public int value() {
            return value;
        }

        @Override
        public void set(Integer value) {
            this.value = sanitize.applyAsInt(value != null ? value : defaultValue);
        }

        @Override
        public void reloadFromSystemProperties() {
            String prop = System.getProperty(key);
            if (prop == null) {
                this.value = defaultValue;
                return;
            }
            try {
                this.value = sanitize.applyAsInt(Integer.parseInt(prop.trim()));
            } catch (NumberFormatException e) {
                this.value = defaultValue;
            }
        }

        @Override
        public void writeToFile(CommentedConfig config) {
            config.set(tomlPath, value);
        }

        private int resolveInitial() {
            String prop = System.getProperty(key);
            if (prop != null) {
                try {
                    return sanitize.applyAsInt(Integer.parseInt(prop.trim()));
                } catch (NumberFormatException e) {
                    return defaultValue;
                }
            }
            Number fromFile = fileNumber(tomlPath);
            return fromFile != null ? sanitize.applyAsInt(fromFile.intValue()) : defaultValue;
        }
    }

    public static final class FloatSetting implements RuntimeSetting<Float> {
        private final String key;
        private final String tomlPath;
        private final float defaultValue;
        // Maps a raw external number (system property, file, or the constructor's raw default) into the
        // stored value domain, e.g. degrees -> radians.
        private final DoubleUnaryOperator inputTransform;
        // Inverse of inputTransform: maps the stored value domain back to the raw external domain (e.g.
        // radians -> degrees) for writeToFile, so a value round-trips through the file unchanged instead
        // of having inputTransform re-applied to an already-transformed number on the next load.
        private final DoubleUnaryOperator outputTransform;
        // Idempotent guard on a value-domain number (clamp / finite check); safe to apply to any source.
        private final DoubleUnaryOperator valueClamp;
        private volatile float value;

        private FloatSetting(String key, String tomlPath, float rawDefault, DoubleUnaryOperator inputTransform,
                             DoubleUnaryOperator outputTransform, DoubleUnaryOperator valueClamp) {
            this.key = key;
            this.tomlPath = tomlPath;
            this.inputTransform = inputTransform;
            this.outputTransform = outputTransform;
            this.valueClamp = valueClamp;
            this.defaultValue = (float) valueClamp.applyAsDouble(inputTransform.applyAsDouble(rawDefault));
            this.value = resolveInitial();
            SETTINGS.add(this);
        }

        @Override
        public String key() {
            return key;
        }

        @Override
        public String tomlPath() {
            return tomlPath;
        }

        @Override
        public Float defaultValue() {
            return defaultValue;
        }

        @Override
        public Float get() {
            return value;
        }

        public float value() {
            return value;
        }

        @Override
        public void set(Float value) {
            if (value == null) {
                this.value = defaultValue;
            } else {
                this.value = (float) valueClamp.applyAsDouble(inputTransform.applyAsDouble(value));
            }
        }

        @Override
        public void reloadFromSystemProperties() {
            String prop = System.getProperty(key);
            if (prop == null) {
                this.value = defaultValue;
                return;
            }
            try {
                this.value = (float) valueClamp.applyAsDouble(inputTransform.applyAsDouble(Double.parseDouble(prop.trim())));
            } catch (NumberFormatException e) {
                this.value = defaultValue;
            }
        }

        @Override
        public void writeToFile(CommentedConfig config) {
            // Round-trip through Float.toString() so the file gets the shortest decimal that reproduces
            // this float (e.g. "0.6"), not outputTransform's raw double with float's binary noise spelled
            // out to 17 digits (e.g. 0.6000000487130328).
            float raw = (float) outputTransform.applyAsDouble(value);
            config.set(tomlPath, Double.parseDouble(Float.toString(raw)));
        }

        private float resolveInitial() {
            String prop = System.getProperty(key);
            if (prop != null) {
                try {
                    return (float) valueClamp.applyAsDouble(inputTransform.applyAsDouble(Double.parseDouble(prop.trim())));
                } catch (NumberFormatException e) {
                    return defaultValue;
                }
            }
            Number fromFile = fileNumber(tomlPath);
            if (fromFile == null) {
                return defaultValue;
            }
            return (float) valueClamp.applyAsDouble(inputTransform.applyAsDouble(fromFile.doubleValue()));
        }
    }

    public static final class StringSetting implements RuntimeSetting<String> {
        private final String key;
        private final String tomlPath;
        private final String defaultValue;
        private final UnaryOperator<String> sanitize;
        private volatile String value;

        private StringSetting(String key, String tomlPath, String defaultValue, UnaryOperator<String> sanitize) {
            this.key = key;
            this.tomlPath = tomlPath;
            this.defaultValue = sanitize.apply(defaultValue);
            this.sanitize = sanitize;
            this.value = resolveInitial();
            SETTINGS.add(this);
        }

        @Override
        public String key() {
            return key;
        }

        @Override
        public String tomlPath() {
            return tomlPath;
        }

        @Override
        public String defaultValue() {
            return defaultValue;
        }

        @Override
        public String get() {
            return value;
        }

        @Override
        public void set(String value) {
            this.value = sanitize.apply(value != null ? value : defaultValue);
        }

        @Override
        public void reloadFromSystemProperties() {
            set(System.getProperty(key, defaultValue));
        }

        @Override
        public void writeToFile(CommentedConfig config) {
            config.set(tomlPath, value);
        }

        private String resolveInitial() {
            String prop = System.getProperty(key);
            if (prop != null) {
                return sanitize.apply(prop);
            }
            String fromFile = fileString(tomlPath);
            return sanitize.apply(fromFile != null ? fromFile : defaultValue);
        }
    }

    public static final class OptionalStringSetting implements RuntimeSetting<String> {
        private final String key;
        private final String tomlPath;
        private volatile String value;

        private OptionalStringSetting(String key, String tomlPath) {
            this.key = key;
            this.tomlPath = tomlPath;
            this.value = resolveInitial();
            SETTINGS.add(this);
        }

        @Override
        public String key() {
            return key;
        }

        @Override
        public String tomlPath() {
            return tomlPath;
        }

        @Override
        public String defaultValue() {
            return null;
        }

        @Override
        public String get() {
            return value;
        }

        @Override
        public void set(String value) {
            this.value = value;
        }

        @Override
        public void reloadFromSystemProperties() {
            this.value = System.getProperty(key);
        }

        @Override
        public void writeToFile(CommentedConfig config) {
            if (value != null) {
                config.set(tomlPath, value);
            } else {
                config.remove(tomlPath);
            }
        }

        private String resolveInitial() {
            String prop = System.getProperty(key);
            return prop != null ? prop : fileString(tomlPath);
        }
    }

    public static final class Rt {
        public static final BooleanSetting ENABLED = bool("caustica.rt", "enabled", true);
        public static final IntSetting WORKER_THREADS =
                intAtLeast("caustica.rt.workerThreads", "worker-threads", defaultWorkerThreads(), 1);

        private Rt() {
        }

        public static final class Composite {
            public static final IntSetting DEBUG_VIEW = intValue("caustica.rt.debugView", "composite.debug-view", 0);
            public static final IntSetting SPP = intAtLeast("caustica.rt.spp", "composite.spp", 1, 1);
            public static final IntSetting MAX_BOUNCES =
                    clampedInt("caustica.rt.maxBounces", "composite.max-bounces", 4, 2, 8);
            public static final BooleanSetting WATER_WAVES =
                    bool("caustica.rt.waterWaves", "composite.water-waves", true);
            /**
             * Shader-only Parallax Occlusion Mapping from the LabPBR {@code _n} alpha height channel.
             * The closest-hit shader marches a short ray through the height field and shades the
             * displaced texel; geometry, BLASes and terrain streaming are never touched, so toggling
             * this (or dragging the sliders) is always safe mid-game. Resource packs without authored
             * height maps are unaffected — the material FEATURE_NORMAL bit gates the whole path.
             */
            public static final BooleanSetting PARALLAX_ENABLED =
                    bool("caustica.rt.parallax", "composite.parallax", true);
            /** Virtual relief depth multiplier (1.0 = 1/8 block of relief). */
            public static final FloatSetting PARALLAX_STRENGTH =
                    clampedFloat("caustica.rt.parallaxStrength", "composite.parallax-strength", 1.0f, 0.0f, 4.0f);
            /** Bilinear (smooth) vs pixel-aligned LabPBR height/normal sampling. */
            public static final BooleanSetting PARALLAX_SMOOTHING =
                    bool("caustica.rt.parallaxSmoothing", "composite.parallax-smoothing", true);
            /** Camera distance (blocks) at which relief fades out; full through 80% of the range. */
            public static final FloatSetting PARALLAX_DISTANCE =
                    clampedFloat("caustica.rt.parallaxDistance", "composite.parallax-distance", 64.0f, 16.0f, 256.0f);
            /**
             * LabPBR subsurface scattering. Light entering the back of a thin surface (leaves, grass,
             * ice plants) scatters through toward the viewer via a forward-biased Henyey-Greenstein
             * phase, which is what makes foliage glow when you look through it toward the sun.
             *
             * <p>Only materials that actually author an SSS channel are affected, so turning this off
             * costs nothing visually on the rest of the world — but it does remove one shadow ray per
             * eligible vertex, so it is a genuine performance lever in heavily vegetated scenes. The
             * flag reaches the shaders through {@code WorldPush.featureFlags} and zeroes the SSS
             * strength at the payload seam, which switches off the RIS back lobe and the explicit
             * transmission pass together.
             */
            public static final BooleanSetting SSS =
                    bool("caustica.rt.sss", "composite.subsurface-scattering", true);
            /**
             * Weather-driven lighting. Rain and thunderstorms attenuate the sun/moon NEE radiance,
             * darken and desaturate the sky toward an overcast grey, hide the celestial discs and the
             * stars behind the cloud deck, and add a light haze to the air.
             *
             * <p>Off restores clear-sky lighting in all weather (the vanilla-shader look), which is
             * also the safe setting if a server drives rain constantly.
             */
            public static final BooleanSetting WEATHER_LIGHTING =
                    bool("caustica.rt.weatherLighting", "composite.weather-lighting", true);
            /**
             * Denoising filter (DLSS Ray Reconstruction). Off traces and presents the raw path-traced
             * image — a reference view that is correct but visibly noisy at low SPP, and, because RR
             * also owns the upscale, one that renders at full display resolution instead of RR's
             * chosen render size.
             *
             * <p>This is the player-facing name for the same switch {@code dlss-rr.enabled} exposes;
             * both must be on for the filter to run, so a machine without RR support is unaffected by
             * this toggle. Changing it re-sizes the trace targets on the next frame (see
             * {@code RtComposite.ensureOutput}).
             */
            public static final BooleanSetting DENOISER =
                    bool("caustica.rt.denoiser", "composite.denoiser", true);
            /**
             * Flat, vanilla-style cloud deck drawn by the sky shader.
             *
             * <p>Caustica cancels vanilla's {@code LevelRenderer}, and vanilla's cloud pass lives inside
             * it, so without this the ray-traced world has no clouds at all. Off restores that
             * (cloudless) behaviour; the deck also follows the vanilla Clouds video option, so setting
             * that to OFF hides it regardless of this toggle.
             */
            public static final BooleanSetting CLOUDS =
                    bool("caustica.rt.clouds", "composite.clouds", true);
            /**
             * Cloud rendering style.
             *
             * <p>{@code classic} reproduces vanilla's flat, blocky deck: coverage is quantised to the
             * 12-block cell grid so the silhouette is genuinely square-edged, and the slab is shaded
             * with vanilla's distinct top/side/bottom faces. {@code volumetric} extrudes the same
             * coverage map into a ray-marched slab with self-shadowing and forward scattering — the
             * look heavy shaderpacks produce, at a real GPU cost.
             *
             * <p>Both styles read one shared coverage field, so switching does not move the clouds and
             * the cloud shadows stay identical between them.
             */
            public static final StringSetting CLOUD_STYLE =
                    string("caustica.rt.cloudStyle", "composite.cloud-style", "classic",
                            Composite::sanitizeCloudStyle);
            /**
             * Cloud thickness, 0..1, as a fraction of {@link #CLOUD_MAX_THICKNESS_BLOCKS}.
             *
             * <p>0 is a flat sheet (the deck collapses to a plane and takes the cheap non-marched
             * path); 1 is a deep bank. Applies to BOTH styles — classic clouds become real vanilla-like
             * boxes with lit tops and shaded sides rather than a decal, and volumetric clouds gain the
             * depth their shading needs to read as cumulus.
             */
            public static final FloatSetting CLOUD_THICKNESS =
                    clampedFloat("caustica.rt.cloudThickness", "composite.cloud-thickness", 0.5f, 0.0f, 1.0f);
            /**
             * How much the cloud deck darkens the sun/moon light reaching the ground beneath it.
             *
             * <p>0 means clouds are visible in the sky but cast nothing; 1 means a fully opaque cloud
             * blocks the celestial light completely. The shadow is an analytic query against the same
             * density function the visible deck is drawn from, so it costs no extra ray and the shadow
             * on the ground always matches the cloud overhead.
             */
            public static final FloatSetting CLOUD_SHADOW_STRENGTH =
                    clampedFloat("caustica.rt.cloudShadowStrength", "composite.cloud-shadow-strength",
                            0.75f, 0.0f, 1.0f);
            /**
             * Opacity of the cloud deck. 0 is invisible (and skips the whole cloud path), 1 fully hides
             * the sky behind a cloud. Values in between let the sky, sun and stars show through.
             */
            public static final FloatSetting CLOUD_OPACITY =
                    clampedFloat("caustica.rt.cloudOpacity", "composite.cloud-opacity", 0.9f, 0.0f, 1.0f);
            /**
             * World Y the BASE of the cloud deck sits at. Vanilla's clouds sit at 192; the default is
             * higher because Caustica's clouds have real thickness and a deck whose base is at vanilla
             * height reads as much closer to the ground than vanilla's flat sheet does.
             *
             * <p>Exposed as a slider: with volumetric clouds the deck's distance is a strong part of the
             * look, and the right value depends on the world's terrain height and the player's taste.
             * The range comfortably spans from just above build height to far overhead.
             */
            public static final FloatSetting CLOUD_HEIGHT =
                    clampedFloat("caustica.rt.cloudHeight", "composite.cloud-height", 320.0f, 128.0f, 1024.0f);
            /**
             * Fraction of the sky the deck covers in clear weather. Rain drives this toward fully
             * overcast on top of whatever is set here (see {@code RtComposite.cloudState}).
             */
            public static final FloatSetting CLOUD_COVERAGE =
                    clampedFloat("caustica.rt.cloudCoverage", "composite.cloud-coverage", 0.55f, 0.0f, 1.0f);
            public static final FloatSetting SUN_ANGULAR_RADIUS =
                    radians("caustica.rt.sunAngularRadius", "composite.sun-angular-radius-deg", 0.6f);
            public static final FloatSetting MOON_ANGULAR_RADIUS =
                    radians("caustica.rt.moonAngularRadius", "composite.moon-angular-radius-deg", 1.5f);
            public static final FloatSetting SUN_NOON_SOUTH_TILT =
                    radians("caustica.rt.sunNoonSouthDeg", "composite.sun-noon-south-tilt-deg", 30.0f);
            public static final FloatSetting JITTER_SIGN_X =
                    finiteFloat("caustica.rt.jitterSignX", "composite.jitter-sign-x", 1.0f);
            public static final FloatSetting JITTER_SIGN_Y =
                    finiteFloat("caustica.rt.jitterSignY", "composite.jitter-sign-y", -1.0f);

            private Composite() {
            }

            /** Shader-side style id; mirrors {@code clouds.slang}'s CLOUD_STYLE_* constants. */
            public static int cloudStyleIndex() {
                return "volumetric".equals(CLOUD_STYLE.get()) ? 1 : 0;
            }

            private static String sanitizeCloudStyle(String value) {
                if (value == null) {
                    return "classic";
                }
                return switch (value.toLowerCase(java.util.Locale.ROOT).replace('-', '_')) {
                    case "volumetric", "volumetrics", "realistic", "3d" -> "volumetric";
                    default -> "classic";
                };
            }
        }

        public static final class Terrain {
            // External keys retain their historical "per-tick" names for config compatibility; terrain
            // streaming is render-pass driven and these Java names reflect the actual scheduling unit.
            public static final IntSetting ASYNC_DISPATCH_PER_PASS =
                    intAtLeast("caustica.rt.asyncDispatchPerTick", "terrain.async-dispatch-per-tick", 32, 0);
            public static final IntSetting COMPLETION_RESULTS_PER_PASS =
                    intAtLeast("caustica.rt.sectionResultsPerTick", "terrain.section-results-per-tick", 32, 0);
            public static final IntSetting MAX_INFLIGHT_SECTIONS =
                    intAtLeast("caustica.rt.maxInflightSections", "terrain.max-inflight-sections", 32, 0);
            public static final IntSetting SECTION_TABLE_INITIAL_CAPACITY =
                    intAtLeast("caustica.rt.sectionTableInitialCapacity", "terrain.section-table-initial-capacity", 512, 1);
            public static final IntSetting REBASE_DISTANCE_BLOCKS =
                    intAtLeast("caustica.rt.rebaseDistanceBlocks", "terrain.rebase-distance-blocks", 128, 0);
            public static final BooleanSetting BLAS_COMPACTION =
                    bool("caustica.rt.blasCompaction", "terrain.blas-compaction", true);

            private Terrain() {
            }
        }

        /**
         * First-person viewmodel (held item / arm) rendering.
         *
         * <p>Vanilla draws the hand through {@code GameRenderer.hudProjection}, a separate perspective built
         * from {@code CameraRenderState.hudFov} — a constant 70° (see {@code Camera.calculateHudFov}) that is
         * deliberately isolated from the FOV slider so the arm never changes size. Enabling
         * {@link #FOV_FOLLOWS_CAMERA} scales that constant to the player's configured FOV instead, so a
         * higher FOV pushes the arm away and a lower FOV pulls it closer.
         *
         * <p>It follows the FOV <em>setting</em>, not {@code Camera.getFov()}: the latter also folds in the
         * transient sprint/zoom multiplier, which would make the arm pump while sprinting and balloon while
         * a spyglass is scoped. The death and underwater/lava FOV modulation baked into {@code hudFov} is
         * preserved either way.
         */
        public static final class Hand {
            public static final BooleanSetting FOV_FOLLOWS_CAMERA =
                    bool("caustica.rt.handFov", "hand.fov-follows-camera", false);

            private Hand() {
            }
        }

        /** Runtime light scaling and RIS block-emitter lights. {@code ris-candidates = 0} disables RIS. */
        public static final class Lights {
            /**
             * Scales the analytic lights created from luminous held items. Caustica's stock held-item
             * dynamic lighting stays on and unchanged at the default 1.0; this remains a config/system-property
             * knob only — the Video Settings screen intentionally exposes just {@link #BLOCK_INTENSITY}.
             */
            public static final FloatSetting DYNAMIC_INTENSITY =
                    lightIntensity("caustica.rt.dynamicLightIntensity", "lights.dynamic-intensity", 1.0f);
            public static final FloatSetting BLOCK_INTENSITY =
                    lightIntensity("caustica.rt.blockLightIntensity", "lights.block-emissive-intensity", 2.0f);
            /**
             * Reservoir-based spatio-temporal resampling for emitter NEE. When disabled, every shading
             * vertex uses the original independent per-frame RIS reservoir and no history allocation is
             * retained. The renderer notices live changes, idles before retiring/recreating the two Vulkan
             * history buffers, and starts newly enabled history from zero.
             */
            public static final BooleanSetting RESTIR_SAMPLING =
                    bool("caustica.rt.restir", "lights.restir-sampling", true);
            public static final IntSetting RIS_CANDIDATES =
                    intAtLeast("caustica.rt.risCandidates", "lights.ris-candidates", 8, 0);
            public static final FloatSetting MIN_FILL_RATIO =
                    finiteFloat("caustica.rt.lightMinFillRatio", "lights.min-fill-ratio", 0.25f);
            public static final BooleanSetting STATS = bool("caustica.rt.lightStats", "lights.stats", false);
            public static final BooleanSetting DUMP = bool("caustica.rt.lightDump", "lights.dump", false);
            public static final IntSetting DUMP_RADIUS =
                    intAtLeast("caustica.rt.lightDumpRadius", "lights.dump-radius", 12, 1);

            private Lights() {
            }
        }

        public static final class Omm {
            public static final BooleanSetting ENABLED = bool("caustica.rt.omm", "omm.enabled", true);
            public static final IntSetting SUBDIVISION =
                    clampedInt("caustica.rt.ommSubdivision", "omm.subdivision", 4, 0, 6);
            public static final BooleanSetting STATS = bool("caustica.rt.ommStats", "omm.stats", false);

            private Omm() {
            }
        }

        public static final class Entities {
            public static final BooleanSetting ENABLED = bool("caustica.rt.entities", "entities.enabled", true);
            public static final BooleanSetting PARTICLES_ENABLED =
                    bool("caustica.rt.particles", "particles.enabled", true);
            /**
             * Ray-traced rain and snow. Vanilla draws weather in its own {@code WeatherEffectRenderer}
             * pass inside {@code LevelRenderer.render}, which Caustica cancels, so this switch is what
             * puts precipitation back in the world at all. The columns are vanilla's own — position,
             * ground clipping and fall animation all come from the render state the game already
             * extracts each frame — replayed as real geometry in the acceleration structure.
             *
             * <p>Shares the particle budget ({@code particles.max-particles}) and requires
             * {@code particles.enabled}, since weather rides the same mesh/BLAS as particle billboards.
             */
            public static final BooleanSetting WEATHER_ENABLED =
                    bool("caustica.rt.weatherParticles", "particles.weather-enabled", true);
            public static final BooleanSetting GLOW_ENABLED =
                    bool("caustica.rt.glow", "entities.glow.enabled", true);
            public static final BooleanSetting NAME_TAGS_ENABLED =
                    bool("caustica.rt.nameTags", "entities.name-tags.enabled", true);
            /** Debug-only: render each model submission twice and require bitwise-identical CPU captures. */
            public static final BooleanSetting CAPTURE_PARITY =
                    bool("caustica.rt.entityCaptureParity", "entities.debug.capture-parity", false);
            public static final IntSetting MAX_ORDINARY_ENTITIES =
                    intAtLeast("caustica.rt.maxOrdinaryEntities", "entities.max-ordinary-entities", 1024, 0);
            public static final IntSetting MAX_BLOCK_ENTITIES =
                    intAtLeast("caustica.rt.maxBlockEntities", "entities.block-entities.max-entities", 1024, 0);
            public static final IntSetting MAX_PARTICLES =
                    intAtLeast("caustica.rt.maxParticles", "particles.max-particles", 1024, 0);
            public static final IntSetting BE_VIEW_CHUNKS =
                    intAtLeast("caustica.rt.beViewChunks", "entities.block-entities.view-chunks", 8, 0);
            public static final IntSetting BE_BUILDS_PER_FRAME =
                    intAtLeast("caustica.rt.beBuildsPerFrame", "entities.block-entities.builds-per-frame", 64, 0);
            public static final BooleanSetting REFIT_ENABLED =
                    bool("caustica.rt.entityRefit", "entities.refit.enabled", true);

            private Entities() {
            }

            public static int maxEntities() {
                return Math.addExact(Math.addExact(
                        MAX_ORDINARY_ENTITIES.value(), MAX_BLOCK_ENTITIES.value()), MAX_PARTICLES.value());
            }

            public static int entityListCapacity() {
                return Math.max(16, maxEntities());
            }

            public static int entityMapCapacity() {
                // Fastutil expected-size constructors apply their own load-factor headroom.
                return Math.max(16, MAX_ORDINARY_ENTITIES.value());
            }
        }

        public static final class EntityTextures {
            public static final IntSetting MAX_TEXTURES =
                    intAtLeast("caustica.rt.maxEntityTextures", "entities.textures.max-textures", 256, 1);
            public static final BooleanSetting PBR = bool("caustica.rt.entityPbr", "entities.textures.pbr", true);

            private EntityTextures() {
            }
        }

        public static final class Overlay {
            public static final BooleanSetting BLOCK_OUTLINE_ENABLED =
                    bool("caustica.rt.blockOutline", "overlay.block-outline.enabled", true);

            private Overlay() {
            }
        }

        public static final class DlssRr {
            public static final BooleanSetting ENABLED = bool("caustica.rt.dlssRr", "dlss-rr.enabled", true);
            public static final IntSetting PRESET = intValue("caustica.rt.dlssRr.preset", "dlss-rr.preset", 0);
            public static final IntSetting QUALITY = intValue("caustica.rt.dlssRr.quality", "dlss-rr.quality", 0);

            private DlssRr() {
            }
        }

        /** DLSS Frame Generation. Default off; gated additionally by hardware/driver availability. */
        public static final class Fg {
            public static final BooleanSetting ENABLED = bool("caustica.rt.fg", "frame-generation.enabled", false);
            public static final IntSetting MULTI_FRAME_COUNT =
                    intAtLeast("caustica.rt.fg.multiFrameCount", "frame-generation.multi-frame-count", 1, 1);

            private Fg() {
            }
        }

        /**
         * NVIDIA Reflex ({@code VK_NV_low_latency2}). Default off; gated additionally by device support.
         * Phase 0 (extension + capability probe only, see {@code RtDeviceBringup}/{@code RtReflex}) — the
         * per-frame sleep call + latency markers + the swapchain {@code VkSwapchainLatencyCreateInfoNV} the
         * spec requires for {@code vkSetLatencySleepModeNV} to take effect land in a later phase.
         */
        public static final class Reflex {
            public static final BooleanSetting ENABLED = bool("caustica.rt.reflex", "reflex.enabled", false);
            public static final BooleanSetting LOW_LATENCY_BOOST =
                    bool("caustica.rt.reflex.boost", "reflex.low-latency-boost", false);
            public static final IntSetting MINIMUM_INTERVAL_US =
                    intAtLeast("caustica.rt.reflex.minIntervalUs", "reflex.minimum-interval-us", 0, 0);

            private Reflex() {
            }
        }

        public static final class Exposure {
            public static final StringSetting MODE =
                    string("caustica.rt.exposure.mode", "exposure.mode", "auto", Exposure::sanitizeMode);
            public static final FloatSetting MANUAL_EV =
                    finiteFloat("caustica.rt.exposure.manualEv", "exposure.manual-ev", 0.0f);
            public static final FloatSetting KEY = exposureScale("caustica.rt.exposure.key", "exposure.key", 0.18f);
            public static final FloatSetting MIN_EV =
                    finiteFloat("caustica.rt.exposure.minEv", "exposure.min-ev", -1.5f);
            public static final FloatSetting MAX_EV =
                    finiteFloat("caustica.rt.exposure.maxEv", "exposure.max-ev", 4.0f);
            public static final FloatSetting ADAPT_UP =
                    exposureScale("caustica.rt.exposure.adaptUp", "exposure.adapt-up", 0.12f);
            public static final FloatSetting ADAPT_DOWN =
                    exposureScale("caustica.rt.exposure.adaptDown", "exposure.adapt-down", 0.35f);

            private Exposure() {
            }

            public static float minEv() {
                return Math.min(MIN_EV.value(), MAX_EV.value());
            }

            public static float maxEv() {
                return Math.max(MIN_EV.value(), MAX_EV.value());
            }

            public static float clampScale(float value) {
                return Math.clamp(value, 1.0e-4f, 1.0e4f);
            }

            private static String sanitizeMode(String value) {
                if ("auto".equalsIgnoreCase(value)) {
                    return "auto";
                }
                if ("manual".equalsIgnoreCase(value)) {
                    return "manual";
                }
                return "auto";
            }
        }

        /** Tonemap curve and final look controls for the SDR display mapper. */
        public static final class Tonemapping {
            public static final StringSetting OPERATOR =
                    string("caustica.rt.tonemap.operator", "tonemap.operator", "agx", Tonemapping::sanitizeOperator);
            /** Extra exposure bias applied after the auto/manual exposure image, in EV stops. */
            public static final FloatSetting EXPOSURE_EV =
                    clampedFloat("caustica.rt.tonemap.exposureEv", "tonemap.exposure-ev", 0.0f, -5.0f, 5.0f);
            public static final FloatSetting GAMMA =
                    clampedFloat("caustica.rt.tonemap.gamma", "tonemap.gamma", 1.0f, 0.5f, 3.0f);
            public static final FloatSetting SATURATION =
                    clampedFloat("caustica.rt.tonemap.saturation", "tonemap.saturation", 1.0f, 0.0f, 3.0f);
            public static final FloatSetting CONTRAST =
                    clampedFloat("caustica.rt.tonemap.contrast", "tonemap.contrast", 1.0f, 0.0f, 3.0f);

            private Tonemapping() {
            }

            public static int operatorIndex() {
                return switch (OPERATOR.get()) {
                    case "pbr_neutral" -> 1;
                    case "aces" -> 2;
                    case "filmic" -> 3;
                    case "linear" -> 4;
                    case "psychov", "psycho_v", "psychovisual", "psycho" -> 5;
                    default -> 0; // agx
                };
            }

            private static String sanitizeOperator(String value) {
                if (value == null) {
                    return "agx";
                }
                return switch (value.toLowerCase(java.util.Locale.ROOT).replace('-', '_')) {
                    case "agx" -> "agx";
                    case "pbr_neutral", "pbrneutral", "neutral" -> "pbr_neutral";
                    case "aces" -> "aces";
                    case "filmic" -> "filmic";
                    case "linear", "passthrough", "pass_through", "none" -> "linear";
                    case "psychov", "psycho_v", "psychovisual", "psycho" -> "psychov";
                    default -> "agx";
                };
            }
        }

        /** Render-frame timing + hitch logging. See {@code RtFrameStats}. */
        public static final class FrameStats {
            public static final BooleanSetting ENABLED = bool("caustica.rt.frameStats", "frame-stats.enabled", false);

            private FrameStats() {
            }
        }

        /** Distant Horizons LOD integration. Requires the Distant Horizons mod to be installed. */
        public static final class DistantHorizons {
            /** Master switch — enable LOD ray tracing when DH is installed. */
            public static final BooleanSetting ENABLED =
                    bool("caustica.rt.dh.enabled", "distant-horizons.enabled", true);
            /** How many chunks beyond vanilla render distance to extend with DH LOD data. */
            public static final IntSetting LOD_CHUNK_RADIUS =
                    intAtLeast("caustica.rt.dh.lodRadius", "distant-horizons.lod-chunk-radius", 128, 32);
            /** How often (in ticks) to rescan DH data for changes. */
            public static final IntSetting SCAN_INTERVAL_TICKS =
                    intAtLeast("caustica.rt.dh.scanTicks", "distant-horizons.scan-interval-ticks", 60, 10);
            /** LOD mesh quad size in chunks (higher = coarser distant LOD, less GPU memory). */
            public static final IntSetting LOD_QUAD_SIZE =
                    intAtLeast("caustica.rt.dh.quadSize", "distant-horizons.lod-quad-size", 8, 2);

            private DistantHorizons() {
            }
        }

        /** Startup Vulkan inventory + {@code VK_EXT_device_fault} reporting on device loss. See {@code VulkanDiagnostics}. */
        public static final class Diagnostics {
            /** Heavy driver-side crash diagnostics: vendor diagnostics-config extensions (shader debug
             * info, resource tracking, automatic checkpoints, shader error reporting) and the
             * {@code deviceFaultVendorBinary} feature (vendor-format crash dump on device loss). Off by
             * default: measured ~10x BLAS build time / -20% fps when enabled. Plain {@code deviceFault}
             * reporting (fault addresses + vendor records) is always on and unaffected. Turn on only
             * while chasing a live device-loss crash. */
            public static final BooleanSetting HEAVY_CRASH_DIAGNOSTICS =
                    bool("caustica.rt.heavyCrashDiagnostics", "diagnostics.heavy-crash-diagnostics", false);

            private Diagnostics() {
            }
        }

        /**
         * HDR display output. When enabled the swapchain is created in PQ (ST.2084/HDR10 — the display-ready
         * encoding both HDR10 swapchains and DLSS Frame Generation require; whatever pixel format the surface
         * pairs with that color space, commonly a 10-bit UNORM), falling back to SDR if the surface doesn't
         * advertise it. The nit values drive the scene-HDR → display mapping: SDR paper white maps to
         * {@code paperWhiteNits}, and highlights roll off toward {@code peakNits}.
         */
        public static final class Hdr {
            public static final BooleanSetting ENABLED = bool("caustica.rt.hdr", "hdr.enabled", false);
            public static final FloatSetting PAPER_WHITE_NITS =
                    clampedFloat("caustica.rt.hdr.paperWhiteNits", "hdr.paper-white-nits", 200.0f, 80.0f, 500.0f);
            public static final FloatSetting PEAK_NITS =
                    clampedFloat("caustica.rt.hdr.peakNits", "hdr.peak-nits", 1000.0f, 80.0f, 5000.0f);

            // Snapshot of ENABLED as resolved at startup (system property / config file), before any
            // in-session edit from the options screen. The swapchain's pixel format (PQ vs SDR) is fixed
            // at surface-creation time, so flipping ENABLED later cannot change what's actually presented
            // until a restart — every runtime/rendering check reads this frozen value via enabled(),
            // never ENABLED directly, so the live toggle is a no-op for the current session.
            private static final boolean ENABLED_AT_STARTUP = ENABLED.value();

            private Hdr() {
            }

            /** Whether the HDR display path (world HDR + PQ swapchain + UI overlay) is active this session. */
            public static boolean enabled() {
                return ENABLED_AT_STARTUP;
            }

            /** Whether {@link #ENABLED} has been changed since startup and needs a restart to take effect. */
            public static boolean pendingRestart() {
                return ENABLED.value() != ENABLED_AT_STARTUP;
            }

            /** Absolute nits SDR paper white maps to in the PQ encode (ST.2084 is referenced to 10000 nits). */
            public static float paperWhiteNits() {
                return PAPER_WHITE_NITS.value();
            }

            /** Highlight headroom above paper white, in paper-white-referred units ({@code >= 1}). */
            public static float headroom() {
                return Math.max(1.0f, PEAK_NITS.value() / Math.max(1.0f, PAPER_WHITE_NITS.value()));
            }
        }
    }

    public static final class Ngx {
        public static final OptionalStringSetting PATH = optionalString("caustica.ngx.path", "ngx.path");

        private Ngx() {
        }
    }

    private static BooleanSetting bool(String key, String tomlPath, boolean fallback) {
        return new BooleanSetting(key, tomlPath, fallback);
    }

    private static StringSetting string(String key, String tomlPath, String fallback, UnaryOperator<String> sanitize) {
        return new StringSetting(key, tomlPath, fallback, sanitize);
    }

    private static OptionalStringSetting optionalString(String key, String tomlPath) {
        return new OptionalStringSetting(key, tomlPath);
    }

    private static IntSetting intValue(String key, String tomlPath, int fallback) {
        return new IntSetting(key, tomlPath, fallback, v -> v);
    }

    private static IntSetting intAtLeast(String key, String tomlPath, int fallback, int min) {
        return new IntSetting(key, tomlPath, fallback, v -> Math.max(min, v));
    }

    private static IntSetting clampedInt(String key, String tomlPath, int fallback, int min, int max) {
        return new IntSetting(key, tomlPath, fallback, v -> Math.clamp(v, min, max));
    }

    private static FloatSetting finiteFloat(String key, String tomlPath, float fallback) {
        return new FloatSetting(key, tomlPath, fallback, v -> v, v -> v, v -> Double.isFinite(v) ? v : fallback);
    }

    private static FloatSetting exposureScale(String key, String tomlPath, float fallback) {
        return new FloatSetting(key, tomlPath, fallback, v -> v, v -> v, v -> Math.clamp(v, 1.0e-4, 1.0e4));
    }

    private static FloatSetting lightIntensity(String key, String tomlPath, float fallback) {
        return new FloatSetting(key, tomlPath, fallback, v -> v, v -> v, v -> Math.clamp(v, 0.0, 16.0));
    }

    private static FloatSetting clampedFloat(String key, String tomlPath, float fallback, float min, float max) {
        return new FloatSetting(key, tomlPath, fallback, v -> v, v -> v, v -> Math.clamp(v, min, max));
    }

    private static FloatSetting radians(String key, String tomlPath, float fallbackDegrees) {
        return new FloatSetting(key, tomlPath, fallbackDegrees, Math::toRadians, Math::toDegrees, v -> Double.isFinite(v) ? v : 0.0);
    }

    private static int defaultWorkerThreads() {
        return Math.clamp(Runtime.getRuntime().availableProcessors() / 2, 1, 4);
    }
}
