package dev.comfyfluffy.caustica.rt.terrain;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;

/**
 * Watertight-seal invariants ({@link RtTerrainMesher#sealBlockQuad} /
 * {@link RtTerrainMesher#sealFluidQuad}). The seal exists because the hardware ray-triangle
 * intersection epsilon can reject a ray that passes through the shared edge/corner of face quads,
 * "missing" the terrain and leaking sky light (a thin bright line at block corners by day, gone
 * at midnight). These tests pin down the geometry the leak-proof relies on:
 *
 * <ul>
 *   <li>face planes never move, span axes grow by exactly 2×EPS, corners keep their order;</li>
 *   <li>the shared edge of two coplanar faces lands strictly INSIDE both extended faces (a hit,
 *       never a miss) — the actual leak-proof;</li>
 *   <li>fluid water heights stay exact (inset-free fluid surfaces are a documented invariant);</li>
 *   <li>non-rectangular and degenerate quads are left untouched rather than mis-extended.</li>
 * </ul>
 */
final class RtTerrainSealTest {
    private static final float EPS = RtTerrainMesher.FACE_SEAL_EPS;

    @Test
    void blockFaceExtendsAlongBothInPlaneAxesOnly() {
        // The +x face of the block at the section origin: plane x=0, y,z ∈ [0,1].
        float[] x = {0f, 0f, 0f, 0f};
        float[] y = {0f, 1f, 1f, 0f};
        float[] z = {0f, 0f, 1f, 1f};
        RtTerrainMesher.sealBlockQuad(x, y, z);
        assertArrayEquals(new float[]{0f, 0f, 0f, 0f}, x, 0f, "the face plane must not move");
        assertEquals(-EPS, y[0]);
        assertEquals(-EPS, z[0]);
        assertEquals(1f + EPS, y[1]);
        assertEquals(-EPS, z[1]);
        assertEquals(1f + EPS, y[2]);
        assertEquals(1f + EPS, z[2]);
        assertEquals(-EPS, y[3]);
        assertEquals(1f + EPS, z[3]);
    }

    @Test
    void halfBlockFaceExtendsByTheSameAbsoluteAmount() {
        // A slab's +z face: plane z=0.5, x ∈ [0,1], y ∈ [0, 0.5].
        float[] x = {0f, 1f, 1f, 0f};
        float[] y = {0f, 0f, 0.5f, 0.5f};
        float[] z = {0.5f, 0.5f, 0.5f, 0.5f};
        RtTerrainMesher.sealBlockQuad(x, y, z);
        assertArrayEquals(new float[]{0.5f, 0.5f, 0.5f, 0.5f}, z, 0f, "the face plane must not move");
        assertEquals(-EPS, x[0]);
        assertEquals(1f + EPS, x[1]);
        assertEquals(-EPS, y[0]);
        assertEquals(0.5f + EPS, y[2]);
    }

    @Test
    void sharedEdgeOfCoplanarFacesLandsInsideBothExtendedFaces() {
        // Two adjacent blocks in the same wall: unit faces at z ∈ [0,1] and z ∈ [1,2] on plane x=0.
        // Before the seal they only TOUCH at the edge z=1; after it, the edge must be strictly
        // interior to BOTH extended faces — that is what turns the driver-epsilon band into a hit.
        float[] ax = {0f, 0f, 0f, 0f};
        float[] ay = {0f, 1f, 1f, 0f};
        float[] az = {0f, 0f, 1f, 1f};
        float[] bx = {0f, 0f, 0f, 0f};
        float[] by = {0f, 1f, 1f, 0f};
        float[] bz = {1f, 1f, 2f, 2f};
        RtTerrainMesher.sealBlockQuad(ax, ay, az);
        RtTerrainMesher.sealBlockQuad(bx, by, bz);

        assertEquals(-EPS, min(az), 0f);
        assertEquals(1f + EPS, max(az), 0f);
        assertEquals(1f - EPS, min(bz), 0f);
        assertEquals(2f + EPS, max(bz), 0f);
        // z=1 is inside both spans with an EPS margin on every side.
        assertTrueRange(-EPS, 1f, 1f + EPS);
        assertTrueRange(1f - EPS, 1f, 2f + EPS);
    }

    @Test
    void slopedWaterTopFaceKeepsHeightsExact() {
        // Water top face with a z-slope: (0, hA, 0) (0, hB, 1) (1, hB, 1) (1, hA, 0).
        float[] x = {0f, 0f, 1f, 1f};
        float[] y = {0.875f, 0.75f, 0.75f, 0.875f};
        float[] z = {0f, 1f, 1f, 0f};
        float[] yOriginal = y.clone();
        RtTerrainMesher.sealFluidQuad(x, y, z);
        assertArrayEquals(yOriginal, y, 0f, "water heights must stay exact (inset-free surfaces)");
        assertEquals(-EPS, x[0]);
        assertEquals(-EPS, x[1]);
        assertEquals(1f + EPS, x[2]);
        assertEquals(1f + EPS, x[3]);
        assertEquals(-EPS, z[0]);
        assertEquals(1f + EPS, z[1]);
    }

