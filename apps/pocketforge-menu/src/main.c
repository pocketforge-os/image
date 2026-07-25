/*
 * pocketforge-menu (bd: tsp-ga7s.1)
 * -----------------------------------------------------------------------------
 * MVP static launcher. Three HARDCODED rows — "Button Tester", "Steam Link",
 * "poolside.fm". LRADC volume keys navigate (KEY_VOLUMEUP → up, KEY_VOLUMEDOWN
 * → down, wrapping); there is no select action (no third LRADC key). Highlight
 * inverts the selected row (charcoal-on-ember). Redraw ONLY on state change.
 *
 * fb0 handoff from pocketforge-boot-animator.service is done by systemd (this
 * unit declares Conflicts=/After= on ITSELF, per the reliable direction proven
 * by tsp-ikk0.11) — exactly one fb0 writer, no pan-fight (root cause tsp-7kpp).
 *
 * Pan-to-present (tsp-woy3): fb0's scan-out is a g2d-rotated copy of fb0 that
 * refreshes ONLY on FBIOPAN_DISPLAY, so we redraw the inactive page and pan.
 *
 * Font: 8x16 monospace bitmap, hand-crafted for the ~22 glyphs the three
 * labels use plus space and '.'. Rendered at scale 4 → 32x64 per glyph, plenty
 * readable on the 1280x720 landscape panel. libc only — no freetype/harfbuzz.
 */

#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <fcntl.h>
#include <linux/fb.h>
#include <linux/input.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

#define FB_W  1280
#define FB_H  720

/* Warm near-black field + PocketForge ember accent (matches placeholder). */
#define BG_R  0x14
#define BG_G  0x12
#define BG_B  0x10
#define EM_R  0xE8
#define EM_G  0x62
#define EM_B  0x2A

#define ROW_COUNT 3
#define GLYPH_W   8
#define GLYPH_H   16
#define GLYPH_SCALE 4

/* 8x16 bitmap font. Each glyph is 16 bytes = 16 rows; MSB = leftmost column.
 * Only the glyphs the three MVP labels use are populated (a-z subset + B, L,
 * S, T + '.' + space); everything else is a zeroed slot rendered as blank. */
static const uint8_t glyph_table[128][16] = {
    [' ']  = {0},
    ['.']  = {0,0,0,0,0,0,0,0,0,0,0,0x18,0x18,0,0,0},
    ['B']  = {0,0,0, 0xFC, 0x66, 0x66, 0x66, 0x7C, 0x66, 0x66, 0x66, 0x66, 0xFC, 0,0,0},
    ['L']  = {0,0,0, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x7E, 0,0,0},
    ['S']  = {0,0,0, 0x3C, 0x66, 0x60, 0x60, 0x3C, 0x06, 0x06, 0x06, 0x66, 0x3C, 0,0,0},
    ['T']  = {0,0,0, 0xFE, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0,0,0},
    ['a']  = {0,0,0,0,0, 0x38, 0x44, 0x04, 0x3C, 0x44, 0x44, 0x44, 0x3A, 0,0,0},
    ['b']  = {0,0,0, 0x40, 0x40, 0x40, 0x7C, 0x42, 0x42, 0x42, 0x42, 0x42, 0x7C, 0,0,0},
    ['d']  = {0,0,0, 0x02, 0x02, 0x02, 0x3E, 0x42, 0x42, 0x42, 0x42, 0x42, 0x3E, 0,0,0},
    ['e']  = {0,0,0,0,0, 0x38, 0x44, 0x44, 0x7C, 0x40, 0x40, 0x44, 0x38, 0,0,0},
    ['f']  = {0,0,0, 0x1C, 0x22, 0x20, 0x7C, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0,0,0},
    ['i']  = {0,0,0, 0x18, 0x18, 0, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0,0,0},
    ['k']  = {0,0,0, 0x40, 0x40, 0x40, 0x46, 0x4C, 0x58, 0x70, 0x58, 0x4C, 0x46, 0,0,0},
    ['l']  = {0,0,0, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0,0,0},
    ['m']  = {0,0,0,0,0,0, 0xEC, 0xFE, 0xD6, 0xD6, 0xD6, 0xD6, 0xD6, 0,0,0},
    ['n']  = {0,0,0,0,0,0, 0x7C, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0,0,0},
    ['o']  = {0,0,0,0,0,0, 0x3C, 0x66, 0x66, 0x66, 0x66, 0x66, 0x3C, 0,0,0},
    ['p']  = {0,0,0,0,0,0, 0x7C, 0x66, 0x66, 0x66, 0x66, 0x7C, 0x60, 0x60, 0x60, 0},
    ['r']  = {0,0,0,0,0,0, 0x6E, 0x70, 0x60, 0x60, 0x60, 0x60, 0x60, 0,0,0},
    ['s']  = {0,0,0,0,0,0, 0x3C, 0x66, 0x60, 0x3C, 0x06, 0x66, 0x3C, 0,0,0},
    ['t']  = {0,0,0, 0x30, 0x30, 0xFC, 0x30, 0x30, 0x30, 0x30, 0x30, 0x36, 0x1C, 0,0,0},
    ['u']  = {0,0,0,0,0,0, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x3B, 0,0,0},
};

