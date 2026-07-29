// Closest-hit shader. Geometry is per-section: InstanceID() indexes a section table (BDA array reached
// from the push constant) holding this section's {prim, uv} buffer addresses. Per-primitive
// {normal, tint} plus barycentric atlas UVs produce the payload guides; lighting is deferred to raygen.
//
// tableAddr/entityTableAddr are read from the inline push-constant lanes (pc), not through the
// WorldPush BDA struct: they're read on every single hit (the hottest chain in the frame), and going
// through worldPushAddr first would cost an extra global-memory load just to find the address of the
// load we actually want. The cold WorldPush struct is dereferenced only for the breaking overlay.
import world_common;
import math;

[[vk::push_constant]] WorldPushConstants pc;

[[vk::binding(2, 0)]] Sampler2D blockAlbedoAtlas;
// Independent bindless arrays: per-draw entity albedo slots and compact canonical material-page bundles.
[[vk::binding(0, 1)]] Sampler2D entityAlbedoTex[];
[[vk::binding(1, 1)]] Sampler2D materialSurface0Tex[];
[[vk::binding(2, 1)]] Sampler2D materialNormalAoTex[];
[[vk::binding(3, 1)]] Sampler2D materialSurface1Tex[];

void payloadSetPacked(inout Payload payload, uint material, float roughness, float metalness,
        float emission, float sss, float ior, float transmission, uint emissionSource) {
    payload.flags = material | (emissionSource << PAYLOAD_EMISSION_SOURCE_SHIFT);
    payload.roughMetal = packHalf2(float2(roughness, metalness));
    payload.emissionSss = packHalf2(float2(emission, sss));
    payload.iorTransmission = packHalf2(float2(ior, transmission));
}

// Which side of a dielectric face this hit is on, shared by every hit path. Comes from the face
// orientation, so it is re-derived at each crossing instead of toggled (see PAYLOAD_DIELECTRIC_ENTERING).
void payloadSetDielectric(inout Payload payload, uint material, bool entering) {
    if (material != MATERIAL_WATER && material != MATERIAL_DIELECTRIC) return;
    if (entering) payload.flags |= PAYLOAD_DIELECTRIC_ENTERING;
}

uint materialEmissionSource(MaterialHeader header, float emission) {
    if (emission <= 0.0) return EMISSION_SOURCE_NONE;
    if ((header.features & MATERIAL_FEATURE_SPEC) != 0u) return EMISSION_SOURCE_LAB_PBR;
    if ((header.features & MATERIAL_FEATURE_HEURISTIC_EMISSION) != 0u) return EMISSION_SOURCE_HEURISTIC;
    return EMISSION_SOURCE_UNIFORM;
}

// Strength of the LabPBR _n ambient-occlusion (blue) applied to albedo. Kept mild because the path
// tracer already computes its own AO from sky-visibility rays (avoid double-darkening).
static const float NORMAL_AO_STRENGTH = 0.5;

static const float RAY_CONE_MIN_WIDTH = 1.0e-5;
static const float RAY_CONE_MIN_TEXEL_FOOTPRINT = 1.0e-4;
static const float RAY_CONE_MAX_LOD = 12.0;

float2 texSizePx(Sampler2D t) {
    uint w, h;
    t.GetDimensions(w, h);
    return float2(w, h);
}

float rayConeHitWidth(uint rayCone) {
    float2 cone = unpackHalf2(rayCone);
    return max(cone.x + cone.y * max(RayTCurrent(), 0.0), RAY_CONE_MIN_WIDTH);
}

float edgeTexelsPerWorld(float3 p0, float3 p1, float2 uv0, float2 uv1, float2 textureSizePx) {
    float worldLen = length(p1 - p0);
    if (worldLen <= 1.0e-7) {
        return 0.0;
    }
    return length((uv1 - uv0) * textureSizePx) / worldLen;
}

float rayConeTextureLod(uint rayCone, float2 textureSizePx, float3 p0, float3 p1, float3 p2, float2 uv0, float2 uv1, float2 uv2) {
    float texelsPerWorld = max(edgeTexelsPerWorld(p0, p1, uv0, uv1, textureSizePx),
            max(edgeTexelsPerWorld(p1, p2, uv1, uv2, textureSizePx),
                edgeTexelsPerWorld(p2, p0, uv2, uv0, textureSizePx)));
    float footprint = max(rayConeHitWidth(rayCone) * texelsPerWorld, RAY_CONE_MIN_TEXEL_FOOTPRINT);
    return clamp(log2(footprint), 0.0, RAY_CONE_MAX_LOD);
}

