/*
 * SPDX-FileCopyrightText: Copyright (c) 2020-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
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

#ifndef RTXDI_UNIFORM_SAMPLING
#define RTXDI_UNIFORM_SAMPLING

void RTXDI_RandomlySelectLightUniformly(
    float rnd,
    RTXDI_LightBufferRegion region,
    out RAB_LightInfo lightInfo,
    out uint lightIndex,
    out float invSourcePdf)
{
    invSourcePdf = float(region.numLights);
    lightIndex = region.firstLightIndex + min(uint(floor(rnd * region.numLights)), region.numLights - 1);
    lightInfo = RAB_LoadLightInfo(lightIndex, false);
}

#endif // RTXDI_UNIFORM_SAMPLING
