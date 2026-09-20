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

#ifndef CANVAS_VIDEO_SCALE_H
#define CANVAS_VIDEO_SCALE_H
#include <stdint.h>

/* Bilinear scaling of distinct, tightly packed ARGB32 buffers.
   All dimensions must be in [1, 4096]. */
void cv_scale(const uint32_t *source, int sw, int sh,
              uint32_t *destination, int dw, int dh);
#endif
