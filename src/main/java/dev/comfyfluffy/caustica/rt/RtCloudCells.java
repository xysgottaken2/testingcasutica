package dev.comfyfluffy.caustica.rt;

import com.mojang.blaze3d.platform.NativeImage;
import dev.comfyfluffy.caustica.CausticaMod;
import net.minecraft.client.Minecraft;
import net.minecraft.resources.Identifier;
import net.minecraft.server.packs.resources.Resource;
import net.minecraft.util.ARGB;

import java.io.InputStream;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.Optional;

/**
 * The authored vanilla cloud deck: {@code textures/environment/clouds.png} decoded into a 256x256 cell
 * map, mirroring {@code CloudRenderer.prepare} (26.2). One pixel = one 12-block cell; a cell is
 * occupied when its alpha is >= 10 (vanilla's {@code isCellEmpty}), and each occupied cell carries the
 * four "is my neighbour empty" bits vanilla packs ({@code packCellData}) plus a "surrounded" bit (all
 * four neighbours occupied) that reserves tall volumetric towers for the cores of large systems.
 *
 * <p>A second, per-cell "shown" byte applies the coverage slider as a <b>size-ranked component
 * filter</b>: the map's occupied cells form connected components (4-neighbour, wrap-aware — the
 * texture tiles), and a cell is shown iff the cumulative occupied-cell count of all components larger
 * than its own stays below {@code coverage * totalOccupied}. The slider therefore chooses how much of
 * the authored deck is up while every cloud stays whole (a system is never cut into pieces); the
 * mapping is measured in docs/cloud-rework-plan.md.
 *
 * <p>Layout behind {@code cloudCellsAddr} in the WorldPush BDA ring (see {@link RtComposite}):
 * 8-byte header (u32 magic "CLDC", u32 version), 65536 occupancy/neighbour bytes, 65536 shown bytes.
 * The shader wraps both axes with a mask — the texture tiles every 256 * 12 = 3072 blocks by
 * construction, which is exactly vanilla's own wrap.
 */
public final class RtCloudCells {
    public static final RtCloudCells INSTANCE = new RtCloudCells();

    public static final int CELLS = 256;
    public static final int CELLS_TOTAL = CELLS * CELLS;
    public static final int HEADER_BYTES = 8;
    public static final int MAP_BYTES = CELLS_TOTAL;
    public static final int SHOWN_BYTES = CELLS_TOTAL;
    public static final int TOTAL_BYTES = HEADER_BYTES + MAP_BYTES + SHOWN_BYTES;
    static final int MAGIC = 0x434C4443; // "CLDC"

    private static final int BIT_OCCUPIED = 1;
    private static final int BIT_NORTH_EMPTY = 2;
    private static final int BIT_EAST_EMPTY = 4;
    private static final int BIT_SOUTH_EMPTY = 8;
    private static final int BIT_WEST_EMPTY = 16;
    private static final int BIT_SURROUNDED = 32;

    private final byte[] bits = new byte[MAP_BYTES];
    private final byte[] shown = new byte[SHOWN_BYTES];
    // Per-cell prefix of the size-ranked component order: the number of occupied cells in components
    // LARGER than this cell's own (sizes descending). Shown iff prefix < coverage * totalOccupied.
    private final int[] componentPrefix = new int[CELLS_TOTAL];
    private int totalOccupied;
    private float lastCoverage = Float.NaN;
    private boolean attempted;
    private boolean available;

    private RtCloudCells() {
    }

    /** True once the map is loaded and valid. Render thread only. */
    public boolean available() {
        return available;
    }

    /**
     * Load the vanilla texture once. Render thread only (uses the live {@code ResourceManager}); a
     * missing or unreadable texture disables clouds permanently, matching vanilla's own failed-reload
     * behaviour (its {@code prepare()} returns empty and the deck is never drawn).
     */
    public void ensureLoaded() {
        if (attempted) {
            return;
        }
        attempted = true;
        Minecraft mc = Minecraft.getInstance();
        if (mc == null || mc.getResourceManager() == null) {
            attempted = false; // client not fully up yet; retry next frame
            return;
        }
        Optional<Resource> resource = mc.getResourceManager()
                .getResource(Identifier.withDefaultNamespace("textures/environment/clouds.png"));
        if (resource.isEmpty()) {
            CausticaMod.LOGGER.warn("Caustica: clouds.png missing from the resource packs; clouds disabled");
            return;
        }
        try (InputStream input = resource.get().open()) {
            try (NativeImage image = NativeImage.read(input)) {
                if (image.getWidth() != CELLS || image.getHeight() != CELLS) {
                    CausticaMod.LOGGER.warn("Caustica: unexpected clouds.png size {}x{}; clouds disabled",
                            image.getWidth(), image.getHeight());
                    return;
                }
                buildMap(image);
            }
        } catch (Exception e) {
            CausticaMod.LOGGER.error("Caustica: failed to decode clouds.png; clouds disabled", e);
        }
    }

