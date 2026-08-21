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
import portals;

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

// LabPBR _n decode (shared): rotate the tangent-space normal into world space via a TBN built from the
// hit triangle's vertex positions (VK_KHR_ray_tracing_position_fetch) + UVs. `n` must already be
// oriented toward the viewer (`vdir`). Clamps the result above the horizon so grazing perturbations
// don't invert it through the surface (the black-spot fix). Returns AO (blue) via `ao`; falls back to
// `n` on a degenerate UV triangle. Instance transforms are translation-only, so object edges equal
// world edges.
float3 perturbNormal(float3 n, float3 p0, float3 p1, float3 p2, float2 t0, float2 t1, float2 t2, float3 vdir, float4 ntex, out float ao) {
    ao = 1.0;
    float2 g1 = t1 - t0;
    float2 g2 = t2 - t0;
    float det = g1.x * g2.y - g1.y * g2.x;
    if (abs(det) <= 1.0e-12) {
        return n;
    }
    float r = 1.0 / det;
    float3 traw = ((p1 - p0) * g2.y - (p2 - p0) * g1.y) * r;
    float3 T = normalize(traw - n * dot(n, traw));       // Gram-Schmidt against the viewer-oriented normal
    float3 B = cross(n, T) * (det < 0.0 ? -1.0 : 1.0);   // handedness from the UV winding
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

struct Surface {
    float3 normal;
    float3 f0;
    float roughness;
    float metalness;
    float emission;
    float sss;
    float ao;
};

// Canonical material pages use a compact page index shared by their three dedicated arrays.
// When height-map smoothing is disabled (WORLD_FLAG_POM_SMOOTHING off), every LabPBR channel snaps to
// exact mip texel centres, so "off" is genuinely pixel-aligned rather than merely applying nearest
// filtering to the height while leaving the mapped normals smooth.
bool pomSmoothingEnabled() {
    return (ConstPtr<WorldPush>(pc.worldPushAddr)[0].flags & WORLD_FLAG_POM_SMOOTHING) != 0u;
}

float2 snapUvToTexelCentre(Sampler2D pageTex, float2 uv, inout float lod) {
    uint w, h;
    pageTex.GetDimensions(w, h);
    float mip = floor(lod);
    float2 size = max(float2(1.0, 1.0), floor(float2(w, h) / exp2(mip)));
    lod = mip;
    return (floor(uv * size) + 0.5) / size;
}

float4 samplePageSurface0(uint page, float2 uv, float lod) {
    Sampler2D pageTex = materialSurface0Tex[NonUniformResourceIndex(page)];
    if (!pomSmoothingEnabled()) uv = snapUvToTexelCentre(pageTex, uv, lod);
    return pageTex.SampleLevel(uv, lod);
}
float4 samplePageSurface1(uint page, float2 uv, float lod) {
    Sampler2D pageTex = materialSurface1Tex[NonUniformResourceIndex(page)];
    if (!pomSmoothingEnabled()) uv = snapUvToTexelCentre(pageTex, uv, lod);
    return pageTex.SampleLevel(uv, lod);
}
float4 samplePageNormalAo(uint page, float2 uv, float lod) {
    Sampler2D pageTex = materialNormalAoTex[NonUniformResourceIndex(page)];
    if (!pomSmoothingEnabled()) uv = snapUvToTexelCentre(pageTex, uv, lod);
    return pageTex.SampleLevel(uv, lod);
}

// LabPBR stores height in the alpha channel of the _n texture; it shares the normalAo page.
float samplePageHeight(uint page, float2 uv, float lod) {
    Sampler2D pageTex = materialNormalAoTex[NonUniformResourceIndex(page)];
    if (!pomSmoothingEnabled()) uv = snapUvToTexelCentre(pageTex, uv, lod);
    return pageTex.SampleLevel(uv, lod).a;
}

// Parallax Occlusion Mapping: trace a short view-space ray through the LabPBR height field and return
// a displaced albedo UV, plus an optional world-space wall normal.
//
// The march is still 2D layers (a per-texel voxel grid would blow the closest-hit budget). From above
// those layers read as relief; from the side they are a stack of cards — a straight square going into
// the face. The missing Z of each layer is a VERTICAL WALL: when the ray crosses a height cliff or
// would leave the sprite, we stop on that wall instead of sampling another horizontal slice (or
// aborting back to the flat quad). Geometry and BLASes stay untouched.
struct ParallaxHit {
    float2 uv;
    float3 wallNormal; // world-space, zero when the hit is a layer top (or POM is off)
};

ParallaxHit parallaxNone(float2 atlasUv) {
    ParallaxHit hit;
    hit.uv = atlasUv;
    hit.wallNormal = float3(0.0, 0.0, 0.0);
    return hit;
}

float pomMapDepth(MaterialHeader header, uint page, float2 localUv, float materialLod) {
    return 1.0 - samplePageHeight(page,
            header.materialUv.xy + localUv * header.materialUv.zw, materialLod);
}

float3 pomWallWorldNormal(float3 T, float3 B, float3 viewTs) {
    // Axis-aligned in tangent space so pixel-art cliffs read as box sides, not sheared ramps.
    float2 ts = viewTs.xy;
    if (dot(ts, ts) < 1.0e-8) {
        return float3(0.0, 0.0, 0.0);
    }
    float2 wallTs = abs(ts.x) >= abs(ts.y) ? float2(sign(ts.x), 0.0) : float2(0.0, sign(ts.y));
    return normalize(wallTs.x * T + wallTs.y * B);
}

float3 pomApplyWall(float3 n, float3 wallNormal, float3 vdir) {
    if (dot(wallNormal, wallNormal) <= 1.0e-8) {
        return n;
    }
    float3 wn = wallNormal;
    if (dot(wn, vdir) < 0.0) {
        wn = -wn;
    }
    float NoV = dot(wn, vdir);
    if (NoV < 0.02) {
        wn = normalize(wn + vdir * (0.02 - NoV));
    }
    return wn;
}

float2 pomSnapLocalUv(MaterialHeader header, uint page, float2 localUv, float materialLod) {
    Sampler2D pageTex = materialNormalAoTex[NonUniformResourceIndex(page)];
    uint w, h;
    pageTex.GetDimensions(w, h);
    float mip = floor(materialLod);
    float2 pageSize = max(float2(1.0, 1.0), floor(float2(w, h) / exp2(mip)));
    float2 localSize = max(float2(1.0, 1.0), pageSize * abs(header.materialUv.zw));
    return (floor(localUv * localSize) + 0.5) / localSize;
}

ParallaxHit parallaxUv(MaterialHeader header, float2 atlasUv, float lod, float3 geometricNormal,
        float3 p0, float3 p1, float3 p2, float2 uv0, float2 uv1, float2 uv2, float3 vdir) {
    if ((header.features & MATERIAL_FEATURE_NORMAL) == 0u) {
        return parallaxNone(atlasUv);
    }

    float2 g1 = uv1 - uv0;
    float2 g2 = uv2 - uv0;
    float det = g1.x * g2.y - g1.y * g2.x;
    if (abs(det) <= 1.0e-12) {
        return parallaxNone(atlasUv);
    }

    float3 n = geometricNormal;
    float r = 1.0 / det;
    float3 traw = ((p1 - p0) * g2.y - (p2 - p0) * g1.y) * r;
    float3 T = normalize(traw - n * dot(n, traw));
    float3 B = cross(n, T) * (det < 0.0 ? -1.0 : 1.0);
    float rawNoV = max(dot(vdir, n), 0.0);
    float3 viewTs = float3(dot(vdir, T), dot(vdir, B), max(rawNoV, 0.08));

    float2 localUv = clamp((atlasUv - header.albedoUv.xy) * header.albedoUv.zw,
            float2(0.0, 0.0), float2(1.0, 1.0));
    WorldPush worldPush = ConstPtr<WorldPush>(pc.worldPushAddr)[0];
    float4 parallaxParams = worldPush.parallaxParams;
    float maxDistance = max(parallaxParams.w, 1.0);
    float3 hitPosition = WorldRayOrigin() + WorldRayDirection() * RayTCurrent();
    float cameraDistance = length(hitPosition - worldPush.camOffset);
    float distanceFade = 1.0 - smoothstep(maxDistance * 0.8, maxDistance, cameraDistance);
    float maxMaterialLod = float((header.features >> MATERIAL_MAX_LOD_SHIFT) & MATERIAL_MAX_LOD_MASK);
    // Only suppress the singular near-horizontal case; a wider fade would override the distance slider.
    float grazingFade = smoothstep(0.002, 0.006, rawNoV);
    // No edge fade: flattening the relief at the sprite border is exactly the "straight square going
    // down" the wall path exists to hide. Rays that leave the sprite hit the border wall instead.
    float heightScale = parallaxParams.x * distanceFade * grazingFade;
    if (heightScale <= 1.0e-5) {
        return parallaxNone(atlasUv);
    }

    uint page = header.texturePage;
    bool smoothing = (worldPush.flags & WORLD_FLAG_POM_SMOOTHING) != 0u;
    float materialLod = min(smoothing ? lod + PARALLAX_SMOOTH_LOD_BIAS : floor(lod), maxMaterialLod);
    // A view-dependent rounded layer count changes abruptly during tiny camera rotations and makes
    // high-contrast height fields shimmer. A fixed configured count is temporally stable.
    int layerCount = clamp(int(round(parallaxParams.y)), 4, 32);
    float layerDepth = 1.0 / float(layerCount);
    float2 deltaUv = (viewTs.xy / viewTs.z) * (heightScale / float(layerCount));
    float2 currentUv = localUv;
    float currentDepth = 0.0;
    float sampledDepth = pomMapDepth(header, page, currentUv, materialLod);
    float3 wallNormal = float3(0.0, 0.0, 0.0);
    bool hitWall = false;

    [loop]
    for (int stepIndex = 0; stepIndex < 32 && currentDepth < sampledDepth; ++stepIndex) {
        float2 nextUv = currentUv - deltaUv;
        if (any(nextUv < float2(0.0, 0.0)) || any(nextUv > float2(1.0, 1.0))) {
            // Face-edge wall: the height field ends here, so the last layer gets a Z side rather than
            // stretching the last texel column or popping back to the undisplaced quad.
            currentUv = clamp(nextUv, float2(0.0, 0.0), float2(1.0, 1.0));
            wallNormal = pomWallWorldNormal(T, B, viewTs);
            hitWall = true;
            break;
        }
        float nextDepth = currentDepth + layerDepth;
        float nextSampled = pomMapDepth(header, page, nextUv, materialLod);
        // Cliff wall: the ray is still between the two columns' surface depths, so it struck the
        // vertical face connecting them — the Z of the 2D layer — not another horizontal card.
        float lo = min(sampledDepth, nextSampled);
        float hi = max(sampledDepth, nextSampled);
        if ((hi - lo) > layerDepth * 0.65 && nextDepth > lo && currentDepth < hi) {
            // Texture the wall with the taller column (shallower surface depth).
            currentUv = nextSampled <= sampledDepth ? nextUv : currentUv;
            if (!smoothing) {
                currentUv = pomSnapLocalUv(header, page, currentUv, materialLod);
            }
            wallNormal = pomWallWorldNormal(T, B, viewTs);
            hitWall = true;
            break;
        }
        currentUv = nextUv;
        currentDepth = nextDepth;
        sampledDepth = nextSampled;
    }

    // Smooth mode refines a TOP-face crossing only. Pixel mode keeps the discrete layer hit so it
    // cannot reintroduce interpolated/rounded relief after the user disabled smoothing. Walls stay
    // sharp in both modes — interpolating them would put the cardboard slope back.
    float2 displacedLocalUv = currentUv;
    if (!hitWall && smoothing) {
        float2 frontUv = currentUv + deltaUv;
        float frontDepth = max(0.0, currentDepth - layerDepth);
        float2 backUv = currentUv;
        float backDepth = currentDepth;
        [unroll]
        for (int refine = 0; refine < 4; ++refine) {
            float2 midUv = (frontUv + backUv) * 0.5;
            float midDepth = (frontDepth + backDepth) * 0.5;
            float mapDepth = pomMapDepth(header, page, midUv, materialLod);
            if (midDepth < mapDepth) {
                frontUv = midUv;
                frontDepth = midDepth;
            } else {
                backUv = midUv;
                backDepth = midDepth;
            }
        }
        displacedLocalUv = (frontUv + backUv) * 0.5;
    }
    ParallaxHit hit;
    hit.uv = header.albedoUv.xy + displacedLocalUv / header.albedoUv.zw;
    hit.wallNormal = wallNormal;
    return hit;
}

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

// Distant Horizons / Voxy mini-material shading defaults. The coarse VBO retains only a one-byte
// material class, so these map that class onto plausible PBR parameters.
float dhMaterialRoughness(uint material, float fallbackRoughness) {
    if (material == DH_MATERIAL_METAL) return 0.28;
    if (material == DH_MATERIAL_SNOW) return 0.38;
    if (material == DH_MATERIAL_WOOD) return 0.72;
    if (material == DH_MATERIAL_STONE) return 0.78;
    if (material == DH_MATERIAL_DEEPSLATE) return 0.84;
    if (material == DH_MATERIAL_TERRACOTTA) return 0.76;
    if (material == DH_MATERIAL_LEAVES) return 0.84;
    if (material == DH_MATERIAL_GRASS) return 0.92;
    if (material == DH_MATERIAL_DIRT) return 0.96;
    if (material == DH_MATERIAL_SAND) return 0.98;
    if (material == DH_MATERIAL_NETHER_STONE) return 0.88;
    if (material == DH_MATERIAL_LAVA) return 0.68;
    if (material == DH_MATERIAL_ILLUMINATED) return clamp(fallbackRoughness, 0.18, 0.90);
    return clamp(fallbackRoughness, 0.25, 1.0);
}

float dhMaterialMetalness(uint material, float fallbackMetalness) {
    if (material == DH_MATERIAL_METAL) return 1.0;
    if (material == DH_MATERIAL_ILLUMINATED) return clamp(fallbackMetalness, 0.0, 1.0);
    return 0.0;
}

float dhMaterialSss(uint material) {
    if (material == DH_MATERIAL_LEAVES) return 0.18;
    if (material == DH_MATERIAL_GRASS) return 0.055;
    if (material == DH_MATERIAL_SNOW) return 0.08;
    return 0.0;
}

[shader("closesthit")]
void main(inout Payload payload, in BuiltInTriangleIntersectionAttributes attr) {
    float2 attribs = attr.barycentrics;
    uint rayCone = payload.rayCone;

    // Native DH/Voxy LOD triangles participate in camera, GI, reflection and shadow rays through the
    // same TLAS. They carry no sprite: shading comes from vertex colour + the mini-material class.
    if ((InstanceID() & DH_INSTANCE_KIND) == DH_INSTANCE_KIND) {
        Section sec = ConstPtr<Section>(pc.dhTableAddr)[InstanceID() & IDX_MASK];
        uint dpid = PrimitiveIndex() + sec.triBase[GeometryIndex()];
        TerrainPrim dpr = ConstPtr<TerrainPrim>(sec.primAddr)[dpid];
        float3 sourceNormal = normalize(dpr.normal.xyz);
        float3 dn = sourceNormal;
        if (dot(dn, -WorldRayDirection()) < 0.0) dn = -dn;
        uint dhSurface = uint(dpr.tint.w + 0.5);
        uint dhMaterial = dpr.flags;
        bool dhWater = dhSurface == DH_SURFACE_WATER;
        bool dhGlass = dhSurface == DH_SURFACE_GLASS;
        bool dhEmissive = dhSurface == DH_SURFACE_EMISSIVE;
        bool dhEmissiveGlass = dhSurface == DH_SURFACE_EMISSIVE_GLASS;
        float dhEmission = (dhEmissive || dhEmissiveGlass) ? clamp(asfloat(dpr.aux0), 0.0, 4.0) : 0.0;
        MaterialHeader dhHeader = ConstPtr<MaterialHeader>(pc.materialTableAddr)[dpr.materialId];

        if (dhGlass || dhEmissiveGlass) {
            float opticalAlpha = clamp(asfloat(dhEmissiveGlass ? dpr.aux1 : dpr.aux0), 0.04, 0.80);
            float3 glassTint = glassTransmissionFilter(dpr.tint.rgb, opticalAlpha);
            float ior = max(dhHeader.params.z, 1.45);
            float f0Base = (ior - 1.0) / (ior + 1.0);
            float f0Scalar = f0Base * f0Base;
            payload.albedo = half3(glassTint);
            payload.normal = half3(dn);
            payload.hitT = RayTCurrent();
            payload.motionPrev = half3(0.0h, 0.0h, 0.0h);
            payload.f0 = half3(float3(f0Scalar, f0Scalar, f0Scalar));
            payloadSetPacked(payload, MATERIAL_DIELECTRIC,
                    clamp(dhHeader.params.x, 0.025, 0.16), 0.0, dhEmission, 0.0,
                    ior, max(dhHeader.params.w, 0.97),
                    dhEmissiveGlass ? EMISSION_SOURCE_UNIFORM : EMISSION_SOURCE_NONE);
            payloadSetDielectric(payload, MATERIAL_DIELECTRIC,
                    dot(WorldRayDirection(), sourceNormal) < 0.0);
            return;
        }

        if (dhWater) {
            // A coarse LOD voxel is a sparse surface approximation, not a watertight column: pushing a
            // real water medium here would accumulate Beer-Lambert absorption through generated
            // bottom/side faces and turn distant lakes into black sheets (the fork's voxy-compat bug).
            // Our unified dielectric raygen derives the medium from the payload, so the safe adaptation
            // is a glossy opaque water-tinted surface: correct colour and a plausible sun highlight at
            // horizon distances, with zero medium-stack interaction.
            payload.albedo = half3(dpr.tint.rgb);
            payload.normal = half3(dn);
            payload.hitT = RayTCurrent();
            payload.motionPrev = half3(0.0h, 0.0h, 0.0h);
            payload.f0 = half3(0.02h, 0.02h, 0.02h);
            payloadSetPacked(payload, MATERIAL_OPAQUE, 0.075, 0.0, 0.0, 0.0,
                    1.333, 0.0, EMISSION_SOURCE_NONE);
            return;
        }

        payload.albedo = half3(dpr.tint.rgb);
        payload.normal = half3(dn);
        payload.hitT = RayTCurrent();
        payload.motionPrev = half3(0.0h, 0.0h, 0.0h);
        float dhRoughness = dhMaterialRoughness(dhMaterial, dhHeader.params.x);
        float dhMetalness = dhMaterialMetalness(dhMaterial, dhHeader.params.y);
        float dhSss = dhMaterialSss(dhMaterial);
        payload.f0 = half3(lerp(float3(0.04, 0.04, 0.04), dpr.tint.rgb, dhMetalness));
        payloadSetPacked(payload, MATERIAL_OPAQUE, dhRoughness, dhMetalness, dhEmission, dhSss,
                max(dhHeader.params.z, 1.0), 0.0,
                dhEmissive ? EMISSION_SOURCE_UNIFORM : EMISSION_SOURCE_NONE);
        return;
    }

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
        // Rain/snow sheets are tagged at capture (RtWeatherCapture) and shaded unlit in raygen — the
        // path tracer's light response was visibly breaking them (see PRIM_WEATHER).
        if ((pr.flags & PRIM_WEATHER) != 0u) {
            payload.flags |= PAYLOAD_WEATHER;
        }
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
        uint material = header.model;
        // Portal surfaces captured through the entity/block-entity path (EndPortalRenderer's quad, or a
        // held/displayed nether portal block): the same dedicated procedural shading as terrain portals,
        // so the flat end_portal texture never shows. The collector stamps TERRAIN_PRIM_PORTAL_* into
        // the entity prim's flags lane and forces the opaque bucket.
        if ((pr.flags & (TERRAIN_PRIM_PORTAL_NETHER | TERRAIN_PRIM_PORTAL_END)) != 0u) {
            WorldPush worldPush = ConstPtr<WorldPush>(pc.worldPushAddr)[0];
            float portalTime = worldPush.waterParams.w; // per-frame animation clock (seconds, wrapped)
            float3 portalColor;
            float portalEmission;
            if ((pr.flags & TERRAIN_PRIM_PORTAL_END) != 0u) {
                float3 abyss = endPortalAbyss(WorldRayDirection(), portalTime);
                portalColor = abyss * END_PORTAL_BRIGHTNESS;
                portalEmission = luminance(abyss) * END_PORTAL_EMISSION;
            } else {
                // Nether swirl on entity-held portal blocks: same in-sprite scroll as terrain.
                float2 localUv = (euvCoord - header.albedoUv.xy) * header.albedoUv.zw;
                float2 scrolled = frac(localUv + float2(portalTime * NETHER_PORTAL_SCROLL_U,
                        portalTime * NETHER_PORTAL_SCROLL_V));
                float2 swirlUv = header.albedoUv.xy + scrolled / header.albedoUv.zw;
                float4 swirlTexel = entityAlbedoTex[NonUniformResourceIndex(texSlot)].SampleLevel(swirlUv, 0.0);
                float3 swirl = srgbToLinear(swirlTexel.rgb) * pr.tint.rgb * (0.35 + 0.65 * swirlTexel.a);
                portalColor = swirl;
                portalEmission = luminance(swirl) * NETHER_PORTAL_EMISSION;
            }
            payload.albedo = half3(portalColor);
            payload.normal = half3(n);
            payload.hitT = RayTCurrent();
            payload.motionPrev = half3(0.0h, 0.0h, 0.0h);
            payload.f0 = half3(0.04h, 0.04h, 0.04h);
            payloadSetPacked(payload, MATERIAL_OPAQUE, 0.6, 0.0, portalEmission, 0.0,
                    1.0, 0.0, EMISSION_SOURCE_UNIFORM);
            payloadSetDielectric(payload, MATERIAL_OPAQUE, entering);
            return;
        }
        // POM on the opaque entity BLAS geometry only; cutout/translucent entities keep the exact UV
        // whose alpha the any-hit shader already validated (block-entity models like chests are opaque).
        float3 entityPomWall = float3(0.0, 0.0, 0.0);
        if (GeometryIndex() == 0u && material == MATERIAL_OPAQUE) {
            ParallaxHit pom = parallaxUv(header, euvCoord, entityLod, n, ep0, ep1, ep2,
                    euv[e0], euv[e1], euv[e2], vdir);
            euvCoord = pom.uv;
            entityPomWall = pom.wallNormal;
        }
        float4 entityTexel = entityAlbedoTex[NonUniformResourceIndex(texSlot)].SampleLevel(euvCoord, entityLod);
        float3 baseAlbedo = srgbToLinear(entityTexel.rgb) * pr.tint.rgb;
        float3 albedo = material == MATERIAL_DIELECTRIC
                ? lerp(float3(1.0, 1.0, 1.0), baseAlbedo, entityTexel.a) : baseAlbedo;
        Surface surface = evaluateMaterial(header, euvCoord, entityLod, albedo, n,
                ep0, ep1, ep2, euv[e0], euv[e1], euv[e2], vdir,
                header.params.x, header.params.y, pr.normal.w, material == MATERIAL_OPAQUE);
        n = pomApplyWall(surface.normal, entityPomWall, vdir);

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

    // Parallax Occlusion Mapping: restrict relief to the opaque geometry bucket so leaves, plants,
    // grass overlays and translucent blocks cannot shade a different texel than the one that
    // established their any-hit coverage.
    float3 pomWall = float3(0.0, 0.0, 0.0);
    if (GeometryIndex() == BUCKET_SOLID && materialHeader.model == MATERIAL_OPAQUE) {
        ParallaxHit pom = parallaxUv(materialHeader, uv, blockLod, n, tp0, tp1, tp2, uv0, uv1, uv2, vdir);
        uv = pom.uv;
        pomWall = pom.wallNormal;
    }

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

    // ---- Portals. RtTerrainMesher routes the nether/end portal sprites into the SOLID bucket and
    // tags their prims (TERRAIN_PRIM_PORTAL_*), so they never take the glass-dielectric path above:
    // the Nether portal is a self-lit animated swirl, the End portal is the End sky's cosmic abyss
    // (deep void purple + starfield), view-parallax like vanilla's end-portal shader.
    uint terrainFlags = pr.flags;
    if ((terrainFlags & TERRAIN_PRIM_PORTAL_NETHER) != 0u) {
        WorldPush worldPush = ConstPtr<WorldPush>(pc.worldPushAddr)[0];
        float portalTime = worldPush.waterParams.w; // per-frame animation clock (seconds, wrapped)
        // Scroll inside the sprite's own rect (local 0..1, wrapped) so the drift can never bleed a
        // neighbouring atlas sprite in; the vanilla 32-frame atlas animation plays on top of it, so
        // the swirl is alive either way. LOD 0 keeps the swirl texels crisp at any distance.
        float2 localUv = (uv - materialHeader.albedoUv.xy) * materialHeader.albedoUv.zw;
        float2 scrolled = frac(localUv + float2(portalTime * NETHER_PORTAL_SCROLL_U,
                portalTime * NETHER_PORTAL_SCROLL_V));
        float2 swirlUv = materialHeader.albedoUv.xy + scrolled / materialHeader.albedoUv.zw;
        float4 swirlTexel = blockAlbedoAtlas.SampleLevel(swirlUv, 0.0);
        // Tint is the quad's authored colour (white for vanilla), never the glass lerp toward white.
        // The texture's own alpha darkens the gaps between the swirl arms instead of transmitting —
        // the portal is a surface, not a dielectric.
        float3 swirl = srgbToLinear(swirlTexel.rgb) * tint * (0.35 + 0.65 * swirlTexel.a);
        float swirlLum = luminance(swirl);
        payload.albedo = half3(swirl);
        payload.normal = half3(n);
        payload.hitT = RayTCurrent();
        payload.motionPrev = half3(0.0h, 0.0h, 0.0h);
        payload.f0 = half3(0.04h, 0.04h, 0.04h);
        payloadSetPacked(payload, MATERIAL_OPAQUE, 0.6, 0.0,
                swirlLum * NETHER_PORTAL_EMISSION, 0.0, 1.0, 0.0, EMISSION_SOURCE_UNIFORM);
        payloadSetDielectric(payload, MATERIAL_OPAQUE, entering);
        if ((terrainFlags & TERRAIN_PRIM_IN_LIGHT_BUFFER) != 0u) {
            payload.flags |= PAYLOAD_EMITTER_IN_LIST;
        }
        return;
    }
    if ((terrainFlags & TERRAIN_PRIM_PORTAL_END) != 0u) {
        WorldPush worldPush = ConstPtr<WorldPush>(pc.worldPushAddr)[0];
        float portalTime = worldPush.waterParams.w;
        float3 abyss = endPortalAbyss(WorldRayDirection(), portalTime);
        payload.albedo = half3(abyss * END_PORTAL_BRIGHTNESS);
        payload.normal = half3(n);
        payload.hitT = RayTCurrent();
        payload.motionPrev = half3(0.0h, 0.0h, 0.0h);
        payload.f0 = half3(0.04h, 0.04h, 0.04h);
        payloadSetPacked(payload, MATERIAL_OPAQUE, 0.9, 0.0,
                luminance(abyss) * END_PORTAL_EMISSION, 0.0, 1.0, 0.0, EMISSION_SOURCE_UNIFORM);
        payloadSetDielectric(payload, MATERIAL_OPAQUE, entering);
        if ((terrainFlags & TERRAIN_PRIM_IN_LIGHT_BUFFER) != 0u) {
            payload.flags |= PAYLOAD_EMITTER_IN_LIST;
        }
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
    n = pomApplyWall(surface.normal, pomWall, vdir);
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