float rayConeUnitUvLod(uint rayCone, float2 textureSizePx) {
    float footprint = max(rayConeHitWidth(rayCone) * max(textureSizePx.x, textureSizePx.y), RAY_CONE_MIN_TEXEL_FOOTPRINT);
    return clamp(log2(footprint), 0.0, RAY_CONE_MAX_LOD);
}

// Canonical material pages use a compact page index shared by their three dedicated arrays.
float4 samplePageSurface0(uint page, float2 uv, float lod) {
    return materialSurface0Tex[NonUniformResourceIndex(page)].SampleLevel(uv, lod);
}
float4 samplePageSurface1(uint page, float2 uv, float lod) {
    return materialSurface1Tex[NonUniformResourceIndex(page)].SampleLevel(uv, lod);
}
float4 samplePageNormalAo(uint page, float2 uv, float lod) {
    return materialNormalAoTex[NonUniformResourceIndex(page)].SampleLevel(uv, lod);
}

// Shared tangent-space basis, built from the hit triangle's vertex positions
// (VK_KHR_ray_tracing_position_fetch) + UVs. `n` must already be oriented toward the viewer. Used by
// both the LabPBR _n decode below (perturbNormal) and the Parallax Occlusion Mapping UV march
// (parallaxOffsetLocalUv), so the two effects agree on the same tangent frame for a given hit. Returns
// false on a degenerate UV triangle, in which case T/B are left zeroed and the caller should fall back
// to unperturbed shading. Instance transforms are translation-only, so object edges equal world edges.
bool computeTangentBasis(float3 n, float3 p0, float3 p1, float3 p2, float2 t0, float2 t1, float2 t2,
        out float3 T, out float3 B) {
    float2 g1 = t1 - t0;
    float2 g2 = t2 - t0;
    float det = g1.x * g2.y - g1.y * g2.x;
    if (abs(det) <= 1.0e-12) {
        T = float3(0.0, 0.0, 0.0);
        B = float3(0.0, 0.0, 0.0);
        return false;
    }
    float r = 1.0 / det;
    float3 traw = ((p1 - p0) * g2.y - (p2 - p0) * g1.y) * r;
    T = normalize(traw - n * dot(n, traw));       // Gram-Schmidt against the viewer-oriented normal
    B = cross(n, T) * (det < 0.0 ? -1.0 : 1.0);   // handedness from the UV winding
    return true;
}

// LabPBR _n decode: rotate the tangent-space normal into world space via computeTangentBasis. `n` must
// already be oriented toward the viewer (`vdir`). Clamps the result above the horizon so grazing
// perturbations don't invert it through the surface (the black-spot fix). Returns AO (blue) via `ao`;
// falls back to `n` on a degenerate UV triangle.
float3 perturbNormal(float3 n, float3 p0, float3 p1, float3 p2, float2 t0, float2 t1, float2 t2, float3 vdir, float4 ntex, out float ao) {
    ao = 1.0;
    float3 T, B;
    if (!computeTangentBasis(n, p0, p1, p2, t0, t1, t2, T, B)) {
        return n;
    }
    float2 nxy = ntex.xy * 2.0 - 1.0;                    // R,G = tangent-space X,Y
    float nz = sqrt(max(0.0, 1.0 - dot(nxy, nxy)));      // reconstruct Z
    float3 nm = normalize(nxy.x * T + nxy.y * B + nz * n);
    float NoV = dot(nm, vdir);
    if (NoV < 0.02) {
        nm = normalize(nm + vdir * (0.02 - NoV));        // keep above the horizon (no flip)
    }
    ao = lerp(1.0, ntex.b, NORMAL_AO_STRENGTH);
    return nm;
}

// ---- Parallax Occlusion Mapping ----------------------------------------------------------------
// LabPBR's height channel (materialNormalAoTex's alpha) spans 0.0 (fully recessed, 25% of a block deep)
// .. 1.0 (at the surface, 0% recessed). POM_MAX_RELIEF is that 25%-of-a-block ceiling expressed in the
// SAME normalized sprite-local UV space evaluateMaterial already computes (one block face == [0,1] in
// both axes), so the march needs no world<->texel unit conversion. pomDepth (WorldPushConstants.pomDepth,
// the player's "POM Depth" slider, 0..1) linearly scales from no relief up to that full LabPBR ceiling;
// 0 collapses the march to a single, free iteration (see the early-out below).
static const float POM_MAX_RELIEF = 0.25;
static const int POM_MIN_LAYERS = 4;
static const int POM_MAX_LAYERS = 16;

