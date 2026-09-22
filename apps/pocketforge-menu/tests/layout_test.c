#define _GNU_SOURCE
#define _POSIX_C_SOURCE 200809L

#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#define main pocketforge_menu_main
#include "../src/main.c"
#undef main

static void assert_highlight_spans_long_axis(unsigned int width,
                                             unsigned int height) {
    const unsigned int stride = width * 4;
    unsigned char *buffer = calloc(height, stride);
    assert(buffer != NULL);

    draw_menu(buffer, stride, width, height, 0);

    unsigned int min_x = width, min_y = height, max_x = 0, max_y = 0;
    for (unsigned int y = 0; y < height; y++) {
        for (unsigned int x = 0; x < width; x++) {
            const unsigned char *p = buffer + (size_t)y * stride + x * 4;
            if (p[0] == EM_B && p[1] == EM_G && p[2] == EM_R) {
                if (x < min_x) min_x = x;
                if (x > max_x) max_x = x;
                if (y < min_y) min_y = y;
                if (y > max_y) max_y = y;
            }
        }
    }

    assert(min_x <= max_x && min_y <= max_y);
    if (width >= height)
        assert(max_x - min_x + 1 == width - 64);
    else
        assert(max_y - min_y + 1 == height - 64);

    free(buffer);
}

int main(void) {
    assert_highlight_spans_long_axis(1280, 720);
    assert_highlight_spans_long_axis(720, 1280);
    puts("menu layout: PASS (1280x720 and 720x1280)");
    return 0;
}
