#include "scale.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(void)
{
    const uint32_t corners[] = {0xffff0000, 0xff00ff00, 0xff0000ff, 0xffffffff};
    uint32_t pixels[16];
    cv_scale(corners, 2, 2, pixels, 4, 4);
    assert(pixels[0] == corners[0] && pixels[3] == corners[1]);
    assert(pixels[12] == corners[2] && pixels[15] == corners[3]);
    /* Interior pixels must interpolate, not just copy/crop the source. */
    assert(pixels[5] == 0xff9f4040);
    for (int i = 0; i < 16; ++i) assert((pixels[i] >> 24) == 255);
    cv_scale(corners, 2, 2, pixels, 1, 1);
    assert(pixels[0] == 0xff808080);
    cv_scale(corners, 2, 2, pixels, 2, 2);
    assert(memcmp(corners, pixels, sizeof(corners)) == 0);

    const uint32_t single[] = {0xff123456};
    cv_scale(single, 1, 1, pixels, 4, 4);
    for (int i = 0; i < 16; ++i) assert(pixels[i] == single[0]);
    /* Exercise maximum coordinates, both portrait and landscape, and guard
       the destination boundaries against writes outside the declared size. */
    uint32_t *wide = malloc(4097 * sizeof(*wide));
    uint32_t *scaled = malloc(4097 * 2 * sizeof(*scaled));
    assert(wide && scaled);
    for (int i = 0; i < 4097; ++i) wide[i] = (uint32_t)i | 0xff000000;
    scaled[0] = scaled[8193] = 0x12345678;
    cv_scale(wide, 4096, 1, scaled + 1, 4096, 2);
    assert(scaled[4096] == wide[4095] && scaled[8192] == wide[4095]);
    cv_scale(wide, 1, 4096, scaled + 1, 2, 4096);
    assert(scaled[8191] == wide[4095] && scaled[8192] == wide[4095]);
    assert(scaled[0] == 0x12345678 && scaled[8193] == 0x12345678);
    free(wide);
    free(scaled);
    puts("PASS: pixel scaling, interpolation, edges, alpha, portrait and maximum dimensions");
    return 0;
}
