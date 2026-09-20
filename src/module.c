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

#include <emacs-module.h>
#include <mpv/client.h>
#include "player.h"
#include "scale.h"
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

int plugin_is_GPL_compatible;

typedef struct {
    cv_player *player;
    uint64_t sequence;
} player_ref;

static emacs_value call(emacs_env *env, const char *name,
                         ptrdiff_t count, emacs_value *args)
{
    return env->funcall(env, env->intern(env, name), count, args);
}

static emacs_value fail(emacs_env *env, const char *message)
{
    emacs_value text = env->make_string(env, message, (ptrdiff_t)strlen(message));
    emacs_value list = call(env, "list", 1, &text);
    env->non_local_exit_signal(env, env->intern(env, "error"), list);
    return env->intern(env, "nil");
}

static int exited(emacs_env *env)
{
    return env->non_local_exit_check(env) != emacs_funcall_exit_return;
}

static void finalize(void *opaque)
{
    player_ref *ref = opaque;
    if (ref) {
        cv_destroy(ref->player);
        free(ref);
    }
}

static player_ref *reference(emacs_env *env, emacs_value value, int allow_closed)
{
    emacs_finalizer finalizer = env->get_user_finalizer(env, value);
    if (exited(env))
        return NULL;
    if (finalizer != finalize) {
        fail(env, "Not a canvas-video player handle");
        return NULL;
    }
    player_ref *ref = env->get_user_ptr(env, value);
    if (!ref || (!allow_closed && !ref->player)) {
        fail(env, "Canvas video player is closed");
        return NULL;
    }
    return ref;
}

static char *string_copy(emacs_env *env, emacs_value value)
{
    ptrdiff_t size = 0;
    if (!env->copy_string_contents(env, value, NULL, &size))
        return NULL;
    char *text = malloc((size_t)size);
    if (!text) {
        fail(env, "Cannot allocate command string");
        return NULL;
    }
    if (!env->copy_string_contents(env, value, text, &size)) {
        free(text);
        return NULL;
    }
    if (memchr(text, '\0', (size_t)size - 1)) {
        free(text);
        fail(env, "Player arguments cannot contain NUL bytes");
        return NULL;
    }
    return text;
}

static emacs_value native_create(emacs_env *env, ptrdiff_t nargs,
                                  emacs_value *args, void *data)
{
    (void)nargs; (void)data;
    intmax_t width = env->extract_integer(env, args[0]);
    intmax_t height = env->extract_integer(env, args[1]);
    if (exited(env))
        return env->intern(env, "nil");
    if (width < 1 || width > 4096 || height < 1 || height > 4096)
        return fail(env, "Video dimensions must be between 1 and 4096");
    char *audio = NULL;
    if (env->is_not_nil(env, args[2])) {
        audio = string_copy(env, args[2]);
        if (!audio)
            return env->intern(env, "nil");
    }
    char error[256];
    cv_player *player = cv_create((int)width, (int)height, audio, error, sizeof(error));
    free(audio);
    if (!player)
        return fail(env, error);
    player_ref *ref = calloc(1, sizeof(*ref));
    if (!ref) {
        cv_destroy(player);
        return fail(env, "Cannot allocate player handle");
    }
    ref->player = player;
    emacs_value value = env->make_user_ptr(env, finalize, ref);
    if (exited(env))
        finalize(ref);
    return value;
}

static emacs_value native_close(emacs_env *env, ptrdiff_t nargs,
                                 emacs_value *args, void *data)
{
    (void)nargs; (void)data;
    player_ref *ref = reference(env, args[0], 1);
    if (ref) {
        cv_destroy(ref->player);
        ref->player = NULL;
    }
    return env->intern(env, "nil");
}

static emacs_value native_command(emacs_env *env, ptrdiff_t nargs,
                                   emacs_value *args, void *data)
{
    (void)nargs; (void)data;
    player_ref *ref = reference(env, args[0], 0);
    if (!ref)
        return env->intern(env, "nil");
    ptrdiff_t count = env->vec_size(env, args[1]);
    if (exited(env))
        return env->intern(env, "nil");
    if (count < 1 || count > 32)
        return fail(env, "Command needs between 1 and 32 string arguments");
    char *argv[33] = {0};
    for (ptrdiff_t i = 0; i < count; ++i) {
        argv[i] = string_copy(env, env->vec_get(env, args[1], i));
        if (!argv[i]) {
            for (ptrdiff_t j = 0; j < i; ++j)
                free(argv[j]);
            return env->intern(env, "nil");
        }
    }
    int result = cv_command(ref->player, (const char *const *)argv);
    for (ptrdiff_t i = 0; i < count; ++i)
        free(argv[i]);
    if (result < 0)
        return fail(env, mpv_error_string(result));
    return env->intern(env, "t");
}

static emacs_value native_present(emacs_env *env, ptrdiff_t nargs,
                                   emacs_value *args, void *data)
{
    (void)nargs; (void)data;
    player_ref *ref = reference(env, args[0], 0);
    if (!ref)
        return env->intern(env, "nil");
    emacs_value plist = call(env, "cdr", 1, &args[1]);
    emacs_value get[] = {plist, env->intern(env, ":data-width")};
    emacs_value w = call(env, "plist-get", 2, get);
    get[1] = env->intern(env, ":data-height");
    emacs_value h = call(env, "plist-get", 2, get);
    intmax_t width = env->extract_integer(env, w);
    intmax_t height = env->extract_integer(env, h);
    if (exited(env))
        return env->intern(env, "nil");
    if (width != cv_width(ref->player) || height != cv_height(ref->player))
        return fail(env, "Canvas dimensions differ from player dimensions; reopen the video");
    /* Never cache this pointer: canvas resize or GC may invalidate it. */
    uint32_t *pixels = env->canvas_data(env, args[1]);
    if (exited(env))
        return env->intern(env, "nil");
    if (!pixels)
        return fail(env, "Cannot access canvas pixel buffer");
    int copied = cv_copy_frame(ref->player, pixels, (int)width, (int)height,
                               &ref->sequence);
    return env->intern(env, copied > 0 ? "t" : "nil");
}

