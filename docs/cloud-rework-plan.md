# Cloud rework — findings, verified facts and plan

Working notes for the cloud half of the weather work. Part 1 (rain + fog) is merged (PR #26);
this file tracks the cloud rework that replaces the procedural deck with vanilla's authored
`clouds.png` cell map.

## Status

- [x] CI evidence: `32c287d` compiled green on 2026-08-01 (run 30682458782, all jobs incl. jar).
  `eed5533` and everything after it never reached the compiler — every run died on the GitHub
  artifact-quota upload. The quota meter is recalculated every 6-12 h after deletion; CI is
  re-triggerable once it clears (re-run from the PR, or a new push).
- [x] PR #25 and PR #24 closed by owner decision (2026-08-05). Absorbed from #25, adapted:
  rain-overcast closure in `cloudState`, storm-greyed cloud tint (via vanilla's own
  `EnvironmentAttributes.CLOUD_COLOR` instead of the hand-tuned ramp), celestial-disc fade in rain,
  global storm shadow. Left out: procedural rain streaks (superseded by `RtWeatherCapture`) and the
  aggressive `rainLight` ramps (the merged values stay).
- [x] Design decisions (owner-confirmed direction): vanilla's `clouds.png` as the only shape source;
  classic style = analytic box intersection; thickness slider = box height, minimum 4 blocks
  (vanilla's extrusion height); only "surrounded" cells get tall volumetric towers.
- [x] Implementation (PR #27, branch arena/019fd4c4-testingcasutica): `RtCloudCells` + WorldPush lanes
  (`cloudCellsAddr`, `cloudColor`), analytic classic boxes, authored volumetric with surrounded-cell
  towers, crossing-region exclusion, rain-overcast closure, celestial-disc fade. Hand-validated
  (box-trace simulation: 22 ray cases; cell-map algorithm replicated against the real PNG; brace/
  symbol cross-checks) — the compiler verdict still has to come from CI once the artifact quota
  meter recalculates.
- [ ] CI validation of the rework (blocked by the GitHub artifact-quota meter; see Status).

## Why the procedural deck kept producing new bugs

The old deck was a procedural noise field (`cloudCoverageField`): three octaves of value noise on a
12-block lattice, thresholded by the coverage slider. Every visual property — where a cloud is, how
big it is, whether the sky closes — was an emergent consequence of that noise plus roughly a dozen
interacting tuning constants (`CLOUD_EDGE_SOFTNESS`, `CLOUD_BULGE`, `CLOUD_VOLUMETRIC_SCALE`,
`CLOUD_BILLOW_DIV_*`, `CLOUD_MAX_SLAB_CROSSINGS`, two extinction scales…). The constants are not
independent: `CLOUD_VOLUMETRIC_SCALE` must stay a reciprocal power of two or the field desyncs at the
anchor wrap; the classic style's `+ CLOUD_EDGE_SOFTNESS * 0.5` threshold offset existed only to keep
both styles covering the same fraction of sky; the opacity slider had to be moved out of the
extinction and applied to the finished march because it was silently doubling as a thickness
multiplier. Fixing one bug tended to surface another.

**Vanilla does not have this problem, because vanilla does not generate a field.** It reads
`textures/environment/clouds.png` — a 256x256 image where each pixel is one 12-block cell — and
extrudes the non-transparent ones. Cloud shape is authored data, not a tuning problem.

## What vanilla actually does (26.2 `CloudRenderer.java`, verified from source)

- `prepare()` reads the PNG into `long[] cells`, one entry per pixel. `isCellEmpty(color)` is
  `ARGB.alpha(color) < 10`. Each cell packs its colour plus four "is my neighbour empty" bits
  (`packCellData`), which is how it culls interior faces.
- `CELL_SIZE_IN_BLOCKS = 12.0F`; the extruded box is **4 blocks tall** (`putVec3(12, 4, 12)`).
- Scroll: `cloudOffset = gameTime % (width * 400L) + partialTicks`, then
  `cloudX = cameraX + cloudOffset * 0.030000001`, `cloudZ = cameraZ + 3.96`. The texture tiles every
  `width * 12` = **3072 blocks**, so the pattern is exactly periodic by construction — no
  anchor-wrap hazard at all (the mod's anchor already wraps to a whole multiple of 3072).
- `CloudStatus.FANCY` extrudes boxes; `FAST` draws only the down face.
- Face shading is flat per orientation (`rendertype_clouds.vsh`): top 1.0, bottom 0.7, north/south
  0.8, west/east 0.9, multiplied by the pushed `CloudColor`.
- Colour comes from `EnvironmentAttributes.CLOUD_COLOR` (ARGB; overworld base `#ccffffff`; rain
  applies `BLEND_TO_GRAY(brightness=0.24, factor=0.5)` ≈ `#cc9e9e9e`; thunder
  `(0.095, 0.94)` ≈ near-black), height from `EnvironmentAttributes.CLOUD_HEIGHT` (192.33).
  **`LevelExtractor` (which Caustica does not cancel) already resolves both into
  `LevelRenderState.cloudColor` / `.cloudHeight` every frame** — the mod reads the resolved value and
  never re-implements the weather ramp.

## Verified properties of the actual clouds.png

- 256x256, RGBA, **binary alpha**: 13356 cells alpha=255 (occupied, 20.4 %), 52180 cells alpha=1
  (empty). Nothing in between — an alpha-threshold coverage slider would do nothing.
- Occupied cells form 1195 connected components (4-neighbour, wrap-aware), sizes 594 down to 1;
  498 components are single cells. Largest component spans ~276 blocks (23 cells).
- 3736 cells (5.7 % of all, 28 % of occupied) have all four neighbours occupied → the
  "surrounded" set that gets tall volumetric towers.

## Design (owner decisions incorporated)

### Cell map transport (no new binding)

- A new `RtCloudCells` class decodes `textures/environment/clouds.png` once (resource manager +
  `NativeImage`, same API the material loader uses) into:
  - 65536 occupancy/neighbour bytes: bit0 occupied (alpha >= 10), bit1..4 N/E/S/W neighbour-empty
    (vanilla's `packCellData` semantics), bit5 surrounded (all 4 neighbours occupied).
  - 65536 "shown" bytes: the coverage filter, rebuilt on the CPU when the coverage slider/weather
    changes (component-size-ranked mapping, see below).
- Written into the existing WorldPush BDA ring **after the ready mask** (same slot, same flush),
  addressed by two new `WorldPush` lanes: `cloudCellsAddr` (uint64, 0 = no map) and `cloudColor`
  (float4: sRGB tint + base alpha). No descriptor/binding changes; the generated
  `WorldPushData`/`WorldPushConstantsData` ABIs follow from the Slang struct.
- Missing texture → `cloudCellsAddr = 0` → `cloudsEnabled` false (clouds off), exactly like
  vanilla with a failed reload.

### Coverage slider with authored data

The texture's alpha is binary, so the slider cannot be a threshold on density. Instead each cell
carries the **size-ranked component prefix**: components are ordered by size (largest first) and a
cell is "shown" iff the cumulative occupied-cell count of all larger components is below
`coverage * totalOccupied`. Coverage = "how much of the authored deck is up", shapes preserved
exactly (a cloud is never cut into pieces). Measured: 0.25 → 25 % of the deck (7 largest systems),
0.55 (default) → 34 systems / 55 %, 1.0 → the full vanilla deck (20.4 % of the sky).
Rain overcast drives coverage to 1 (full deck), which together with the grey `CLOUD_COLOR`,
darkened sky and the celestial-disc fade is how the sky reads as closed — vanilla itself never adds
cells in rain.

### Classic style = analytic boxes (vanilla look)

- A 2D grid traversal over the 12-block lattice steps the ray through the cells inside the deck
  slab; the first shown cell is slab-tested **exactly** (no march, no light loop, no noise).
- Box height = thickness slider, **minimum 4 blocks** (vanilla's own extrusion); at the slider's
  100 % the boxes are `CLOUD_MAX_THICKNESS_BLOCKS` (110) tall.
- Shading reproduces `rendertype_clouds.vsh` exactly: flat face tones (top 1.0 / bottom 0.7 /
  x-sides 0.9 / z-sides 0.8) × `cloudColor` × sun radiance, plus the small sky fill the deck needs
  at night. The vanilla alpha (0xCC ≈ 0.8) is the weather-resolved base opacity, multiplied by the
  player's opacity slider.
- The old flat-plane path (`cloudTrace`/`cloudAlpha`/`cloudRadianceClassic`) is deleted: thickness
  0 is now a 4-block box, per the owner decision.

### Volumetric style = authored coverage + reserved towers

- Density base is the shown cell (one byte lookup, no noise for the 80 % of samples that fall on
  empty cells); the existing domain warp + billow octaves shape the interior and erode the edges.
- Tower rule: cells whose whole 4-neighbourhood is occupied (the 28 % of the deck) get the full
  slab height; cells with empty neighbours stay low (bottom ~30-55 % of the slab). The deck reads as
  "a few thick towers in the big systems, thin puffs elsewhere" instead of uniform depth.
- Light march and march budgets unchanged in structure; the density is much cheaper per sample.

### Bug 1 — the camera-following horizontal band

Root cause: the volumetric march has **no crossing handling at all** (the `crossFade` existed only
in the flat plane path). When the camera sits near the deck mid-plane, near-horizontal rays stay
inside the slab for up to `CLOUD_MAX_SLAB_CROSSINGS` slab depths and saturate, painting a bright
band at the deck altitude that follows the camera. Fix, as planned: **exclude the slab within the
crossing region** — in `cloudMarch`, when the origin is inside the crossing band
(`crossFade <= 0`), return no cloud; outside the band the result is scaled by `crossFade` so the
deck dissolves smoothly at the band edge, consistent with the old flat deck's behaviour.
(The classic box path needs no special case: boxes are thin and sparse, so grazing rays hit an
actual box edge at most a few cells away — vanilla renders the same way from inside a cloud.)

### Bug 2 — classic clouds white in rain

Fixed by the pushed `cloudColor` lane: the classic box shading multiplies by the vanilla
weather-resolved tint (clear ≈ white, rain ≈ 0.62 grey, thunder ≈ 0.15 dark), so the greying is
vanilla's own value, not a shader ramp. (`CLOUD_ALBEDO` is deleted.)

### Bug 3 — sky never closes in rain

- `cloudState` absorbs PR #25's ramp: `overcast = rain + thunder * 0.25` (full rain closes by
  itself), coverage **and opacity** pushed to 1, shadow floored at `overcast * 0.95`.
- `cloudSunShadow` absorbs the global storm branch: in closed overcast the attenuation applies to
  every receiver, not only cells under an occupied column — no dappled sun patches through holes.
- `world.rmiss` absorbs the celestial-disc fade (`1 - smoothstep(0.02, 0.65, stormStrength)`), so no
  sun/moon sprite leaks through deck holes.
- Combined with the existing overcast sky darkening, full rain reads as a closed grey ceiling —
  with the *texture's* holes, exactly like vanilla, rather than a procedurally forced solid slab.

### Performance

- Classic: ~1 cell lookup + exact slab test per grid step; no noise, no light march.
- Volumetric: empty cells cost one lookup; occupied cells cost the warp/billow noise as before, but
  the base field (previously ~6 noise evals) is one lookup. The big remaining cost is the per-step
  light march; the plan's gain #2 (bake the deck's 2D optical depth once per frame) is a follow-up,
  not part of this pass.
- Deleted: `CLOUD_EDGE_SOFTNESS`, `CLOUD_ALBEDO`, `CLOUD_FLAT_EPSILON`, the classic branch of
  `cloudMarch` (analytic boxes replace it), `cloudTrace`/`cloudAlpha`/`cloudRadianceClassic`.

## Open questions (need the owner's eye after a visual pass)

1. Default `CLOUD_COVERAGE` is 0.55 → 55 % of the deck (11 % of the sky). The full vanilla deck is
   20.4 % of the sky; the default may want to move up (e.g. 0.8) once seen in-game.
2. Deck height stays on the config slider (default 320); vanilla's `CLOUD_HEIGHT` (192.33) is not
   pushed. With thin vanilla-shaped boxes the vanilla height may look right again — decide after
   seeing it.
3. The volumetric tower profile (surrounded → full slab, else bottom 30-55 %) and the warp/billow
   divisors are first guesses; tune from screenshots.