    @Test
    void waterSideFaceSealsItsVerticalEdgesAndKeepsHeightsExact() {
        // A water side face on plane x=0 with a sloped top edge:
        // (0, h0, 0) (0, h1, 1) (0, 0, 1) (0, 0, 0).
        float[] x = {0f, 0f, 0f, 0f};
        float[] y = {0.875f, 0.75f, 0f, 0f};
        float[] z = {0f, 1f, 1f, 0f};
        float[] xOriginal = x.clone();
        float[] yOriginal = y.clone();
        RtTerrainMesher.sealFluidQuad(x, y, z);
        assertArrayEquals(xOriginal, x, 0f, "the face plane must not move");
        assertArrayEquals(yOriginal, y, 0f, "water heights must stay exact");
        assertEquals(-EPS, z[0]);
        assertEquals(1f + EPS, z[1]);
        assertEquals(1f + EPS, z[2]);
        assertEquals(-EPS, z[3]);
    }

    @Test
    void nonRectangularQuadIsLeftAlone() {
        // A diamond in the y=0 plane: x takes four values, z three — not an axis-aligned rectangle,
        // so no axis is extended (a partial extension would move corners the wrong way).
        float[] x = {0f, 1f, 0f, -1f};
        float[] y = {0f, 0f, 0f, 0f};
        float[] z = {0f, 1f, 2f, 1f};
        float[] xOriginal = x.clone();
        float[] yOriginal = y.clone();
        float[] zOriginal = z.clone();
        RtTerrainMesher.sealBlockQuad(x, y, z);
        assertArrayEquals(xOriginal, x, 0f);
        assertArrayEquals(yOriginal, y, 0f);
        assertArrayEquals(zOriginal, z, 0f);
    }

    @Test
    void degenerateQuadsAreLeftAlone() {
        float[] point = {1f, 1f, 1f, 1f};
        float[] x = point.clone();
        float[] y = point.clone();
        float[] z = point.clone();
        RtTerrainMesher.sealBlockQuad(x, y, z);
        assertArrayEquals(point, x, 0f);
        assertArrayEquals(point, y, 0f);
        assertArrayEquals(point, z, 0f);

        // A "line" face (two flat axes): nothing to seal.
        float[] lineX = {0f, 0f, 0f, 0f};
        float[] lineY = {0f, 1f, 0f, 1f};
        float[] lineZ = {0f, 0f, 0f, 0f};
        RtTerrainMesher.sealBlockQuad(lineX, lineY, lineZ);
        assertArrayEquals(new float[]{0f, 1f, 0f, 1f}, lineY, 0f);
    }

    @Test
    void sealingPreservesWinding() {
        // Corner order 0,1,2,3 must keep the same orientation: (v1-v0) x (v2-v0) keeps its sign.
        float[] x = {0f, 0f, 0f, 0f};
        float[] y = {0f, 1f, 1f, 0f};
        float[] z = {0f, 0f, 1f, 1f};
        float before = crossSign(x, y, z);
        RtTerrainMesher.sealBlockQuad(x, y, z);
        float after = crossSign(x, y, z);
        assertEquals(1f, before); // sanity: the reference face is +x-wound
        assertEquals(before, after, 0f, "sealing is a scale about the centre: winding must survive");
    }

    private static float min(float[] v) {
        float m = v[0];
        for (float f : v) {
            m = Math.min(m, f);
        }
        return m;
    }

    private static float max(float[] v) {
        float m = v[0];
        for (float f : v) {
            m = Math.max(m, f);
        }
        return m;
    }

    private static void assertTrueRange(float lo, float v, float hi) {
        org.junit.jupiter.api.Assertions.assertTrue(v > lo && v < hi,
                "expected " + lo + " < " + v + " < " + hi);
    }

    /** sign of (v1-v0) x (v2-v0), from corner order 0,1,2. */
    private static float crossSign(float[] x, float[] y, float[] z) {
        float ux = x[1] - x[0], uy = y[1] - y[0], uz = z[1] - z[0];
        float vx = x[2] - x[0], vy = y[2] - y[0], vz = z[2] - z[0];
        float cx = uy * vz - uz * vy;
        float cy = uz * vx - ux * vz;
        float cz = ux * vy - uy * vx;
        return Float.compare(cx, 0f) + Float.compare(cy, 0f) * 2f + Float.compare(cz, 0f) * 4f;
    }
}
