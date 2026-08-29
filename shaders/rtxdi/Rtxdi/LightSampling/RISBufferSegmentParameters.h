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

#ifndef RTXDI_RIS_BUFFER_SEGMENT_PARAMETERS
#define RTXDI_RIS_BUFFER_SEGMENT_PARAMETERS

#include "../RtxdiTypes.h"

struct RTXDI_RISBufferSegmentParameters
{
    uint32_t bufferOffset;
    uint32_t tileSize;
    uint32_t tileCount;
    uint32_t pad1;
};

#endif // RTXDI_RIS_BUFFER_SEGMENT_PARAMETERS
