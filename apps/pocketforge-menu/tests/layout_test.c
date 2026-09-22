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

static void assert_portrait_is_rotated_landscape(void) {
    const unsigned int landscape_width = 1280, landscape_height = 720;
    const unsigned int portrait_width = 720, portrait_height = 1280;
    unsigned char *landscape = calloc(landscape_height, landscape_width * 4);
    unsigned char *portrait = calloc(portrait_height, portrait_width * 4);
    assert(landscape != NULL && portrait != NULL);

    draw_menu(landscape, landscape_width * 4,
              landscape_width, landscape_height, 0);
    draw_menu(portrait, portrait_width * 4,
              portrait_width, portrait_height, 0);

    for (unsigned int y = 0; y < landscape_height; y++) {
        for (unsigned int x = 0; x < landscape_width; x++) {
            const unsigned char *logical =
                landscape + ((size_t)y * landscape_width + x) * 4;
            const unsigned char *native =
                portrait + ((size_t)x * portrait_width +
                            portrait_width - 1 - y) * 4;
            assert(memcmp(logical, native, 4) == 0);
        }
    }

    free(portrait);
    free(landscape);
}

static void assert_portrait_corner_mapping(void) {
    const unsigned int width = 720, height = 1280, stride = width * 4;
    unsigned char *portrait = calloc(height, stride);
    assert(portrait != NULL);

    /* scene (0,0) -> buffer (719,0) */
    fill_rect(portrait, stride, width, height, 0, 0, 1, 1, 1, 2, 3);
    const unsigned char *top_left = portrait + (size_t)719 * 4;
    assert(top_left[0] == 3 && top_left[1] == 2 && top_left[2] == 1);

    /* scene (1279,719) -> buffer (0,1279) */
    fill_rect(portrait, stride, width, height,
              1279, 719, 1280, 720, 4, 5, 6);
    const unsigned char *bottom_right =
        portrait + ((size_t)1279 * width) * 4;
    assert(bottom_right[0] == 6 && bottom_right[1] == 5 &&
           bottom_right[2] == 4);

    free(portrait);
}

int main(void) {
    assert_highlight_spans_long_axis(1280, 720);
    assert_highlight_spans_long_axis(720, 1280);
    assert_portrait_is_rotated_landscape();
    assert_portrait_corner_mapping();
    puts("menu layout: PASS (1280x720 and 720x1280)");
    return 0;
}