float pomHeight(uint page, float2 localUv, float lod) {
    return samplePageNormalAo(page, localUv, lod).a;
}

// Ray-marches the sprite-local UV in the tangent-space view direction against the heightmap (steep
// parallax mapping with a final linear interpolation between the last two layers — Parallax Occlusion
// Mapping proper). Returns the offset UV to re-sample albedo/material channels at, so the surface reads
// as real relief instead of a flat decal, without any extra scene geometry.
float2 parallaxOffsetLocalUv(uint page, float4 materialUv, float2 localUv, float3 T, float3 B, float3 n,
        float3 vdir, float lod, float pomDepth) {
    float3 viewTs = normalize(float3(dot(vdir, T), dot(vdir, B), max(dot(vdir, n), 0.05)));
    // Grazing rays cross more UV distance per unit depth; more layers keep the visible step size (and
    // thus the layer-banding artifact) roughly constant across view angles.
    int layers = int(lerp(float(POM_MAX_LAYERS), float(POM_MIN_LAYERS), abs(viewTs.z)));
    float layerDepth = 1.0 / float(layers);
    // Total UV traversal for the full relief depth, LearnOpenGL-style: divide by view.z so grazing rays
    // walk further per step (they are covering the same depth over more surface distance).
    float2 fullTraversal = (viewTs.xy / viewTs.z) * (POM_MAX_RELIEF * pomDepth);
    float2 deltaUv = fullTraversal * layerDepth;

    float2 curUv = localUv;
    float curLayerDepth = 0.0;
    float curDepth = 1.0 - pomHeight(page, materialUv.xy + clamp(curUv, 0.0, 1.0) * materialUv.zw, lod);
    float2 prevUv = curUv;
    float prevDepth = curDepth;
    float prevLayerDepth = curLayerDepth;

    for (int i = 0; i < layers; i++) {
        if (curLayerDepth >= curDepth) {
            break;
        }
        prevUv = curUv;
        prevDepth = curDepth;
        prevLayerDepth = curLayerDepth;
        curUv -= deltaUv;
        curLayerDepth += layerDepth;
        curDepth = 1.0 - pomHeight(page, materialUv.xy + clamp(curUv, 0.0, 1.0) * materialUv.zw, lod);
    }

    float afterDepth = curDepth - curLayerDepth;
    float beforeDepth = prevDepth - prevLayerDepth;
    float weight = afterDepth / max(afterDepth - beforeDepth, 1.0e-5);
    return clamp(lerp(curUv, prevUv, weight), 0.0, 1.0);
}

// Entry point used at the hit-shader call sites. `atlasUv` is either the vanilla block-atlas UV
// (terrain) or the entity resource's own texture UV (dynamic entities) — both are mapped into
// sprite-local [0,1] space by header.albedoUv the same way evaluateMaterial does.
//
// SAFETY FALLBACK: materials without an authored LabPBR normal map (MATERIAL_FEATURE_NORMAL unset) have
// no real heightmap — their normalAo.a defaults to 0 (see RtBlockMaterials' neutral-fallback pixels),
// which would read as "maximally recessed" and produce a bogus, ugly displacement if ever sampled. This
// check is exactly what keeps such materials on the ordinary flat sampling path, matching the same
// feature-bit gate the normal map itself already uses a few lines below.
float2 applyParallax(MaterialHeader header, float2 atlasUv, float3 p0, float3 p1, float3 p2,
        float2 t0, float2 t1, float2 t2, float3 n, float3 vdir, float lod, float pomDepth) {
    if ((header.features & MATERIAL_FEATURE_NORMAL) == 0u || pomDepth <= 0.0) {
        return atlasUv;
    }
    float3 T, B;
    if (!computeTangentBasis(n, p0, p1, p2, t0, t1, t2, T, B)) {
        return atlasUv;
    }
    // Same max-valid-LOD clamp evaluateMaterial applies before sampling any material-page channel — the
    // page's mip chain stops at MATERIAL_MAX_LOD_MASK, so an unclamped `lod` from a distant/oblique hit
    // would sample past the last authored mip.
    float maxMaterialLod = float((header.features >> MATERIAL_MAX_LOD_SHIFT) & MATERIAL_MAX_LOD_MASK);
    float materialLod = min(lod, maxMaterialLod);
    float2 localUv = clamp((atlasUv - header.albedoUv.xy) * header.albedoUv.zw, float2(0.0, 0.0), float2(1.0, 1.0));
    float2 offsetLocalUv = parallaxOffsetLocalUv(header.texturePage, header.materialUv, localUv, T, B, n,
            vdir, materialLod, pomDepth);
    // Undo the localUv mapping: local = (atlas - uvMin) * invExtent, so atlas = uvMin + local / invExtent.
    return header.albedoUv.xy + offsetLocalUv / header.albedoUv.zw;
}