static int canvas_size(emacs_env *env, emacs_value canvas, int *width, int *height)
{
    emacs_value plist = call(env, "cdr", 1, &canvas);
    if (exited(env)) return 0;
    emacs_value get[] = {plist, env->intern(env, ":data-width")};
    emacs_value value = call(env, "plist-get", 2, get);
    if (exited(env)) return 0;
    intmax_t w = env->extract_integer(env, value);
    if (exited(env)) return 0;
    get[1] = env->intern(env, ":data-height");
    value = call(env, "plist-get", 2, get);
    if (exited(env)) return 0;
    intmax_t h = env->extract_integer(env, value);
    if (exited(env)) return 0;
    if (w < 1 || w > 4096 || h < 1 || h > 4096) {
        fail(env, "Canvas dimensions must be between 1 and 4096");
        return 0;
    }
    *width = (int)w;
    *height = (int)h;
    return 1;
}

static emacs_value native_scale(emacs_env *env, ptrdiff_t nargs,
                                emacs_value *args, void *data)
{
    (void)nargs; (void)data;
    int sw, sh, dw, dh;
    if (!canvas_size(env, args[0], &sw, &sh) ||
        !canvas_size(env, args[1], &dw, &dh))
        return env->intern(env, "nil");
    if (env->eq(env, args[0], args[1]))
        return fail(env, "Source and destination canvases must be distinct");
    uint32_t *source = env->canvas_data(env, args[0]);
    if (exited(env)) return env->intern(env, "nil");
    uint32_t *destination = env->canvas_data(env, args[1]);
    if (exited(env)) return env->intern(env, "nil");
    if (!source || !destination)
        return fail(env, "Cannot access canvas pixel buffer");
    cv_scale(source, sw, sh, destination, dw, dh);
    return env->intern(env, "t");
}

static emacs_value native_status(emacs_env *env, ptrdiff_t nargs,
                                  emacs_value *args, void *data)
{
    (void)nargs; (void)data;
    player_ref *ref = reference(env, args[0], 0);
    if (!ref)
        return env->intern(env, "nil");
    cv_status s;
    cv_get_status(ref->player, &s);
    emacs_value values[] = {
        env->intern(env, ":position"), env->make_float(env, s.position),
        env->intern(env, ":duration"), env->make_float(env, s.duration),
        env->intern(env, ":volume"), env->make_float(env, s.volume),
        env->intern(env, ":speed"), env->make_float(env, s.speed),
        env->intern(env, ":paused"), env->intern(env, s.paused ? "t" : "nil"),
        env->intern(env, ":eof"), env->intern(env, s.eof ? "t" : "nil"),
        env->intern(env, ":idle"), env->intern(env, s.idle ? "t" : "nil"),
        env->intern(env, ":frames"), env->make_integer(env, (intmax_t)s.frames),
        env->intern(env, ":error"), s.error[0]
            ? env->make_string(env, s.error, (ptrdiff_t)strlen(s.error))
            : env->intern(env, "nil")
    };
    return call(env, "list", (ptrdiff_t)(sizeof(values) / sizeof(values[0])), values);
}

int emacs_module_init(struct emacs_runtime *runtime)
{
    if (runtime->size < (ptrdiff_t)sizeof(*runtime))
        return 1;
    emacs_env *env = runtime->get_environment(runtime);
    if (env->size < (ptrdiff_t)(offsetof(emacs_env, canvas_data) + sizeof(env->canvas_data)))
        return 2;
    struct binding {
        const char *name;
        ptrdiff_t arity;
        emacs_function function;
        const char *doc;
    } bindings[] = {
        {"canvas-video--native-create", 3, native_create,
         "Create a player for WIDTH HEIGHT and AUDIO-OUTPUT (nil for automatic)."},
        {"canvas-video--native-close", 1, native_close, "Close PLAYER, idempotently."},
        {"canvas-video--native-command", 2, native_command,
         "Queue a libmpv command for PLAYER using a vector of strings ARGS."},
        {"canvas-video--native-present", 2, native_present,
         "Copy PLAYER's newest frame to CANVAS; return t if changed."},
        {"canvas-video--native-scale", 2, native_scale,
         "Bilinearly scale SOURCE canvas pixels into distinct DESTINATION canvas."},
        {"canvas-video--native-status", 1, native_status,
         "Drain PLAYER events and return its playback status plist."}
    };
    for (size_t i = 0; i < sizeof(bindings) / sizeof(bindings[0]); ++i) {
        emacs_value args[] = {
            env->intern(env, bindings[i].name),
            env->make_function(env, bindings[i].arity, bindings[i].arity,
                               bindings[i].function, bindings[i].doc, NULL)
        };
        call(env, "fset", 2, args);
        if (exited(env))
            return 3;
    }
    emacs_value feature = env->intern(env, "canvas-video-module");
    call(env, "provide", 1, &feature);
    return exited(env) ? 4 : 0;
}
