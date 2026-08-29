/*
 * SPDX-FileCopyrightText: Copyright (c) 2022-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
 * SPDX-License-Identifier: LicenseRef-NvidiaProprietary
 *
 * NVIDIA CORPORATION, its affiliates and licensors retain all intellectual
 * property and proprietary rights in and to this material, related
 * documentation and any modifications thereto. Any use, reproduction,
 * disclosure or distribution of this material and related documentation
 * without an express license agreement from NVIDIA CORPORATION or
 * its affiliates is strictly prohibited.
 */

// --- Caustica vendoring adaptation --------------------------------------------------
// This software contains source code provided by NVIDIA Corporation.
// Source: NVIDIA RTXDI SDK, https://github.com/NVIDIA-RTX/RTXDI (Libraries/Rtxdi,
// the RTXDI-Library submodule). Adaptations, and only adaptations, made for Caustica's
// Slang build are marked with `CAUSTICA:` comments. The algorithm code is unmodified.

#ifndef RTXDI_TYPES_H
#define RTXDI_TYPES_H

// CAUSTICA: also take the shader-side branch when compiled by Slang. Slang does not
// define __cplusplus for shader code, but being explicit keeps this correct under every
// front-end configuration instead of relying on that behavior.
#if !defined(__cplusplus) || defined(__SLANG__)
#ifndef uint32_t
#define uint32_t uint
#endif

#ifdef RTXDI_GLSL

// Macros to compile HLSL code as GLSL
#define int2 ivec2
#define int3 ivec3
#define uint2 uvec2
#define uint3 uvec3
#define float2 vec2
#define float3 vec3
#define float4 vec4
#define float3x3 mat3
#define static
#define atan2 atan
#define sincos(x,s,c) {s=sin(x);c=cos(x);}
#define saturate(x) clamp(x,0,1)
#define asuint floatBitsToUint
#define asfloat uintBitsToFloat
#define groupshared shared
#define WaveActiveSum subgroupAdd
#define WaveGetLaneCount() gl_SubgroupSize
#define WaveActiveCountBits(x) subgroupBallotBitCount(uvec4(x,0,0,0))
#define WaveIsFirstLane subgroupElect
#define GroupMemoryBarrierWithGroupSync barrier
#define f32tof16(f) packHalf2x16(vec2(f, 0))
#define f16tof32(u) unpackHalf2x16(u).x

#define RTXDI_TEX2D sampler2D
#define RTXDI_TEX2D_LOAD(t,pos,lod) texelFetch(t,pos,lod)
#define RTXDI_DEFAULT(value)

#else // RTXDI_GLSL

#define RTXDI_TEX2D Texture2D
#define RTXDI_TEX2D_LOAD(t,pos,lod) t.Load(int3(pos,lod))
#define RTXDI_DEFAULT(value) = value

#endif // RTXDI_GLSL

#endif // __cplusplus

#endif // RTXDI_TYPES_H