struct Surface {

    float3 normal;
    float3 f0;
    float roughness;
    float metalness;
    float emission;
    float sss;
    float ao;
};

// The sole terrain/entity material evaluation path. LabPBR categorical bytes have already been
// decoded on the CPU; every sample below is a continuously filterable physical channel with semantic mips.
Surface evaluateMaterial(MaterialHeader header, float2 atlasUv, float lod, float3 albedo,
        float3 geometricNormal, float3 p0, float3 p1, float3 p2,
        float2 uv0, float2 uv1, float2 uv2, float3 vdir,
        float fallbackRoughness, float fallbackMetalness, float fallbackEmission, bool allowSss) {
    Surface surface;
    surface.normal = geometricNormal;
    surface.roughness = fallbackRoughness;
    surface.metalness = fallbackMetalness;
    surface.f0 = lerp(float3(0.04, 0.04, 0.04), albedo, fallbackMetalness);
    surface.emission = fallbackEmission;
    surface.sss = 0.0;
    surface.ao = 1.0;

    float2 localUv = clamp((atlasUv - header.albedoUv.xy) * header.albedoUv.zw,
            float2(0.0, 0.0), float2(1.0, 1.0));
    float2 pageUv = header.materialUv.xy + localUv * header.materialUv.zw;
    float maxMaterialLod = float((header.features >> MATERIAL_MAX_LOD_SHIFT) & MATERIAL_MAX_LOD_MASK);
    float materialLod = min(lod, maxMaterialLod);
    uint page = header.texturePage;
    if ((header.features & (MATERIAL_FEATURE_SPEC | MATERIAL_FEATURE_HEURISTIC_EMISSION)) != 0u) {
        float4 surface0 = samplePageSurface0(page, pageUv, materialLod);
        if ((header.features & MATERIAL_FEATURE_SPEC) != 0u) {
            float4 surface1 = samplePageSurface1(page, pageUv, materialLod); // LabPBR F0
            surface.roughness = surface0.r;
            surface.metalness = surface0.g;
            surface.emission = surface0.b;
            surface.sss = allowSss ? surface0.a : 0.0;
            surface.f0 = surface1.rgb;
        } else {
            // Eligibility is compiled from block-state semantics; the primitive's exact light level
            // supplies strength, while the page supplies only the normalized spatial mask.
            surface.emission = surface0.b * fallbackEmission;
        }
    }
    // Final HDR emission strength (EMISSIVE_STRENGTH baseline * any JSON multiplier), baked in Java at
    // material-compile time and packed unconditionally — see MATERIAL_EMISSION_STRENGTH_SHIFT. 0 for
    // non-emissive materials, so this multiply is always safe (and a no-op) when nothing above ran.
    // Runtime global light scales are applied later in raygen so block and dynamic emitters can differ.
    float strength = float((header.features >> MATERIAL_EMISSION_STRENGTH_SHIFT)
            & MATERIAL_EMISSION_STRENGTH_MASK)
            * (MATERIAL_MAX_EMISSION_STRENGTH / float(MATERIAL_EMISSION_STRENGTH_MASK));
    if (strength <= 0.0 && fallbackEmission > 0.0) {
        strength = MATERIAL_DEFAULT_DYNAMIC_EMISSION_STRENGTH;
    }
    surface.emission *= strength;
    if ((header.features & MATERIAL_FEATURE_NORMAL) != 0u) {
        float4 normalAo = samplePageNormalAo(page, pageUv, materialLod);
        surface.normal = perturbNormal(geometricNormal, p0, p1, p2, uv0, uv1, uv2,
                vdir, normalAo, surface.ao);
    }
    return surface;
}

