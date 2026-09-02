# Realistic volumetric clouds

What the `volumetric` cloud style now models, why each part of it is there, and where every number comes
from. Everything described here lives in `shaders/world/clouds.slang` (the deck) and
`RtComposite.cloudState` (the lanes it reads); `RtCloudShaderRegressionTest` and
`RtCloudPeriodMirrorTest` guard the parts that are easy to lose in a tuning pass.

The `classic` style is untouched by this work and is meant to keep looking like Minecraft's own cloud
boxes. Where the two share code, the classic path is called out explicitly.

---

## 1. The brief

Make the volumetric deck look like real cloud — the look a heavy shader pack such as
[Photon](https://github.com/sixthsurge/photon) produces — by ray marching, after studying both the
technique and the thing being imitated. One specific requirement came with it:

> since clouds are no longer a PNG, the height slider must not control the distance from the ground, it
> must control the *thickness* (grossura) of the cloud.

The final revision of this PR supersedes half of it: the height slider keeps the first half (where
the deck sits), but the volumetric deck's *thickness* is no longer a slider at all — how deep a cloud
is comes from the genus model (§4.2) and from each parcel's own vigour (§4.3), because a global
thickness was precisely the knob that made the deck read as a rectangle whose look depends on a
slider. The thickness option now shapes only the classic boxes, and the volumetric clouds screen
replaces that row with a greyed-out explanation saying exactly that.

That requirement is about a distinction a flat texture cannot express. `clouds.png` was one plane: a
single number described both how far away it was and how big the clouds looked. A modelled deck has two
independent properties — **where the layer sits** and **how much cloud is in it** — so they are two
controls, and the deck's depth is never a side effect of moving it. See §6.

## 2. What the previous model actually got wrong

Not "it was ugly" — three measurable defects, each with a cause:

1. **It was a 2D picture extruded through a height profile.** Coverage and erosion were both sampled from
   2D noise, so the same pattern repeated at every altitude: lobes lined up vertically through the whole
   depth and the crown never broke into individual heads. Real cloud is a 3D structure — a parcel rises,
   condenses, entrains dry air at its edges and rolls into lobes independently at every height.
2. **It was single-scattering in a medium that is not.** Measured optical depth of low water cloud is
   12–92 (geometric mean ~34), so a photon scatters tens of times before it escapes. Single scattering
   renders that as a silhouette with a black underside, which is the "flat grey cotton" look.
3. **It was eight times too dim, and dim in the wrong places.** One sun term attenuated by one shadow
   march, plus a hand-tuned `skyBehind * 0.35` ambient. Calibrated against the real sky (§5.6), the old
   interior produced ~0.03 · E where a sunlit cloud top should produce ~0.24 · E.

A fourth thing was not a defect but a missing input: the deck had one shape regardless of weather, so
rain made it darker but never made it a *different kind of cloud*.

## 3. Reference material

**Photon** ([sixthsurge/photon](https://github.com/sixthsurge/photon)) — read as a working example of a
shipping real-time cloud pass, which is the fastest way to see how the published techniques are actually
assembled and what they cost. What was learned from looking at it, as *technique*: the order of the
density pipeline (coverage → altitude shaping → detail erosion → edge sharpening → final height ramp);
an edge-sharpening exponent that thins or fattens the field; the optical-depth march on exponentially
growing strides with a dithered start; a per-bounce-order scattering loop that relaxes scattering,
extinction, phase anisotropy and the powder term together; separate light probes for the celestial, the
sky and the ground rather than one shadow march; an early exit once the medium saturates; a two-scale
coverage field; and per-cloud-type parameter sets instead of one global shape.

**No code was taken from it.** Nothing in this repository is derived from Photon's source: no file,
function, expression, identifier, constant set or asset of its appears here, and the two implementations
could not be further apart mechanically — Photon is GLSL for Iris/OptiFine-style loaders, sampling
precomputed 3D noise and coverage textures through uniforms, while this module is Slang in Caustica's
ray-tracing pipeline, reading `WorldPush` lanes and generating every field it samples from a periodic
integer hash written here (`cloudHash3Bits`/`cloudHash3`/`cloudNoise3`/`cloudBillow3`/`cloudWorley3`),
with no texture or sampler of any
kind in the file. Photon's own license explicitly permits examining and learning from its source, which
is all that was done; where this document names it, that is provenance of an idea and not of code. Every
number below comes either from published literature or from a derivation in this repo (§5.6 calibrates
the deck's brightness against the real sky rather than against another shader).

**Unreal Engine 5's Volumetric Cloud** (and the public writeups of its shape stage) — consulted for the
*calibration* of the height profile rather than for any technique: its shape textures are authored
against per-type height gradients, and the published presets are the clearest statement anywhere of what
"cumulus" and "congestus" mean numerically — a fair-weather cumulus closes its dome at roughly
`(0.0, 0.2, 0.42, 0.6)` of the layer (base ramp over the first fifth, top fade from 0.42 to 0.6) while a
developing tower runs `(0.0, 0.08, 0.75, 0.98)` (near-instant flat base, dome closing at the layer top).
Also from that lineage: the weather map carrying per-region type and height, and the observation that
inverting the detail noise at the cloud base is what produces wispy fractus. §4.3 tunes this model's
genus profiles against those two gradients.

**Horizon Zero Dawn's Nubis / Frostbite / Skybolt lineage** (Hillaare's *Physically Based Sky,
Atmosphere and Cloud Rendering in Horizon Zero Dawn*, Wrenninge's multi-scattering writeups) — the
bedrock technique: low-frequency shape eroded by high-frequency detail, height-gradient presets per
cloud type, curl-noise turbulence scaled by altitude, the beer's-powder dark-edge term, and the octave
approximation to multiple scattering (`k = falloff^order`, phase mixed toward `1/4π` by `k`). Also the
marching hygiene: dithered start (Bayer or rotating blue noise), exponentially growing light-march
strides, early exit once the medium saturates.

**Terrestrial cloud optics** (Kokhanovsky's review of light scattering by water clouds; CALIPSO/MODIS
optical-depth climatologies) — where the physical constants come from: extinction coefficient
σ_ext = 1.5 · LWC / a_eff ≈ 0.005–0.1 m⁻¹ (about 0.1 m⁻¹ for a typical a_eff = 6 µm / LWC = 0.4 g m⁻³
layer, i.e. opaque within ~100 m); single-scattering albedo ω₀ ≈ 0.9999 in the visible, so **cloud
darkness is path length, not absorption**; liquid water content ramps up roughly linearly from cloud
base (adiabatic condensate) and falls off near the top (dry-air entrainment), which is the asymmetric
height profile; cloud base is the lifting condensation level, which is why every real deck has a flat
bottom seen from the side.

**WMO genera** — the three shapes this altitude shows: stratocumulus/stratus (continuous, shallow
300–600 m, flat-topped, capped by an inversion), fair-weather cumulus humilis/mediocris (individual
heaps about as wide as they are deep), and cumulus congestus/cumulonimbus (convective, several times
deeper, crown filling the layer).

## 4. Geometry: where cloud is, and what shape it has

Three layers, in the order `cloudVolumeDensity` evaluates them.

### 4.1 Coverage — 2D, shared with the shadow

A cloud *layer*'s horizontal structure genuinely is two-dimensional (one condensing air mass), so
coverage stays a 2D field: `cloudVolumetricCoverage`, reading `cloudCoverageField` (three octaves of
periodic value noise) at `CLOUD_SHAPE_DIV = 2.0`, which puts one cell at 48 blocks — a cloud a few
hundred blocks across, deliberately matched to the deck's depth because real cumulus are about as wide
as they are tall.

Before the threshold, the field is pushed toward its own extremes (one smoothstep of itself). A raw
value-noise field is a Gaussian-ish wash around 0.5, so thresholding it directly gives every cloud the
same soft wide skirt and no clean air between neighbours — a sky of connected blobs. The contrast pass
is what separates individual clouds with real gaps and crisp edges.

A second, independent reading of the same lattice then shifts the THRESHOLD up and down across the sky
(`CLOUD_COVERAGE_CLUSTER = 0.5`): in one region neighbours merge into one big mass, in the next they
shrink to scattered fragments with genuine clear air between the groups. A single global threshold
gives every cloud the same skirt and the same size — a sky of evenly spaced puffs, which is not a
sky.

It is **one function with three callers** (visible density, cloud-shadow query, flat-sheet fallback).
That is a fix, not a tidy-up: the shadow and the density used to merge the weather fill differently, so
in rain the deck stayed at the slider's coverage while its shadow closed the sky completely.

### 4.2 Genus — the weather picks the shape

`cloudWeather` resolves one struct per march from lanes the frame already pushes, so no two parts of the
deck can disagree about what the sky is doing:

| lane | use |
| --- | --- |
| `push.clouds.x` | the coverage slider |
| `push.cloudColor.w` | the weather overcast fill (rain drives it toward 1) |
| `push.weather.x/y` | rain and thunder, **gated on `FEATURE_WEATHER_LIGHTING`** so the deck only changes shape where the rest of the renderer agrees weather exists |

* `sheet` = `smoothstep(0.55, 0.92, coverage)` — a closed sky is a **sheet**; a scattered one is heaps.
  That is how the real sky behaves, so the coverage slider now changes cloud *genus* and not merely
  density.
* `convection` = `max(0.45 · 4c(1−c) · (1−sheet), thunder)` — vertical development peaks on a sunny day
  building cumulus, and in thunderstorms, where the tower *is* the storm. An overcast sheet suppresses
  it: nothing is being heated from below. The 0.45 is calibration, not taste: the raw parabola peaks at
  1.0 for 50% coverage, which turns every scattered fair-weather sky into slab-filling congestus, while
  the published cumulus height gradient (§3) closes its dome at about half the layer.
* `absorbing` = `rain · 0.55 + thunder · 0.45` — precipitating cloud adds extinction (§5.1). Droplets
  that grew large enough to fall no longer scatter cleanly, which is why a storm's underside reads
  grey-green rather than merely shadowed.

There is deliberately **no slider for any of this**. It is the same weather state that dims the sun,
darkens the sky and thickens the fog, so a storm's deep grey deck, its dimmed light and its heavy air
are one reading of one state.

The genus also sets how DEEP the deck is: `cloudDeckDepth` returns 64 blocks for a sheet, 165 for
heaps and 210 for towers, and the volumetric march takes that as its slab instead of the pushed
thickness — the same one-reading-of-one-state argument as above, applied to the slab itself. A cloud's
depth belongs to the sky that made it; §4.3 then develops each individual parcel inside that slab to
its own height.

### 4.3 Height profile — flat base, crown that knows the genus

* **Base** (`CLOUD_BASE_RAMP_HEAP = 0.06`, `SHEET = 0.22`): the lifting condensation level. Below it the
  air is unsaturated and there is no cloud at all, which is why every real deck has a flat bottom. A
  heap's base is sharp (one parcel that just reached saturation); a sheet's frays into mist (stratus
  forms by shallow cooling over a wide area, not by a rising parcel).
* **Crown** (`HEAP = 0.55`, `TOWER = 0.94`, `SHEET = 0.48`, rounding `0.30`, clamped to close at the
  slab top at the latest): where the top starts to round off, tuned against UE5's published height
  gradients (§3) — an ordinary cumulus domes at ~55–75% of the layer, a developing tower at the very top,
  an inversion-capped sheet at half. **Dense cores tower**: the *local* coverage lifts the crown through
  `smoothstep(0.35, 0.90, coverage)`, so the thick middle of a bank billows up into towers while its
  wispy edges stay low and flat, and one sky holds low fringes, mid heaps and tall towers at once. That
  coupling — nonlinear, so different clouds in one sky get different heights — is most of why the result
  reads as a field of individual clouds instead of one extruded slab.
  The clamp on the fade's end is load-bearing: without it a tall crown's fade would finish *above* the
  slab and the deck would be sliced flat by its own ceiling, which is exactly the "straight top that
  follows the thickness slider" artefact this model exists to avoid.
* **Belly bulge** (`CLOUD_BULGE = 0.42` at `CLOUD_BELLY_HEIGHT = 0.42`, heaps only): a cumulus is widest
  around its lower-middle and pulls in toward both base and crown, so the coverage is relaxed there and
  the same cloud grows sideways in its belly. A sheet has no belly, so the term is scaled out by
  `1 − sheet`.
* **Vigour** — a per-cloud stretch of the height coordinate, `lerp(1.30, 0.72, …)` of one low-frequency
  reading of the shape lattice at its own offset, scaled out by `sheet`. Stretched past 1 the profile
  closes its dome low (a shallow humilis puddle); compressed below 1 the same profile closes high (a
  towering mediocris). Two clouds with identical local coverage draw different numbers, so one sky
  holds shallow and deep parcels side by side — without it every cloud develops to the same fraction
  of the slab and the deck reads as one population of identical puffs.

The profile is asymmetric on purpose (measured LWC ramps up from base, decays near the top); a symmetric
lens is what makes a procedural deck read as a slab.

### 4.4 Turbulence — wind shear without a curl-noise texture

Real decks are sheared: wind speed and direction change with altitude, so updrafts lean downwind and a
crown curls while its base stays flat. The sample position is displaced by a smooth low-frequency noise
before the erosion is read (`CLOUD_WARP_AMPLITUDE_BLOCKS = 26`, growing to `CLOUD_WARP_SHEAR = 2.2×` at
the crown, with `CLOUD_WARP_VERTICAL = 0.55` of it leaning the tower over rather than merely smearing
its footprint).

HZD and Frostbite sample a curl-noise *texture* for this. This module cannot: a deck that must survive
the anchor wrap may only sample fields that are periodic with it (§7). Altitude enters as a coordinate
*offset*, which is what makes the displacement grow and slide with height at 2D-noise cost.

### 4.5 Erosion — the 3D part

The erosion FBM is the **Perlin-Worley pair**, generated rather than sampled. A coarse **3D** billow
octave (`cloudBillow3` = `1 − |2·noise₃ − 1|`, value noise folded into rounded lobes) at
`CLOUD_BILLOW_DIV_COARSE = 2.0` — lobes 48 blocks across, a fifth of a cloud's width, which is the
scale real cumulus cauliflower shows — carries the lobes, and a fine **Worley
(cellular) F1** octave at `CLOUD_BILLOW_DIV_FINE = 0.25` — cells 6 blocks across — carves the crisp
scoops between those lobes. Billow alone has soft boundaries everywhere, which is the "aerated cotton
wool" read that separates a procedural deck from a real crown; cellular noise is what removes it. This
is the one field in the module that every write-up of the technique describes as a precomputed texture,
and here it is computed at runtime: `cloudWorley3` walks the 3×3×3 neighbourhood of the sample's cell
and returns the distance to the nearest feature point, each feature being its cell's centre plus a
jitter of ±0.4 cells (`CLOUD_WORLEY_JITTER = 0.8`). Because the jitter stays under half a cell per axis,
the nearest feature point is provably inside that neighbourhood, so 27 taps is an **exact** F1 rather
than an approximation. Each tap costs one hash, from which all three jitter components are unpacked as
8-bit slices (`cloudHash3Bits`), so the octave is 27 hashes rather than 81 — still the most expensive
thing in the density, which is why it lives only at `CLOUD_DETAIL_FULL` and behind the distance LOD.

Raw F1 averages ≈0.511 on this lattice. `CLOUD_WORLEY_REMAP_SCALE = 2.55` with
`CLOUD_WORLEY_REMAP_BIAS = −0.81` — both fitted numerically over 26³ samples of exactly this hash and
this jitter — remap it to a mean of exactly 0.500, with ~25% of the range landing on the clamps, and
that clipping *is* the crispness. The mean is not cosmetic: the SHAPE tier substitutes this octave's
expected value for it (§5), so a hand-guessed remap would silently bias every light probe.

The vertical axis is a real third dimension on its own lattice (`cloudHash3`, masked to
`CLOUD_VERTICAL_CELLS = 256`), and it is sampled in **blocks above the deck's own base**, never in
camera-relative Y: the deck's internal structure is pinned to the world, so it does not swim past the
eye as the camera rises or falls. `RtCloudShaderRegressionTest` asserts the absence of `posRel.y` in the
density function for exactly this reason.

Erosion then bites hardest where the field is thin (the fraying edge) and at the slab extremes — the crown
breaking into lobes, the base dissolving into mist (`CLOUD_EROSION_EDGE = 0.75`, `CROWN = 0.55`,
`BASE = 0.35`) — leaving the interior solid. Uniform erosion is what makes procedural cloud read as flat
fluff. Finally `edge_sharpening`: an exponent interpolated from `1.55` at the base (thins → wispy,
mist-like underside) to `0.90` at the crown (fattens → hard, well-defined top).

## 5. Optics and light transport

### 5.1 Extinction and albedo

`CLOUD_EXTINCTION = 0.42` per block at unit density. Measured water cloud is 0.005–0.1 m⁻¹ and a real
cumulus is opaque because it is hundreds of metres deep (τ 30–100 straight up); this deck is a
compressed sky a few tens of blocks deep, so it cannot buy that opacity with depth and buys it per
block instead. At the physical per-metre value a core here reached τ ≈ 1–3 — see-through cotton wool
with no shadowed underside, the single most visible difference between this constant and a cloud that
reads as a cloud. At 0.42 a developed core sits at τ ≈ 7–15 (opaque body, dark base, silver lining at
the rim) while a few blocks of fringe at low density still transmit, which is the core/wisp split real
clouds show.

`CLOUD_SINGLE_SCATTER_ALBEDO = 0.9995` follows the measured ω₀: scattering is essentially everything, so
cloud darkness is path length. The small deficit is the only absorption the deck has, and precipitating
cloud adds to it via `CLOUD_STORM_ABSORPTION = 0.85 × absorbing` — **volumetric only**, because classic
already greys in rain through `push.cloudColor` and would otherwise darken twice for the same weather.

Extinction is normalised by `CLOUD_REFERENCE_THICKNESS = 40` blocks, so a deeper deck adds **volume
without adding opacity**. Without it, τ = σ · path grows with the slab depth and the thickness slider
silently doubles as a second opacity control — a deep deck going solid white at the horizon while the
opacity slider still says 20%.

### 5.2 Phase — three lobes

`CLOUD_PHASE_BROAD/SILVER/BACK = 0.50/0.30/0.20` over HG lobes at `g = 0.60`, `0.88` and `−0.22`. Mie
scattering by ~10 µm droplets is dominated by a very tight forward peak inside a broad glow, plus a weak
backward lobe from diffraction and internal reflection. The tight peak *is* the silver lining on a
backlit edge; the broad glow is the general sun-side brightening; the back lobe is what stops the shadow
side collapsing into a silhouette. Weights sum to 1, so the mixture stays 4π-normalised and the expansion
cannot invent energy. A weighted sum of HG lobes is the usual cheap stand-in for a Mie table.

### 5.3 Three optical-depth probes

One sample asks three different questions about three different directions, and answering only the first
is what leaves a deck looking like lit cotton wool with a black underside. All three return **raw**
∫ density dl in blocks, because the octave expansion needs the same quantity at several different
extinction coefficients.

| probe | how | why |
| --- | --- | --- |
| **sun/moon** | `CLOUD_LIGHT_STEPS = 6` strides growing ×2 each (`CLOUD_LIGHT_STEP_GROWTH`), over a span of one deck depth divided by the light's elevation (floored at `CLOUD_LIGHT_MIN_SUN_ELEVATION = 0.35`) | self-shadowing is decided within tens of blocks of the sample, while the shadow of the whole bank arrives from its far side; a uniform march of the same step count resolves neither end. The elevation floor is what makes sunrise shadowing stretch sideways instead of lighting the entire bank from within. |
| **zenith** | `CLOUD_SKY_STEPS = 2` steps straight up; analytic on the cheap tier | the deck's own ambient occlusion — how much sky a sample can see. Broad and low-frequency, so two steps are enough. |
| **ground** | analytic from the sample's height and density | sunlight bounced off the lit surface back up into the cloud's base (`CLOUD_GROUND_ALBEDO = 0.22`, Earth's standard neutral value). Soft by nature; marching down for every sample is not affordable and the trend is all that matters. |

Probes sample `CLOUD_DETAIL_SHAPE` — the coverage-times-profile field with erosion replaced by its
**expected value** (a billow octave averages 0.5, and the Worley octave's remap is fitted to average
0.5 — §4.5). That keeps a probe unbiased about how much cloud is
between the sample and the light without paying for the octave, whereas skipping erosion entirely would
make every probe read the deck as denser than it is.

### 5.4 Multi-scattering expansion

`CLOUD_MULTI_SCATTER_OCTAVES = 6` (3 on the cheap tier). Each pass is one **bounce order**: order 0 is
single scattering, order N has been scattered N more times inside the bank before leaving. Rather than
tracing those paths, the same three light terms are re-evaluated with the coefficients scaled by
`k = 0.5^N` — scattering and extinction both shrink (a photon deep in the bank is less affected by the
cloud still in front of it) and the phase relaxes toward `1/4π` by the same k (each bounce randomises the
direction a little more). The geometric series converges, costs no extra march, and is what puts a bright
soft interior, a lit crown and a dark-but-not-black base into the deck.

Per order: `scatterAmt *= 0.5`, `extinctAmt *= 0.4`, `phaseG *= 0.8`, `powder = lerp(powder, √powder, 0.5)`
— the relaxation schedule the octave model was published with.

### 5.5 Powder

`cloudPowder(d) = 1 − e^{−4d}` applied at `CLOUD_POWDER_STRENGTH = 0.7`: ~0 at a thin edge, ~1 in a dense
interior. A single-scattering model brightens a wispy edge as readily as the core; real cloud does the
opposite, because a thin edge transmits its light onward instead of scattering it back, which is what
gives a backlit deck dark, crisp fringes. It relaxes toward 1 as the orders pile up (deep in the bank,
edge darkening no longer applies) and lets go toward the light at `CLOUD_POWDER_SUN_RELAX = 0.8` — at a
backlit edge what reaches the eye is the forward peak, not absorption, so powder that survives there eats
the silver lining it exists to frame.

### 5.6 Calibration

`push.lightRadiance` is irradiance-like: surface NEE is `brdf · lightRadiance · ndl` with
`brdf = albedo/π`. So the correct source term for a directional light is `albedo · E · phase(cosT)` and
for isotropic sky radiance simply `L` — the units need no fudge factor. What is left to calibrate is the
deck's brightness, and the real sky answers it: an optically thick, conservative water cloud reflects
~0.75 of the irradiance reaching it spread over the hemisphere, so a sunlit cloud top has a radiance of
about `0.75/π ≈ 0.24 · E` — the same as a white surface facing the sun, which is why clouds and sunlit
snow look equally bright. Summing this expansion for a full-depth sample gives ~0.29 · E before the gain,
so **`CLOUD_SCATTER_GAIN = 0.85`** lands the deck on that number. The single-scattering model it replaced
produced ~0.03 · E, eight times too dim — the measurable reason its interiors read as grey cotton.

### 5.7 Aerial perspective

`CLOUD_AERIAL_STRENGTH = 0.6` blends the accumulated scatter toward `skyBehind · (1 − transmittance)`
with distance. The air between the eye and the deck dims the deck's own scatter and puts sky radiance in
its place, which is why distant clouds lose contrast and take on the horizon's colour instead of simply
vanishing. It ramps over the same range as the density fade, so the view-limit cutoff is hidden by cloud
dissolving *into* the sky rather than by cloud being deleted at a line.

## 6. Marching

* **Energy-conserving step.** For a homogeneous stride the exact integral is
  `S · (σ_s/σ_t) · (1 − e^{−τ})` — the single-scattering albedo times the light the step *absorbed*,
  independent of stride length. Accumulating `S · (1 − T)` without the albedo ratio instead makes
  brightness a property of the march resolution, so raising the step count brightens the deck and a
  coarse step through thin cloud disagrees with a fine one through thick cloud. The previous
  fixed-step-count march banded for exactly this reason.
* **Dither.** `cloudDither` hashes `DispatchRaysIndex().xy` with `push.frameIndex` and offsets the march
  *start*. A fixed sample pattern puts truncation error at a fixed place (bands across the deck, rings at
  its edge, a step in every shadow terminator); moving it per pixel and per frame turns that into
  high-frequency noise the temporal denoiser resolves. Pixel-only dither freezes into static, frame-only
  dither bands across the screen — both halves are needed. The probe strides are jittered from the same
  value.
* **Early exit** at `CLOUD_MIN_TRANSMITTANCE = 0.02`: past that the deck is opaque, nothing behind it can
  show through, and every remaining sample is the most expensive thing in the loop.
* **Distance LOD.** The fine erosion octave fades out between `CLOUD_DETAIL_LOD_NEAR = 320` and
  `FAR = 1400` blocks. A 6-block lobe is sub-pixel past that, and the atmosphere has already washed the
  contrast out of it, so the hashes buy nothing.
* **Two tiers.** `highQuality` (camera rays and specular/mirror bounces) gets 24–48 steps, 6-order
  expansion, 6 sun strides, 2 sky steps and full erosion. Diffuse indirect gets 6–12 steps, 3 orders, 2
  sun strides, an analytic sky probe and coarse-only erosion: those bounces contribute a broad sky-fill
  term that is averaged over the hemisphere and denoised anyway, and both tiers keep the same extinction
  and phase so the *energy* stays right.
* **Preserved from before**, because they fix reported bugs and are still needed: the crossing exclusion
  (`crossFade`, which stops a bright band tracking the camera at the deck plane), the
  `CLOUD_MAX_SLAB_CROSSINGS = 3.5` cap on grazing horizon rays (which stops the horizon going solid
  white), the horizon distance fade, the step count scaling to the marched distance, and the opacity
  slider applied **once** to the finished march as a genuine ceiling rather than to extinction.

## 7. Invariants that must not break

1. **Periodicity.** Every octave divisor is a power of two and `CLOUD_FIELD_PERIOD_BLOCKS = 24576` is an
   integer multiple of every octave's own repeat (24576, 24576, 12288, 3072). The anchor wrap is only
   seamless if that holds in *every* space the hash is sampled in; two of the historical breaks were
   divisors of 0.9 and 0.35, whose repeats are not whole numbers of periods at any wrap distance. The
   vertical axis has no anchor to wrap, but `CLOUD_VERTICAL_CELLS` gives it a 1536-block repeat — over
   four times the deepest deck — so the erosion cannot tile visibly inside one cloud.
   `RtCloudPeriodMirrorTest` re-derives all of it from both files.
2. **The deck and its shadow read one coverage function** (§4.1).
3. **Vertical coordinates are deck-relative**, never camera-relative (§4.5).
4. **This module imports `world_common` and nothing else.** `world.rmiss` must not pull in `world_core`
   (which declares the raygen bindings), so every entry point takes the `WorldPush` explicitly. That is
   also why the dither hashes the pixel index itself instead of using `math.slang`'s PCG stream — `math`
   imports `world_core` — and why the 3D noise is written here rather than shared. It does mean the
   module reads `DispatchRaysIndex()`, so it may only be imported by ray-tracing stages, which every
   current importer (`world.rgen`, `world.rmiss`, `fog`) is.
5. **The classic style keeps its flat vanilla face shading** and stays out of the storm-absorption and
   aerial-perspective terms.

## 8. Cost

A full-quality step is one density evaluation (~40 hash lookups: 12 for the coverage octaves, 12 for the
shear displacement, 8 per 3D erosion octave) plus a 6-stride sun probe plus two sky-probe steps, each
probe sample being a shape-level density (~32 lookups). That is roughly **twice the previous model per
pixel**, and it is the price of the look — texture-based cloud passes are heavier still, and they buy
that budget back by sampling precomputed 3D noise instead of hashing it, which this module cannot do
(§7.4).

What keeps it affordable, in order of how much they save: the cheap tier on every diffuse bounce; the
`density <= 0` skip, which avoids all three probes in empty air (most of a scattered deck); the
transmittance early exit; the distance LOD dropping the fine octave; and shape-level probes that cost
half a full density each.

## 9. Tuning guide

| artefact | knob |
| --- | --- |
| whole deck too bright/dim | `CLOUD_SCATTER_GAIN` (§5.6 — calibrated, move it last) |
| interiors grey/black again | `CLOUD_MULTI_SCATTER_OCTAVES`, `CLOUD_MULTI_SCATTER_FALLOFF` |
| no silver lining on backlit edges | `CLOUD_HG_SILVER`, `CLOUD_PHASE_SILVER`, then `CLOUD_POWDER_SUN_RELAX` |
| clouds see-through / cotton-wool | `CLOUD_EXTINCTION` (optical depth per block; `CLOUD_REFERENCE_THICKNESS` normalises it by slab depth) |
| deck too shallow / too deep for the genus | `CLOUD_DECK_DEPTH_HEAP/SHEET/TOWER` (§4.2) |
| every cloud the same size | `CLOUD_COVERAGE_CLUSTER` (§4.1) |
| every cloud the same height | vigour stretch (§4.3), then `CLOUD_TOWER_COVERAGE_LO/HI` |
| lobes too small / too big | `CLOUD_BILLOW_DIV_COARSE`, `CLOUD_BILLOW_DIV_FINE` (power of two only!) |
| crown reads as soft cotton wool, not aerated cauliflower | `CLOUD_DETAIL_FINE_WEIGHT`, `CLOUD_BILLOW_DIV_FINE` |
| cellular scoops too soft / too jagged | `CLOUD_WORLEY_JITTER` (must stay < 1.0 — §4.5), then re-fit the remap mean |
| detail missing up close | `CLOUD_DETAIL_LOD_NEAR`, `CLOUD_DETAIL_LOD_FAR` (the LOD, not the field) |
| clouds too narrow / too wide | `CLOUD_SHAPE_DIV` (power of two only — see §7.1) |
| edges too soft / too crisp | `CLOUD_EDGE_SHARPEN_BASE`, `CLOUD_EDGE_SHARPEN_CROWN` |
| crowns not breaking up | `CLOUD_EROSION_CROWN`, `CLOUD_WARP_SHEAR` |
| sky is one connected wash, no clean air between clouds | the contrast pass in `cloudVolumetricCoverage` |
| tops sliced flat by the slab ceiling | `CLOUD_CROWN_ROUNDING` / the `crownEnd` clamp (§4.3) |
| every cloud the same height | `CLOUD_TOWER_COVERAGE_LO/HI` (the lift must stay nonlinear) |
| fair weather looks like a storm | `CLOUD_CONVECTION_PEAK` |
| storm sky not different enough | `CLOUD_SHEET_COVERAGE_LO/HI`, `CLOUD_STORM_ABSORPTION` |
| banding | dither (§6) — check both halves of the seed are still there |
| horizon wall of white | `CLOUD_MAX_SLAB_CROSSINGS` |

## 10. Not done

* **No 3D detail texture.** Both erosion octaves are generated procedurally — billow value noise and an
  exact Worley F1 (§4.5) — where the industry standard samples a precomputed Perlin-Worley shape atlas
  plus a Worley detail atlas. The atlases would still win on quality *and* on cost (one trilinear fetch
  instead of 27 hashes per sample), but they need a texture binding this module deliberately does not
  have (§7.4) and an asset pipeline to produce them.
* **No curl noise** — approximated by shearing a scalar field (§4.4).
* **One deck.** No second high-altitude layer, so no cirrus; the README's TODO still carries that.
* **No temporal reprojection** of the march itself: the dither plus the existing denoiser chain carry it,
  but a reprojected half-resolution cloud buffer is what the heavyweight packs do to afford 100+ steps.
* **Shadow softening** for the deck's shadow on the ground is still the analytic `cloudSunShadow` query.
