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

#ifndef CANVAS_VIDEO_PLAYER_H
#define CANVAS_VIDEO_PLAYER_H

#include <stddef.h>
#include <stdint.h>

typedef struct cv_player cv_player;

typedef struct {
    double position, duration, volume, speed;
    int paused, eof, idle;
    uint64_t frames;
    char error[256];
} cv_status;

/* All calls except the internal render callback run on the owner thread.
   The owner must not call destroy concurrently with any other operation. */
cv_player *cv_create(int width, int height, const char *audio_output,
                     char *error, size_t error_size);
void cv_destroy(cv_player *player);
int cv_command(cv_player *player, const char *const *arguments);
void cv_get_status(cv_player *player, cv_status *status);
/* Copy only a new frame; destination is tightly packed native ARGB32.
   Returns 1 for a copied frame, 0 if unchanged/busy, -1 for invalid size. */
int cv_copy_frame(cv_player *player, uint32_t *destination,
                  int width, int height, uint64_t *sequence);
int cv_width(const cv_player *player);
int cv_height(const cv_player *player);

#endif