// Block-breaking overlay: shared by opaque terrain AND stained-glass/ice. Reconstructs the hit position
// in the same rebased space the breaking list was pushed in, nudges it into the solid block along
// -normal to get the block's integer coordinate, then decal-projects the local [0,1] position onto
// whichever axis pair the normal is most aligned with (same idea as vanilla's
// SheetedDecalTextureGenerator) and multiply-blends the matching destroy-stage crack texture in,
// mirroring vanilla's crumbling blend (DST_COLOR*SRC_COLOR, doubled).
float3 applyBreaking(float3 albedo, uint rayCone, float3 rayOrigin, float3 rayDir, float hitT, float3 n) {
    ConstPtr<WorldPush> pcRef = ConstPtr<WorldPush>(pc.worldPushAddr);
    uint breakCount = pcRef[0].breakCount;
    if (breakCount == 0u) {
        return albedo;
    }
    float3 hitPos = rayOrigin + rayDir * hitT;
    int3 blockPos = int3(floor(hitPos - n * 0.01));
    for (uint bi = 0u; bi < breakCount; ++bi) {
        int4 ps = pcRef[0].breaking[bi].posSlot;
        if (all(ps.xyz == blockPos)) {
            float3 local = hitPos - float3(blockPos);
            float3 an = abs(n);
            float2 decalUv = (an.x >= an.y && an.x >= an.z) ? local.zy
                           : (an.y >= an.z) ? local.xz
                           : local.xy;
            float decalLod = rayConeUnitUvLod(rayCone, texSizePx(entityAlbedoTex[NonUniformResourceIndex(ps.w)]));
            float3 crack = srgbToLinear(entityAlbedoTex[NonUniformResourceIndex(ps.w)].SampleLevel(decalUv, decalLod).rgb);
            return clamp(crack * albedo, 0.0, 1.0);
        }
    }
    return albedo;
}

