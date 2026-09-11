#define _POSIX_C_SOURCE 200809L
#include "player.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

static void delay(void)
{
    struct timespec duration = {0, 10000000};
    nanosleep(&duration, NULL);
}

static void command(cv_player *p, const char *a, const char *b, const char *c)
{
    const char *args[] = {a, b, c, NULL};
    assert(cv_command(p, args) >= 0);
}

static cv_status status(cv_player *p)
{
    cv_status s;
    cv_get_status(p, &s);
    if (s.error[0]) {
        fprintf(stderr, "Unexpected player error: %s\n", s.error);
        abort();
    }
    return s;
}

static void wait_color(cv_player *p, uint32_t *pixels, uint64_t *sequence, int blue)
{
    for (int i = 0; i < 500; ++i) {
        (void)status(p);
        if (cv_copy_frame(p, pixels, 318, 180, sequence) > 0) {
            /* Check center plus several rows: output width is deliberately
               not divisible by 16, exercising aligned-stride unpacking. */
            int matches = 1;
            for (int y = 10; y < 170; y += 17) {
                uint32_t pixel = pixels[y * 318 + 159];
                int r = (pixel >> 16) & 255, b = pixel & 255;
                assert((pixel >> 24) == 255);
                if (!(blue ? (b > 180 && r < 60) : (r > 180 && b < 60)))
                    matches = 0;
            }
            if (matches)
                return;
        }
        delay();
    }
    fprintf(stderr, "Timed out waiting for %s video frame\n", blue ? "blue" : "red");
    abort();
}

int main(int argc, char **argv)
{
    assert(argc == 2);
    char error[256];
    assert(!cv_create(0, 180, "null", error, sizeof(error)));
    cv_player *p = cv_create(318, 180, "null", error, sizeof(error));
    if (!p) {
        fprintf(stderr, "%s\n", error);
        return 1;
    }
    uint32_t *pixels = calloc(318 * 180, sizeof(*pixels));
    assert(pixels);
    uint64_t sequence = 0;
    assert(cv_copy_frame(p, pixels, 319, 180, &sequence) == -1);
    command(p, "loadfile", argv[1], "replace");
    wait_color(p, pixels, &sequence, 0);
    assert(status(p).duration > 3.9);

    command(p, "set", "pause", "yes");
    for (int i = 0; i < 200 && !status(p).paused; ++i)
        delay();
    cv_status paused = status(p);
    assert(paused.paused);
    for (int i = 0; i < 20; ++i)
        delay();
    assert(fabs(status(p).position - paused.position) < 0.08);

    command(p, "seek", "2.5", "absolute+exact");
    wait_color(p, pixels, &sequence, 1);
    assert(status(p).paused);
    assert(fabs(status(p).position - 2.5) < 0.12);
    command(p, "set", "volume", "35");
    command(p, "set", "speed", "2");
    for (int i = 0; i < 200; ++i) {
        cv_status s = status(p);
        if (fabs(s.volume - 35) < 0.1 && fabs(s.speed - 2) < 0.01)
            break;
        delay();
    }
    assert(fabs(status(p).volume - 35) < 0.1);
    assert(fabs(status(p).speed - 2) < 0.01);
    command(p, "set", "pause", "no");
    for (int i = 0; i < 500 && !status(p).eof; ++i)
        delay();
    assert(status(p).eof);
    command(p, "seek", "0", "absolute+exact");
    command(p, "set", "pause", "no");
    wait_color(p, pixels, &sequence, 0);
    cv_destroy(p); /* close during active playback */

    for (int i = 0; i < 5; ++i) {
        p = cv_create(318, 180, "null", error, sizeof(error));
        assert(p);
        command(p, "loadfile", argv[1], "replace");
        cv_destroy(p); /* pending load + worker teardown */
    }
    p = cv_create(318, 180, "null", error, sizeof(error));
    assert(p);
    command(p, "loadfile", "/nonexistent/canvas-video-test.mkv", "replace");
    cv_status failure = {0};
    for (int i = 0; i < 300; ++i) {
        cv_get_status(p, &failure);
        if (failure.error[0])
            break;
        delay();
    }
    assert(failure.error[0]);
    cv_destroy(p);
    free(pixels);
    puts("PASS: real frames, ARGB alpha/stride, pause, seek, volume, speed, EOF, replay, errors and teardown");
    return 0;
}