static const char *const LABELS[ROW_COUNT] = {
    "Button Tester",
    "Steam Link",
    "poolside.fm",
};

static volatile sig_atomic_t g_stop = 0;
static void on_signal(int sig) { (void)sig; g_stop = 1; }

/* Unbind fbcon so kernel console text cannot bleed onto our screen. Best
 * effort: no-op if already unbound or fbcon absent. */
static void hide_fbcon(void) {
    int fd = open("/sys/class/vtconsole/vtcon1/bind", O_WRONLY | O_CLOEXEC);
    if (fd < 0) return;
    ssize_t n = write(fd, "0\n", 2);
    (void)n;
    close(fd);
}

/* Write one XRGB8888 pixel (sunxi DE2.0 byte order: B, G, R, X). */
static inline void put_px(unsigned char *p, unsigned char r,
                          unsigned char g, unsigned char b) {
    p[0] = b; p[1] = g; p[2] = r; p[3] = 0xFF;
}

static void fill_rect(unsigned char *page, unsigned int stride,
                      int x0, int y0, int x1, int y1,
                      unsigned char r, unsigned char g, unsigned char b) {
    if (x0 < 0) x0 = 0;
    if (y0 < 0) y0 = 0;
    if (x1 > FB_W) x1 = FB_W;
    if (y1 > FB_H) y1 = FB_H;
    for (int y = y0; y < y1; y++) {
        unsigned char *dp = page + (size_t)y * stride + (size_t)x0 * 4;
        for (int x = x0; x < x1; x++) { put_px(dp, r, g, b); dp += 4; }
    }
}

/* Draw one 8x16 glyph at (x, y), scale s, in colour (r,g,b). Zeroed glyph
 * slots render as blank — safe for chars we do not have a bitmap for. */
static void draw_glyph(unsigned char *page, unsigned int stride,
                       int x, int y, int s, unsigned char c,
                       unsigned char r, unsigned char g, unsigned char b) {
    if (c >= 128) return;
    const uint8_t *rows = glyph_table[c];
    for (int gy = 0; gy < GLYPH_H; gy++) {
        uint8_t bits = rows[gy];
        if (!bits) continue;
        for (int gx = 0; gx < GLYPH_W; gx++) {
            if (bits & (0x80 >> gx))
                fill_rect(page, stride,
                          x + gx * s, y + gy * s,
                          x + (gx + 1) * s, y + (gy + 1) * s,
                          r, g, b);
        }
    }
}

