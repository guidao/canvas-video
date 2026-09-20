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

#define _POSIX_C_SOURCE 200809L
#include "player.h"
#include <mpv/client.h>
#include <mpv/render.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct cv_player {
    mpv_handle *mpv;
    mpv_render_context *render;
    pthread_t thread;
    pthread_mutex_t wake_mutex, frame_mutex;
    pthread_cond_t wake_condition;
    bool thread_started, stop, pending;
    int width, height, render_error;
    size_t stride;
    uint32_t *front, *back;
    uint64_t sequence;
    char error[256];
};

static void wake_renderer(void *opaque)
{
    cv_player *p = opaque;
    /* Never call mpv or Emacs here; libmpv invokes this on its own threads. */
    pthread_mutex_lock(&p->wake_mutex);
    p->pending = true;
    pthread_cond_signal(&p->wake_condition);
    pthread_mutex_unlock(&p->wake_mutex);
}

static void *render_frames(void *opaque)
{
    cv_player *p = opaque;
    const uint32_t endian = 1;
    char *format = *(const unsigned char *)&endian ? "bgr0" : "0rgb";
    int size[] = {p->width, p->height};

    for (;;) {
        pthread_mutex_lock(&p->wake_mutex);
        while (!p->pending && !p->stop)
            pthread_cond_wait(&p->wake_condition, &p->wake_mutex);
        bool stop = p->stop;
        p->pending = false;
        pthread_mutex_unlock(&p->wake_mutex);
        if (stop)
            break;

        /* No locks held while entering libmpv.  Rendering can wait until the
           frame's target time; only this worker waits, never the Emacs thread. */
        if (!(mpv_render_context_update(p->render) & MPV_RENDER_UPDATE_FRAME))
            continue;
        mpv_render_param params[] = {
            {MPV_RENDER_PARAM_SW_SIZE, size},
            {MPV_RENDER_PARAM_SW_FORMAT, format},
            {MPV_RENDER_PARAM_SW_STRIDE, &p->stride},
            {MPV_RENDER_PARAM_SW_POINTER, p->back},
            {MPV_RENDER_PARAM_INVALID, NULL}
        };
        int result = mpv_render_context_render(p->render, params);
        if (result < 0) {
            pthread_mutex_lock(&p->frame_mutex);
            p->render_error = result;
            pthread_mutex_unlock(&p->frame_mutex);
            continue;
        }
        for (int y = 0; y < p->height; ++y) {
            uint32_t *row = (uint32_t *)((char *)p->back + y * p->stride);
            for (int x = 0; x < p->width; ++x)
                row[x] |= UINT32_C(0xff000000);
        }
        pthread_mutex_lock(&p->frame_mutex);
        uint32_t *swap = p->front;
        p->front = p->back;
        p->back = swap;
        ++p->sequence;
        pthread_mutex_unlock(&p->frame_mutex);
    }
    return NULL;
}

cv_player *cv_create(int width, int height, const char *audio_output,
                     char *error, size_t error_size)
{
    if (width < 1 || height < 1 || width > 4096 || height > 4096) {
        snprintf(error, error_size, "Video dimensions must be between 1 and 4096");
        return NULL;
    }
    cv_player *p = calloc(1, sizeof(*p));
    if (!p) {
        snprintf(error, error_size, "Cannot allocate player");
        return NULL;
    }
    if (pthread_mutex_init(&p->wake_mutex, NULL) != 0) {
        free(p);
        snprintf(error, error_size, "Cannot initialize wake mutex");
        return NULL;
    }
    if (pthread_mutex_init(&p->frame_mutex, NULL) != 0) {
        pthread_mutex_destroy(&p->wake_mutex);
        free(p);
        snprintf(error, error_size, "Cannot initialize frame mutex");
        return NULL;
    }
    if (pthread_cond_init(&p->wake_condition, NULL) != 0) {
        pthread_mutex_destroy(&p->frame_mutex);
        pthread_mutex_destroy(&p->wake_mutex);
        free(p);
        snprintf(error, error_size, "Cannot initialize render condition");
        return NULL;
    }
    p->width = width;
    p->height = height;
    p->stride = ((size_t)width * 4 + 63) & ~(size_t)63;
    if (posix_memalign((void **)&p->front, 64, p->stride * height) != 0 ||
        posix_memalign((void **)&p->back, 64, p->stride * height) != 0) {
        snprintf(error, error_size, "Cannot allocate video frames");
        goto fail;
    }
    p->mpv = mpv_create();
    if (!p->mpv) {
        snprintf(error, error_size, "mpv_create failed");
        goto fail;
    }
    const char *options[][2] = {
        {"config", "no"}, {"terminal", "no"}, {"msg-level", "all=no"},
        {"load-scripts", "no"}, {"input-default-bindings", "no"},
        {"input-vo-keyboard", "no"}, {"osc", "no"}, {"vo", "libmpv"},
        {"idle", "yes"}, {"keep-open", "yes"}, {"audio-display", "no"},
        {"hwdec", "no"}, {"video-sync", "audio"},
        {"video-timing-offset", "0"}
    };
    for (size_t i = 0; i < sizeof(options) / sizeof(options[0]); ++i) {
        int r = mpv_set_option_string(p->mpv, options[i][0], options[i][1]);
        if (r < 0) {
            snprintf(error, error_size, "%s: %s", options[i][0], mpv_error_string(r));
            goto fail;
        }
    }
    if (audio_output && audio_output[0]) {
        int r = mpv_set_option_string(p->mpv, "ao", audio_output);
        if (r < 0) {
            snprintf(error, error_size, "Audio output: %s", mpv_error_string(r));
            goto fail;
        }
    }
    int result = mpv_initialize(p->mpv);
    if (result < 0) {
        snprintf(error, error_size, "mpv_initialize: %s", mpv_error_string(result));
        goto fail;
    }
    mpv_render_param params[] = {
        {MPV_RENDER_PARAM_API_TYPE, MPV_RENDER_API_TYPE_SW},
        {MPV_RENDER_PARAM_INVALID, NULL}
    };
    result = mpv_render_context_create(&p->render, p->mpv, params);
    if (result < 0) {
        snprintf(error, error_size, "Software renderer: %s", mpv_error_string(result));
        goto fail;
    }
    mpv_render_context_set_update_callback(p->render, wake_renderer, p);
    result = pthread_create(&p->thread, NULL, render_frames, p);
    if (result != 0) {
        snprintf(error, error_size, "Render thread: %s", strerror(result));
        goto fail;
    }
    p->thread_started = true;
    return p;
fail:
    cv_destroy(p);
    return NULL;
}

