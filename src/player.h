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