    private void buildMap(NativeImage image) {
        boolean[] occupied = new boolean[CELLS_TOTAL];
        for (int y = 0; y < CELLS; y++) {
            for (int x = 0; x < CELLS; x++) {
                occupied[y * CELLS + x] = ARGB.alpha(image.getPixel(x, y)) >= 10;
            }
        }
        // Occupancy byte per cell: occupied + vanilla's neighbour-empty bits + the surrounded flag.
        // Neighbours wrap like vanilla's prepare() (floorMod), so the bit pattern is consistent across
        // the texture's tile seam.
        for (int y = 0; y < CELLS; y++) {
            for (int x = 0; x < CELLS; x++) {
                int i = y * CELLS + x;
                if (!occupied[i]) {
                    continue;
                }
                int north = occupied[(y + CELLS - 1) % CELLS * CELLS + x];
                int east = occupied[y * CELLS + (x + 1) % CELLS];
                int south = occupied[(y + 1) % CELLS * CELLS + x];
                int west = occupied[y * CELLS + (x + CELLS - 1) % CELLS];
                int b = BIT_OCCUPIED;
                if (!north) {
                    b |= BIT_NORTH_EMPTY;
                }
                if (!east) {
                    b |= BIT_EAST_EMPTY;
                }
                if (!south) {
                    b |= BIT_SOUTH_EMPTY;
                }
                if (!west) {
                    b |= BIT_WEST_EMPTY;
                }
                if (north && east && south && west) {
                    b |= BIT_SURROUNDED;
                }
                bits[i] = (byte) b;
            }
        }
        // Connected components (4-neighbour, wrap-aware). Iterative flood fill; the texture is a torus,
        // so the whole map can be one component and a recursive fill would overflow. Cells are appended
        // to one flat list as they are claimed, so the per-component range is known without rescanning.
        int[] componentOf = new int[CELLS_TOTAL];
        java.util.Arrays.fill(componentOf, -1);
        int[] stack = new int[CELLS_TOTAL];
        int[] cellsByComponent = new int[CELLS_TOTAL]; // occupancy-counted cell storage
        int[] componentOffsets = new int[CELLS_TOTAL + 1]; // [c]..[c+1] = cell range of component c
        int fillCursor = 0;
        int componentCount = 0;
        for (int start = 0; start < CELLS_TOTAL; start++) {
            if (!occupied[start] || componentOf[start] != -1) {
                continue;
            }
            componentOffsets[componentCount] = fillCursor;
            int top = 0;
            stack[top++] = start;
            componentOf[start] = componentCount;
            while (top > 0) {
                int i = stack[--top];
                cellsByComponent[fillCursor++] = i;
                int x = i % CELLS;
                int y = i / CELLS;
                int[] neighbours = {
                        y * CELLS + (x + CELLS - 1) % CELLS, // west
                        y * CELLS + (x + 1) % CELLS,         // east
                        (y + CELLS - 1) % CELLS * CELLS + x, // north
                        (y + 1) % CELLS * CELLS + x          // south
                };
                for (int n : neighbours) {
                    if (componentOf[n] == -1 && occupied[n]) {
                        componentOf[n] = componentCount;
                        stack[top++] = n;
                    }
                }
            }
            componentOffsets[componentCount + 1] = fillCursor;
            componentCount++;
        }
        totalOccupied = fillCursor;
        // Size-ranked prefix: components in descending size order; a cell's prefix is the occupied-cell
        // count of every component larger than its own.
        Integer[] order = new Integer[componentCount];
        for (int i = 0; i < componentCount; i++) {
            order[i] = i;
        }
        java.util.Arrays.sort(order, (a, b) -> Integer.compare(
                componentOffsets[b + 1] - componentOffsets[b],
                componentOffsets[a + 1] - componentOffsets[a]));
        int prefix = 0;
        for (Integer component : order) {
            for (int i = componentOffsets[component]; i < componentOffsets[component + 1]; i++) {
                componentPrefix[cellsByComponent[i]] = prefix;
            }
            prefix += componentOffsets[component + 1] - componentOffsets[component];
        }
        available = true;
        lastCoverage = Float.NaN; // force the shown set to rebuild on the next frame
        CausticaMod.LOGGER.info("Caustica: cloud cell map loaded ({} occupied cells, {} components)",
                totalOccupied, componentCount);
    }

    /**
     * Rebuild the shown set for a coverage value: a cell is shown iff the occupied-cell count of all
     * larger components is below {@code coverage * totalOccupied}. Coverage 0 shows nothing, coverage 1
     * shows the full vanilla deck. Cheap enough to run whenever the slider or the weather moves it.
     */
    private void rebuildShown(float coverage) {
        int threshold = (int) Math.floor(coverage * totalOccupied);
        for (int i = 0; i < CELLS_TOTAL; i++) {
            shown[i] = (bits[i] & BIT_OCCUPIED) != 0 && componentPrefix[i] < threshold ? (byte) 1 : (byte) 0;
        }
        lastCoverage = coverage;
    }

    /**
     * Write the map into the WorldPush ring slot and return whether a valid map is present (the caller
     * publishes {@code cloudCellsAddr} = 0 otherwise). Render thread, once per frame per slot.
     */
    public boolean writeFrame(ByteBuffer dst, float coverage) {
        if (!available) {
            return false;
        }
        if (coverage != lastCoverage) {
            rebuildShown(coverage);
        }
        dst.order(ByteOrder.nativeOrder());
        dst.putInt(0, MAGIC);
        dst.putInt(4, 1); // version
        // Bulk-copy both maps: per-byte absolute put() would be 131072 bounds-checked JNI writes per
        // frame; absolute array puts are a single native copy per chunk.
        int chunk = 4096;
        for (int i = 0; i < MAP_BYTES; i += chunk) {
            int n = Math.min(chunk, MAP_BYTES - i);
            dst.put(HEADER_BYTES + i, bits, i, n);
            dst.put(HEADER_BYTES + MAP_BYTES + i, shown, i, n);
        }
        return true;
    }
}