void cv_destroy(cv_player *p)
{
    if (!p)
        return;
    if (p->thread_started) {
        pthread_mutex_lock(&p->wake_mutex);
        p->stop = true;
        pthread_cond_signal(&p->wake_condition);
        pthread_mutex_unlock(&p->wake_mutex);
        pthread_join(p->thread, NULL);
    }
    if (p->render) {
        mpv_render_context_set_update_callback(p->render, NULL, NULL);
        mpv_render_context_free(p->render);
    }
    if (p->mpv)
        mpv_terminate_destroy(p->mpv);
    pthread_cond_destroy(&p->wake_condition);
    pthread_mutex_destroy(&p->wake_mutex);
    pthread_mutex_destroy(&p->frame_mutex);
    free(p->front);
    free(p->back);
    free(p);
}

int cv_command(cv_player *p, const char *const *arguments)
{
    if (!strcmp(arguments[0], "loadfile"))
        p->error[0] = '\0';
    return mpv_command_async(p->mpv, 0, (const char **)arguments);
}

static double number_property(mpv_handle *mpv, const char *name, double fallback)
{
    double value;
    return mpv_get_property(mpv, name, MPV_FORMAT_DOUBLE, &value) < 0
        ? fallback : value;
}

static int flag_property(mpv_handle *mpv, const char *name)
{
    int value;
    return mpv_get_property(mpv, name, MPV_FORMAT_FLAG, &value) < 0 ? 0 : value;
}

void cv_get_status(cv_player *p, cv_status *status)
{
    /* Bound event work per tick so an event flood cannot starve the editor. */
    for (int i = 0; i < 64; ++i) {
        mpv_event *event = mpv_wait_event(p->mpv, 0);
        if (event->event_id == MPV_EVENT_NONE)
            break;
        if (event->event_id == MPV_EVENT_END_FILE) {
            mpv_event_end_file *end = event->data;
            if (end->reason == MPV_END_FILE_REASON_ERROR)
                snprintf(p->error, sizeof(p->error), "Playback: %s",
                         mpv_error_string(end->error));
        } else if (event->event_id == MPV_EVENT_COMMAND_REPLY && event->error < 0) {
            snprintf(p->error, sizeof(p->error), "Command: %s",
                     mpv_error_string(event->error));
        } else if (event->event_id == MPV_EVENT_SHUTDOWN) {
            snprintf(p->error, sizeof(p->error), "Player shut down");
        }
    }
    status->position = number_property(p->mpv, "time-pos", -1);
    status->duration = number_property(p->mpv, "duration", -1);
    status->volume = number_property(p->mpv, "volume", 100);
    status->speed = number_property(p->mpv, "speed", 1);
    status->paused = flag_property(p->mpv, "pause");
    status->eof = flag_property(p->mpv, "eof-reached");
    status->idle = flag_property(p->mpv, "idle-active");
    snprintf(status->error, sizeof(status->error), "%s", p->error);
    pthread_mutex_lock(&p->frame_mutex);
    status->frames = p->sequence;
    if (p->render_error < 0)
        snprintf(status->error, sizeof(status->error), "Render: %s",
                 mpv_error_string(p->render_error));
    pthread_mutex_unlock(&p->frame_mutex);
}

int cv_copy_frame(cv_player *p, uint32_t *destination,
                  int width, int height, uint64_t *sequence)
{
    if (!destination || width != p->width || height != p->height)
        return -1;
    if (pthread_mutex_trylock(&p->frame_mutex) != 0)
        return 0;
    int copied = 0;
    if (p->sequence != *sequence) {
        for (int y = 0; y < height; ++y)
            memcpy(destination + (size_t)y * width,
                   (char *)p->front + y * p->stride, (size_t)width * 4);
        *sequence = p->sequence;
        copied = 1;
    }
    pthread_mutex_unlock(&p->frame_mutex);
    return copied;
}

int cv_width(const cv_player *p) { return p->width; }
int cv_height(const cv_player *p) { return p->height; }
