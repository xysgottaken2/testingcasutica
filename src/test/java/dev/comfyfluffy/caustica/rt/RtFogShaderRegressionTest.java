package dev.comfyfluffy.caustica.rt;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Regression guards for the world-space fog (fog.slang) that are easy to re-break in shader-only
 * changes.
 *
 * <p>Two properties must survive any refactor: the fog is WORLD SPACE — its density is a function
 * of the ray's world position, not of its screen distance — and it CANNOT PASS THROUGH BLOCKS:
 * every segment integral is bounded by the distance to the nearest scene hit, so geometry in front
 * of the fog stops the segment and the fog beyond it is never integrated (a mountain shows only
 * the fog in front of it; a cave only the thin air to its nearest wall).
 */
final class RtFogShaderRegressionTest {
    private static final Path REPO_ROOT = repoRoot();
    private static final Path FOG = REPO_ROOT.resolve("shaders/world/fog.slang");
    private static final Path WORLD_COMMON = REPO_ROOT.resolve("shaders/world/world_common.slang");
    private static final Path WORLD_RGEN = REPO_ROOT.resolve("shaders/world/world.rgen.slang");

    @Test
    void fogDensityIsAFunctionOfWorldPosition() throws IOException {
        String source = Files.readString(FOG);
        // The density field must read the ray's WORLD height (camera-relative position minus the
        // pushed base), never the segment length alone: a length-only fade would be screen-space.
        assertTrue(source.contains("posRel.y - push.fogParams.y"),
                "fog density must be a function of the position's world height, not the segment length");
        assertTrue(source.contains("exp(-k * max(0, h))") || source.contains("exp(-k * max(fogHeightAboveBase"),
                "the one-sided height profile is the documented density model");
        assertTrue(source.contains("push.dimension == DIMENSION_OVERWORLD"),
                "fog must stay in the Overworld (closed skyboxes have no air to fog)");
        assertTrue(source.contains("!worldFlag(push, WORLD_FLAG_SUBMERGED)"),
                "the submerged eye already lives in the water medium's own extinction");
    }

    @Test
    void fogIsBoundedByTheFirstHitOnEverySegment() throws IOException {
        String source = Files.readString(WORLD_RGEN);
        // The per-segment fog must take payload.hitT as its range — the same first-hit bound the
        // cloud deck uses — so fog beyond a surface is never integrated.
        assertTrue(source.contains("fogSegment(worldPush, ro - worldPush.camOffset, rd, payload.hitT)"),
                "the camera->hit segment must integrate fog bounded by payload.hitT");
        // The sky-miss case integrates over a large finite range (the analytic integral saturates).
        assertTrue(source.contains("fogSegment(worldPush, ro - worldPush.camOffset, rd, FOG_SKY_DISTANCE)"),
                "the sky must be fogged over the analytic sky range");
        // The dielectric camera prefix (segments that start at the surface, not the camera) must
        // recover the fog crossed on the way there, bounded by the surface like the cloud prefix.
        int prefix = source.indexOf("FogVolume preFog = fogSegment(worldPush, float3(0.0, 0.0, 0.0),");
        assertTrue(prefix >= 0, "the dielectric camera prefix must apply the fog crossed on the way to the surface");
        assertTrue(source.indexOf("prefixDist);", prefix) > prefix,
                "the prefix fog must be bounded by the camera->surface distance");
    }

    @Test
    void fogAttenuatesTheSceneAndAddsInScatter() throws IOException {
        String source = Files.readString(WORLD_RGEN);
        // Premultiplied participating-medium composite, same shape as the cloud segment: in-scatter
        // added at the lobe's channel, transmittance multiplied into the throughput.
        assertTrue(source.contains("FogVolume segFog = fogSegment(worldPush, ro - worldPush.camOffset, rd, payload.hitT)"),
                "per-segment fog is missing from the bounce loop");
        int at = source.indexOf("FogVolume segFog");
        String tail = source.substring(at, Math.min(at + 1200, source.length()));
        assertTrue(tail.contains("L += throughput * segFog.scatter;"),
                "the fog in-scatter must be added to the accumulated radiance");
        assertTrue(tail.contains("throughput *= segFog.transmittance;"),
                "the fog transmittance must attenuate everything beyond it");
    }

    @Test
    void fogDimsTheSunBetweenSurfaceAndLight() throws IOException {
        String source = Files.readString(WORLD_RGEN);
        // The direct-light (NEE) term must be attenuated by the fog between the shading point and
        // the sun — the same analytic query the camera-segment fog uses — or light leaks into a fog
        // bank unattenuated while the in-scatter above brightens it. Both lazy sites (front NEE and
        // SSS back-face) must carry the same attenuation.
        int count = countOccurrences(source,
                "cloudShadow *= fogSunAttenuation(worldPush, hitPos - worldPush.camOffset, lightDir);");
        assertTrue(count >= 2,
                "both the front-face NEE and the SSS lazy site must apply the fog sun-attenuation, found " + count);
    }

    @Test
    void worldPushCarriesTheFogLanes() throws IOException {
        String source = Files.readString(WORLD_COMMON);
        assertTrue(source.contains("public static const uint FEATURE_FOG = 512u;"),
                "FEATURE_FOG must own bit 512 in world_common.slang");
        assertTrue(source.contains("public float4   fogParams;"),
                "WorldPush must carry the fogParams lane (x density, y base, z falloff, w strength)");
    }

    private static int countOccurrences(String source, String needle) {
        int count = 0;
        int at = source.indexOf(needle);
        while (at >= 0) {
            count++;
            at = source.indexOf(needle, at + needle.length());
        }
        return count;
    }

    /** Same root discovery pattern as RtShaderConstantMirrorTest, kept local to avoid test coupling. */
    private static Path repoRoot() {
        Path dir = Path.of("").toAbsolutePath();
        for (Path candidate = dir; candidate != null; candidate = candidate.getParent()) {
            if (Files.isDirectory(candidate.resolve("shaders/world"))
                    && Files.isDirectory(candidate.resolve("src/main/java"))) {
                return candidate;
            }
        }
        throw new IllegalStateException("could not locate the repository root from " + dir);
    }
}
