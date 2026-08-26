# ReSTIR / ReSTCV direct-light stability

Caustica's block-emitter next-event estimator has three live-selectable modes:

1. **Independent RIS** — ReSTIR History off. Every eligible vertex draws a fresh reservoir.
2. **Legacy ReSTIR** — ReSTIR History on and ReSTCV off. The first stable screen-space receiver merges validated temporal and spatial reservoirs.
3. **ReSTCV** — both switches on. The same ReSTIR reservoir is resolved with a compact spatio-temporal control variate.

The dedicated **RT Lighting → ReSTIR / ReSTCV Settings...** screen exposes candidate budgets, reuse gates, spatial radius, `M` caps, maximum age, geometry and Jacobian validation, common firefly bounds, and ReSTCV history controls.

## Stability contract

The maximum reservoir weight and final contribution-luminance bound apply to **all three modes** before direct-light radiance reaches DLSS/SVGF history. This is intentional: turning ReSTIR off must not restore the rare unbounded independent-RIS samples that appeared as static block-light flashes.

Spatial ReSTIR uses a random disk pattern hashed per pixel, but the pattern no longer rotates with the frame index. A static scene therefore does not receive a permanently moving set of neighbour candidates. Temporal and spatial history still has to pass camera-relative position, normal, light-generation, age, and connection-Jacobian gates.

## Compact ReSTCV adaptation

The implementation is informed by:

- [DQLin/ReSTIR_PT](https://github.com/DQLin/ReSTIR_PT)
- [Hercier/ReSTCV](https://github.com/Hercier/ReSTCV)
- [*Spatio-Temporal Control Variates with ReSTIR for Real-Time Rendering*](https://doi.org/10.1145/3799902.3811113)

Caustica uses a direct-illumination reservoir rather than the reference implementation's full path reservoir, so it stores an explicit 64-byte record per pixel:

- the existing representative light point, receiver geometry, `W`, `M`, age, generation, and normals;
- a packed positive-HDR RGB accumulated estimate;
- a packed positive-HDR RGB contribution of that record's representative sample;
- confidence and format metadata.

The RGB history is stored before the live block-emitter intensity multiplier, allowing intensity changes to scale history instead of invalidating or flashing it.

When a historical representative wins resampling, its estimate, representative contribution, confidence, and original `W` travel together. The existing final visibility ray produces the representative's current contribution at the final reservoir weight. Multiplying by `sourceW / finalW` reconstructs the same sample at its source weight, and the transfer is:

```text
transferred = source estimate
            + current representative at source W
            - source representative contribution
```

The transferred estimate is sanitized, bounded, and combined with the current ReSTIR estimate using capped confidence. If a fresh representative wins, a separately validated centre-history estimate receives only the configured conservative fallback weight. The resolved estimate and current representative are persisted **after** visibility. ReSTCV itself traces no additional shadow ray.

## Tuning guidance

- Lower **Maximum RIS Weight** or **Contribution Luminance Limit** first when isolated flashes remain. These controls also affect independent RIS.
- Raise **RIS Candidates** or **ReSTIR Fresh Candidates** for lower variance at a direct GPU cost.
- Raise temporal/spatial `M` caps or maximum reservoir `M` for stronger reuse, but keep the total bounded.
- Tighten position/normal/Jacobian gates when history crosses geometry edges.
- Lower **ReSTCV Strength**, **History Confidence**, or **Fresh-Winner Fallback** when lighting reacts too slowly.
- Lower **ReSTCV Outlier Clamp** when transferred estimates spike; raise it only if valid bright history is being clipped.
