/*
 * Copyright (C) 2026 guidao
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * This file is part of canvas-video.
 *
 * canvas-video is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * canvas-video is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with canvas-video.  If not, see <https://www.gnu.org/licenses/>.
 */

#include "scale.h"
#include <stddef.h>
#include <string.h>

void cv_scale(const uint32_t *src, int sw, int sh,
              uint32_t *dst, int dw, int dh)
{
    if (sw == dw && sh == dh) {
        memcpy(dst, src, (size_t)sw * sh * sizeof(*src));
        return;
    }
    /* Pixel-center mapping, clamped at the outermost source pixels.
       Precompute x coordinates once instead of dividing for every row. */
    int left[4096], right[4096], fraction[4096];
    for (int x = 0; x < dw; ++x) {
        int fixed = (int)((2 * x + 1) * (int64_t)sw * 128 / dw) - 128;
        if (fixed < 0) fixed = 0;
        if (fixed > (sw - 1) * 256) fixed = (sw - 1) * 256;
        left[x] = fixed / 256;
        right[x] = left[x] + (left[x] + 1 < sw);
        fraction[x] = fixed % 256;
    }
    for (int y = 0; y < dh; ++y) {
        int fixed = (int)((2 * y + 1) * (int64_t)sh * 128 / dh) - 128;
        if (fixed < 0) fixed = 0;
        if (fixed > (sh - 1) * 256) fixed = (sh - 1) * 256;
        int top = fixed / 256, bottom = top + (top + 1 < sh);
        unsigned fy = (unsigned)fixed % 256;
        const uint32_t *a = src + (size_t)top * sw;
        const uint32_t *b = src + (size_t)bottom * sw;
        for (int x = 0; x < dw; ++x) {
            unsigned fx = (unsigned)fraction[x];
            uint32_t pixel = 0;
            for (int shift = 0; shift < 32; shift += 8) {
                unsigned upper = ((a[left[x]] >> shift) & 255) * (256 - fx)
                               + ((a[right[x]] >> shift) & 255) * fx;
                unsigned lower = ((b[left[x]] >> shift) & 255) * (256 - fx)
                               + ((b[right[x]] >> shift) & 255) * fx;
                pixel |= ((upper * (256 - fy) + lower * fy + 32768) >> 16) << shift;
            }
            dst[(size_t)y * dw + x] = pixel;
        }
    }
}