static void draw_string(unsigned char *page, unsigned int stride,
                        int x, int y, int s, const char *str,
                        unsigned char r, unsigned char g, unsigned char b) {
    for (const unsigned char *p = (const unsigned char *)str; *p; p++) {
        draw_glyph(page, stride, x, y, s, *p, r, g, b);
        x += GLYPH_W * s;
    }
}

/* Full page repaint keyed on `highlight` (0..2). */
static void draw_menu(unsigned char *page, unsigned int stride, int highlight) {
    fill_rect(page, stride, 0, 0, FB_W, FB_H, BG_R, BG_G, BG_B);

    const int row_h = FB_H / ROW_COUNT;              /* 240 px per row */
    const int text_w_char = GLYPH_W * GLYPH_SCALE;   /* 32 px per char */
    const int text_h = GLYPH_H * GLYPH_SCALE;        /* 64 px tall     */

    for (int i = 0; i < ROW_COUNT; i++) {
        const int y0 = i * row_h;
        const int y1 = y0 + row_h;
        const int is_hi = (i == highlight);

        /* Highlight = ember fill + charcoal text; else charcoal fill + ember
         * text. A visible margin around the ember row makes the highlight
         * unambiguous from across a room. */
        unsigned char bgr = is_hi ? EM_R : BG_R;
        unsigned char bgg = is_hi ? EM_G : BG_G;
        unsigned char bgb = is_hi ? EM_B : BG_B;
        unsigned char fgr = is_hi ? BG_R : EM_R;
        unsigned char fgg = is_hi ? BG_G : EM_G;
        unsigned char fgb = is_hi ? BG_B : EM_B;

        if (is_hi) {
            const int m = 32;
            fill_rect(page, stride, m, y0 + m, FB_W - m, y1 - m,
                      bgr, bgg, bgb);
        }

        const char *label = LABELS[i];
        const int len = (int)strlen(label);
        const int tx = (FB_W - len * text_w_char) / 2;
        const int ty = y0 + (row_h - text_h) / 2;
        draw_string(page, stride, tx, ty, GLYPH_SCALE, label,
                    fgr, fgg, fgb);
    }
}

/* Try /dev/input/event0..event15 and return the first that reports the
 * KEY_VOLUMEUP capability. LRADC's numbering can shift across boots depending
 * on probe order (SD hotplug etc.), so a hard-coded /dev/input/event0 is
 * fragile; fall back to it only if scanning finds nothing. */
static int open_lradc_input(void) {
    for (int i = 0; i < 16; i++) {
        char path[32];
        snprintf(path, sizeof path, "/dev/input/event%d", i);
        int fd = open(path, O_RDONLY | O_CLOEXEC);
        if (fd < 0) continue;
        uint8_t keybits[(KEY_MAX + 7) / 8];
        memset(keybits, 0, sizeof keybits);
        if (ioctl(fd, EVIOCGBIT(EV_KEY, sizeof keybits), keybits) >= 0) {
            if (keybits[KEY_VOLUMEUP / 8] & (1u << (KEY_VOLUMEUP % 8))) {
                fprintf(stderr, "menu: input via %s\n", path);
                return fd;
            }
        }
        close(fd);
    }
    int fd = open("/dev/input/event0", O_RDONLY | O_CLOEXEC);
    if (fd >= 0)
        fprintf(stderr, "menu: no VOLUMEUP-capable device found; "
                        "falling back to /dev/input/event0\n");
    return fd;
}