[shader("closesthit")]
void main(inout Payload payload, in BuiltInTriangleIntersectionAttributes attr) {
    float2 attribs = attr.barycentrics;
    uint rayCone = payload.rayCone;

    // Particle billboard: same geom-table/UV/bindless-atlas path as entities. Albedo is atlas texel *
    // per-particle colour; raygen treats material 2 as a primary-visible diffuse receiver with no
    // emission or specular response. Reached only by the primary ray (instance mask 0x02). Cutout: rahit.
    if ((InstanceID() & PARTICLE_BIT) != 0u) {
        uint idx = InstanceID() & IDX_MASK;
        EntityGeom g = ConstPtr<EntityGeom>(pc.entityTableAddr)[idx];
        uint pid = PrimitiveIndex() + g.triBase[GeometryIndex()];
        Prim pr = ConstPtr<Prim>(g.primAddr)[pid];
        ConstPtr<uint> ib = ConstPtr<uint>(g.idxAddr);
        ConstPtr<float2> uvb = ConstPtr<float2>(g.uvAddr);
        uint p0 = ib[3u * pid + 0u];
        uint p1 = ib[3u * pid + 1u];
        uint p2 = ib[3u * pid + 2u];
        float3 pbary = float3(1.0 - attribs.x - attribs.y, attribs.x, attribs.y);
        float2 puv = pbary.x * uvb[p0] + pbary.y * uvb[p1] + pbary.z * uvb[p2];
        int pslot = int(pr.tint.w + 0.5);
        float3x3 o2w = (float3x3)ObjectToWorld3x4();
        float3 pp0 = mul(o2w, HitTriangleVertexPosition(0));
        float3 pp1 = mul(o2w, HitTriangleVertexPosition(1));
        float3 pp2 = mul(o2w, HitTriangleVertexPosition(2));
        float particleLod = rayConeTextureLod(rayCone, texSizePx(entityAlbedoTex[NonUniformResourceIndex(pslot)]),
                pp0, pp1, pp2, uvb[p0], uvb[p1], uvb[p2]);
        float3 pn = normalize(pr.normal.xyz);
        if (dot(pn, WorldRayDirection()) > 0.0) {
            pn = -pn;
        }
        payload.albedo = half3(srgbToLinear(entityAlbedoTex[NonUniformResourceIndex(pslot)].SampleLevel(puv, particleLod).rgb) * pr.tint.rgb);
        payload.normal = half3(pn);
        payload.hitT = RayTCurrent();
        // Per-particle motion vector: interpolate the captured per-vertex displacement (uniform across
        // the billboard's verts) with the same indices/barycentrics as the UV. dispAddr == 0 falls back
        // to rigidDisp, which particles write as zero.
        if (g.dispAddr != 0) {
            ConstPtr<float4> pd = ConstPtr<float4>(g.dispAddr);
            payload.motionPrev = half3(pbary.x * pd[p0].xyz + pbary.y * pd[p1].xyz + pbary.z * pd[p2].xyz);
        } else {
            payload.motionPrev = half3(g.rigidDisp.xyz);
        }
        payload.f0 = half3(0.0h, 0.0h, 0.0h);
        payloadSetPacked(payload, MATERIAL_PARTICLE, 1.0, 0.0, 0.0, 0.0,
                1.0, 0.0, EMISSION_SOURCE_NONE);
        return;
    }
    // Dynamic entities: instances with this custom-index flag bit carry real captured ModelPart
    // geometry; the low bits index the entity geometry table, not the section table.
    if ((InstanceID() & ENTITY_BIT) != 0u) {
        uint eidx = InstanceID() & ~ENTITY_BIT;
        EntityGeom g = ConstPtr<EntityGeom>(pc.entityTableAddr)[eidx];
        uint pid = PrimitiveIndex() + g.triBase[GeometryIndex()];
        Prim pr = ConstPtr<Prim>(g.primAddr)[pid];
        // Rigid-reuse instances (still / spinning entities re-referencing a cached BLAS) carry a real
        // rotation in the instance transform; per-frame-built entities are identity. The cached prim
        // normal (and the TBN source positions below) are object-space — rotate them into world space.
        // Identity/translation instances make this a no-op.
        float3x3 entityO2w = (float3x3)ObjectToWorld3x4();
        // Orient the geometric normal toward the viewer first (so the _n TBN is built in the right
        // hemisphere — same fix as terrain).
        float3 vdir = -WorldRayDirection();
        float3 n = normalize(mul(entityO2w, pr.normal.xyz));
        bool entering = dot(WorldRayDirection(), n) < 0.0;
        if (dot(n, vdir) < 0.0) {
            n = -n;
        }
        // Interpolate the captured entity-texture UV (same scheme as terrain) and sample the bindless
        // per-type texture; tint.rgb is the model colour multiplier (white for most, tinted for sheep/…).
        ConstPtr<uint> eidxBuf = ConstPtr<uint>(g.idxAddr);
        ConstPtr<float2> euv = ConstPtr<float2>(g.uvAddr);
        uint e0 = eidxBuf[3u * pid + 0u];
        uint e1 = eidxBuf[3u * pid + 1u];
        uint e2 = eidxBuf[3u * pid + 2u];
        float3 ebary = float3(1.0 - attribs.x - attribs.y, attribs.x, attribs.y);
        float2 euvCoord = ebary.x * euv[e0] + ebary.y * euv[e1] + ebary.z * euv[e2];
        int texSlot = int(pr.tint.w + 0.5);
        float3 ep0 = mul(entityO2w, HitTriangleVertexPosition(0));
        float3 ep1 = mul(entityO2w, HitTriangleVertexPosition(1));
        float3 ep2 = mul(entityO2w, HitTriangleVertexPosition(2));
        float entityLod = rayConeTextureLod(rayCone, texSizePx(entityAlbedoTex[NonUniformResourceIndex(texSlot)]),
                ep0, ep1, ep2, euv[e0], euv[e1], euv[e2]);
        MaterialHeader header = ConstPtr<MaterialHeader>(pc.materialTableAddr)[pr.materialId];
        // Same parallax offset as terrain (see the opaque-terrain call site below for the full rationale):
        // entities with an authored LabPBR normal+height map (banners, some resource-pack chests, ...)
        // get real relief; everything else falls straight through to the flat euvCoord.
        euvCoord = applyParallax(header, euvCoord, ep0, ep1, ep2, euv[e0], euv[e1], euv[e2], n, vdir,
                entityLod, pc.pomDepth);
        float4 entityTexel = entityAlbedoTex[NonUniformResourceIndex(texSlot)].SampleLevel(euvCoord, entityLod);
        uint material = header.model;
        float3 baseAlbedo = srgbToLinear(entityTexel.rgb) * pr.tint.rgb;
        float3 albedo = material == MATERIAL_DIELECTRIC
                ? lerp(float3(1.0, 1.0, 1.0), baseAlbedo, entityTexel.a) : baseAlbedo;
        Surface surface = evaluateMaterial(header, euvCoord, entityLod, albedo, n,
                ep0, ep1, ep2, euv[e0], euv[e1], euv[e2], vdir,
                header.params.x, header.params.y, pr.normal.w, material == MATERIAL_OPAQUE);
        n = surface.normal;

        payload.albedo = half3(albedo * surface.ao);
        payload.normal = half3(n);
        payload.hitT = RayTCurrent();
        // Per-vertex motion vector: interpolate the captured per-vertex displacement with the same
        // indices/barycentrics used for the UV above. Rotation and skeletal/lid animation use a
        // per-vertex buffer; pure whole-object translation is packed into rigidDisp with no buffer.
        if (g.dispAddr != 0) {
            ConstPtr<float4> dd = ConstPtr<float4>(g.dispAddr);
            payload.motionPrev = half3(ebary.x * dd[e0].xyz + ebary.y * dd[e1].xyz + ebary.z * dd[e2].xyz);
        } else {
            payload.motionPrev = half3(g.rigidDisp.xyz);
        }
        payload.f0 = half3(surface.f0);
        float emission = material == MATERIAL_OPAQUE ? surface.emission : 0.0;
        float sss = material == MATERIAL_OPAQUE ? surface.sss : 0.0;
        payloadSetPacked(payload, material, surface.roughness, surface.metalness,
                emission, sss, header.params.z, header.params.w,
                materialEmissionSource(header, emission));
        payload.flags |= PAYLOAD_DYNAMIC_ENTITY;
        payloadSetDielectric(payload, material, entering);
        return;
    }

    Section sec = ConstPtr<Section>(pc.tableAddr)[InstanceID()];
    // Any-hit/SBT opt: the section BLAS has one fixed geometry per material bucket (solid / cutout /
    // translucent / water). PrimitiveIndex() restarts at 0 per geometry, so re-add this geometry's
    // triangle base to land in the section's packed prim/uv arrays (concatenated in BUCKET order).
    // Water prims keep tint.w == 1, converted to the packed material enum below.
    uint pid = PrimitiveIndex() + sec.triBase[GeometryIndex()];
    TerrainPrim pr = ConstPtr<TerrainPrim>(sec.primAddr)[pid];
    MaterialHeader materialHeader = ConstPtr<MaterialHeader>(pc.materialTableAddr)[pr.materialId];
    float3 n = normalize(pr.normal.xyz);
    float3 tint = pr.tint.rgb;

    // Water prims are single-sided, wound outward from the fluid volume (RtFluidMesher), so the
    // UNFLIPPED geometric normal is a reliable "which side of the dielectric" signal: a ray travelling
    // against it is entering the volume, one travelling with it is exiting. Captured before the
    // toward-viewer flip below and carried in the payload so raygen derives the medium from hit
    // orientation instead of toggling parity per crossing (a single missing/extra face no longer
    // desyncs the rest of the path).
    bool entering = dot(WorldRayDirection(), n) < 0.0;

    // Lever B: per-triangle corner UVs in primitive order. uvs[3*pid + k] is a contiguous,
    // directly-addressed load (no index buffer, no scattered vertex-UV gather), so it issues as soon as
    // pid is known and its latency overlaps the prim fetch instead of serialising behind an index load.
    // The index buffer still exists for the BLAS build; the shading path just no longer reads it.
    ConstPtr<float2> uvs = ConstPtr<float2>(sec.uvAddr);
    float2 uv0 = uvs[3u * pid + 0u];
    float2 uv1 = uvs[3u * pid + 1u];
    float2 uv2 = uvs[3u * pid + 2u];
    float3 bary = float3(1.0 - attribs.x - attribs.y, attribs.x, attribs.y);
    float2 uv = bary.x * uv0 + bary.y * uv1 + bary.z * uv2;
    float3 tp0 = HitTriangleVertexPosition(0);
    float3 tp1 = HitTriangleVertexPosition(1);
    float3 tp2 = HitTriangleVertexPosition(2);
    float blockLod = rayConeTextureLod(rayCone, texSizePx(blockAlbedoAtlas), tp0, tp1, tp2, uv0, uv1, uv2);

    // Orient the GEOMETRIC normal toward the viewer FIRST (double-sided geometry), so the normal-map TBN
    // is built in the correct hemisphere. Doing this before the map — rather than flipping the perturbed
    // normal afterward — is what avoids the grazing-angle black spots: a post-flip could invert a tipped
    // mapped normal through the surface and light the back face.
    float3 vdir = -WorldRayDirection(); // toward the viewer
    if (dot(n, vdir) < 0.0) {
        n = -n;
    }

    // Parallax Occlusion Mapping: offsets the sampled UV along the tangent-space view ray using the
    // LabPBR heightmap, so relief-mapped terrain (cobblestone mortar lines, brick courses, ...) reads as
    // real depth instead of a flat decal. Applied once, ahead of every texture read below (glass, water,
    // opaque), so the dielectric and opaque paths shade the SAME displaced surface point. Materials
    // without a normal map, and water (which never carries a block texture), fall straight through to
    // the original flat `uv` — see applyParallax's safety fallback.
    uv = applyParallax(materialHeader, uv, tp0, tp1, tp2, uv0, uv1, uv2, n, vdir, blockLod, pc.pomDepth);

    // Stained glass / ice: a thin colored filter resolved in raygen
    // (material 3). albedo carries the transmission tint = texel rgb mixed toward white by (1 − opacity),
    // so a more opaque texel tints transmitted light more strongly.
    if (materialHeader.model == MATERIAL_DIELECTRIC) {
        float4 gtex = blockAlbedoAtlas.SampleLevel(uv, blockLod);
        float3 gtexRgb = srgbToLinear(gtex.rgb);
        float3 glassAlbedo = lerp(float3(1.0, 1.0, 1.0), gtexRgb * tint, gtex.a);
        Surface glassSurface = evaluateMaterial(materialHeader, uv, blockLod, glassAlbedo, n,
                tp0, tp1, tp2, uv0, uv1, uv2, vdir,
                materialHeader.params.x, materialHeader.params.y, 0.0, false);
        n = glassSurface.normal;
        // Translucent blocks (glass, ice, …) are breakable too — apply the same overlay here, reusing
        // gtex (already sampled above) rather than re-fetching blockAlbedoAtlas.
        payload.albedo = half3(applyBreaking(glassAlbedo * glassSurface.ao,
                rayCone, WorldRayOrigin(), WorldRayDirection(), RayTCurrent(), n));
        payload.normal = half3(n);
        payload.hitT = RayTCurrent();
        payload.motionPrev = half3(0.0h, 0.0h, 0.0h);
        payload.f0 = half3(glassSurface.f0);
        payloadSetPacked(payload, MATERIAL_DIELECTRIC, glassSurface.roughness,
                glassSurface.metalness, 0.0, 0.0, materialHeader.params.z,
                materialHeader.params.w, EMISSION_SOURCE_NONE);
        payloadSetDielectric(payload, MATERIAL_DIELECTRIC, entering);
        return;
    }

    // Water (tint.w == 1) carries the pure biome water tint (no grey water-texture multiply): raygen
    // shades the surface as a clear dielectric and only needs the tint to derive the per-channel
    // Beer–Lambert absorption. Opaque terrain uses textured albedo.
    payload.albedo = half3(materialHeader.model == MATERIAL_WATER
            ? tint : srgbToLinear(blockAlbedoAtlas.SampleLevel(uv, blockLod).rgb) * tint);
    payload.hitT = RayTCurrent();
    payload.motionPrev = half3(0.0h, 0.0h, 0.0h); // static terrain: camera-only motion vector
    uint material = materialHeader.model == MATERIAL_WATER ? MATERIAL_WATER : MATERIAL_OPAQUE;

    // normal.w packs the 0..1 block-light level plus a +2 offset flag for non-SOLID (cutout /
    // translucent) render layers, set at extraction so the hit can opt SOLID terrain out of SSS below.
    float ew = pr.normal.w;
    bool nonSolid = ew >= 1.5;
    float emission = nonSolid ? ew - 2.0 : ew; // heuristic emission source (block light level)
    Surface surface = evaluateMaterial(materialHeader, uv, blockLod, float3(payload.albedo), n,
            tp0, tp1, tp2, uv0, uv1, uv2, vdir,
            materialHeader.params.x, materialHeader.params.y, emission, nonSolid);
    n = surface.normal;
    payload.albedo *= half(surface.ao);
    // Block-breaking overlay: opaque/cutout terrain (water skips — fluids aren't breakable). Evaluate
    // it after normal mapping so decal projection uses the same shading orientation as the old path.
    if (material != MATERIAL_WATER) {
        payload.albedo = half3(applyBreaking(float3(payload.albedo), rayCone, WorldRayOrigin(), WorldRayDirection(), RayTCurrent(), n));
    }
    payload.normal = half3(n);
    payload.f0 = half3(surface.f0);
    payloadSetPacked(payload, material, surface.roughness, surface.metalness,
            surface.emission, surface.sss, materialHeader.params.z, materialHeader.params.w,
            materialEmissionSource(materialHeader, surface.emission));
    payloadSetDielectric(payload, material, entering);
    // RIS emitter-NEE membership: raygen gates this emitter's direct-hit emission term (RIS covers it).
    if ((pr.flags & TERRAIN_PRIM_IN_LIGHT_BUFFER) != 0u) {
        payload.flags |= PAYLOAD_EMITTER_IN_LIST;
    }
}
