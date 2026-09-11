#ifndef CANVAS_VIDEO_SCALE_H
#define CANVAS_VIDEO_SCALE_H
#include <stdint.h>

/* Bilinear scaling of distinct, tightly packed ARGB32 buffers.
   All dimensions must be in [1, 4096]. */
void cv_scale(const uint32_t *source, int sw, int sh,
              uint32_t *destination, int dw, int dh);
#endif