int main(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = on_signal;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT,  &sa, NULL);

    hide_fbcon();

    int fb = open("/dev/fb0", O_RDWR | O_CLOEXEC);
    if (fb < 0) {
        fprintf(stderr, "menu: open /dev/fb0: %s\n", strerror(errno));
        return 1;
    }
    struct fb_var_screeninfo vinfo;
    struct fb_fix_screeninfo finfo;
    if (ioctl(fb, FBIOGET_VSCREENINFO, &vinfo) < 0 ||
        ioctl(fb, FBIOGET_FSCREENINFO, &finfo) < 0) {
        fprintf(stderr, "menu: FBIOGET_*SCREENINFO: %s\n", strerror(errno));
        close(fb);
        return 1;
    }
    if (vinfo.xres != FB_W || vinfo.yres != FB_H || vinfo.bits_per_pixel != 32) {
        fprintf(stderr, "menu: unexpected fb0 geometry %ux%u @%ubpp; "
                        "expected %ux%u @32bpp\n",
                vinfo.xres, vinfo.yres, vinfo.bits_per_pixel, FB_W, FB_H);
        close(fb);
        return 1;
    }

    size_t page_bytes = (size_t)finfo.line_length * vinfo.yres;
    size_t map_bytes  = (size_t)finfo.line_length * vinfo.yres_virtual;
    if (map_bytes == 0) map_bytes = page_bytes;
    unsigned char *fbmap = mmap(NULL, map_bytes, PROT_READ | PROT_WRITE,
                                MAP_SHARED, fb, 0);
    if (fbmap == MAP_FAILED) {
        fprintf(stderr, "menu: mmap fb0: %s\n", strerror(errno));
        close(fb);
        return 1;
    }
    const unsigned int n_pages =
        (vinfo.yres_virtual >= 2 * vinfo.yres) ? 2 : 1;
    unsigned int page = 0;

    int input_fd = open_lradc_input();
    if (input_fd < 0) {
        fprintf(stderr, "menu: open input: %s\n", strerror(errno));
        munmap(fbmap, map_bytes);
        close(fb);
        return 1;
    }

    int highlight = 0;

    /* Initial paint + present. */
    draw_menu(fbmap + (size_t)page * page_bytes, finfo.line_length, highlight);
    msync(fbmap, map_bytes, MS_SYNC);
    vinfo.xoffset = 0;
    vinfo.yoffset = page * vinfo.yres;
    if (ioctl(fb, FBIOPAN_DISPLAY, &vinfo) < 0)
        fprintf(stderr, "menu: initial FBIOPAN_DISPLAY: %s\n", strerror(errno));

    fprintf(stderr, "menu: presented initial screen (highlight=%d, "
                    "pages=%u); waiting on input\n", highlight, n_pages);

    struct input_event ev;
    while (!g_stop) {
        ssize_t n = read(input_fd, &ev, sizeof ev);
        if (n < 0) {
            if (errno == EINTR) continue;
            fprintf(stderr, "menu: read input: %s\n", strerror(errno));
            break;
        }
        if (n != (ssize_t)sizeof ev) continue;
        if (ev.type != EV_KEY || ev.value != 1) continue;  /* press-edge only */

        int new_hl = highlight;
        if (ev.code == KEY_VOLUMEUP)
            new_hl = (highlight + ROW_COUNT - 1) % ROW_COUNT;
        else if (ev.code == KEY_VOLUMEDOWN)
            new_hl = (highlight + 1) % ROW_COUNT;
        else
            continue;

        if (new_hl == highlight) continue;   /* redraw ONLY on state change */
        highlight = new_hl;

        page = (n_pages > 1) ? (page ^ 1u) : 0;
        draw_menu(fbmap + (size_t)page * page_bytes, finfo.line_length,
                  highlight);
        msync(fbmap, map_bytes, MS_SYNC);
        vinfo.xoffset = 0;
        vinfo.yoffset = page * vinfo.yres;
        if (ioctl(fb, FBIOPAN_DISPLAY, &vinfo) < 0)
            fprintf(stderr, "menu: FBIOPAN_DISPLAY: %s "
                            "(screen may lag)\n", strerror(errno));
        fprintf(stderr, "menu: highlight=%d page=%u\n", highlight, page);
    }

    close(input_fd);
    munmap(fbmap, map_bytes);
    close(fb);
    return 0;
}
