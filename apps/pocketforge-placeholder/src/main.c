/*
 * pocketforge-placeholder (bd: tsp-147u.21)
 * -----------------------------------------------------------------------------
 * ⚠ THROWAWAY / PROOF-OF-LIFE ONLY. This is a deliberately MINIMAL placeholder
 * that draws a single STATIC screen so the owned-chain device presents a stable
 * "we're up" panel instead of looping the boot animation forever. It is NOT the
 * product UI: the real launcher/MainUI is a separate future design effort and
 * NOTHING here is meant to be reused (owner ruling 2026-07-17 on tsp-147u.15).
 * No config, no input, no framework — just: draw one screen, hold it.
 *
 * The fb0 handoff from pocketforge-boot-animator.service is done by systemd, not
 * here: this program's unit declares Conflicts=/After=pocketforge-boot-animator
 * on ITSELF, so starting it first STOPS the animator (SIGTERM → the animator
 * clears fb0 to black and exits 0) and only THEN starts us — exactly one fb0
 * writer at all times, no pan-fight (root cause tsp-7kpp). A brief black flash
 * during the handoff is accepted by design (see pocketforge-foreground.target).
 *
 * Pan-to-present (bd: tsp-woy3, mirrored from the animator): on this platform
 * fb0's scan-out is a g2d-ROTATED COPY of fb0 (the panel is portrait-native,
 * fb0 presents landscape), refreshed ONLY on FBIOPAN_DISPLAY. mmap writes alone
 * NEVER reach the panel. So we draw every page, then pan once to present.
 *
 * No external assets, no image decode — the screen is drawn from plain pixel
 * math (charcoal field + an ember-orange framed emblem), so there is nothing to
 * ship or version alongside this binary. libc only.
 */

#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <fcntl.h>
#include <linux/fb.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

/* fb0 geometry contract — identical to the animator's frame set. If the panel
 * ever changes, this whole block (and the animator's) changes together. */
#define FB_W  1280
#define FB_H  720

/* Placeholder palette (RGB). Warm near-black field, PocketForge ember accent. */
#define BG_R  0x14
#define BG_G  0x12
#define BG_B  0x10
#define EM_R  0xE8
#define EM_G  0x62
#define EM_B  0x2A

static volatile sig_atomic_t g_stop = 0;
static void on_signal(int sig) { (void)sig; g_stop = 1; }

/* Unbind the framebuffer console from fb0 so kernel console text cannot bleed
 * onto our static screen. Best-effort (no-op if already unbound by the animator
 * or if the kernel lacks CONFIG_FRAMEBUFFER_CONSOLE). */
static void hide_fbcon(void) {
    int fd = open("/sys/class/vtconsole/vtcon1/bind", O_WRONLY | O_CLOEXEC);
    if (fd < 0) return;
    ssize_t n = write(fd, "0\n", 2);
    (void)n;
    close(fd);
}

/* Write one XRGB8888 pixel (sunxi DE2.0 memory layout: bytes B,G,R,X). */
static inline void put_px(unsigned char *p, unsigned char r,
                          unsigned char g, unsigned char b) {
    p[0] = b; p[1] = g; p[2] = r; p[3] = 0xFF;
}

/* Fill an axis-aligned rect [x0,x1) x [y0,y1) (clipped to the page) with rgb. */
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

/* Paint the whole static placeholder screen into one page. */
static void draw_screen(unsigned char *page, unsigned int stride) {
    /* Field. */
    fill_rect(page, stride, 0, 0, FB_W, FB_H, BG_R, BG_G, BG_B);

    /* Centered ember "frame" emblem: a hollow square drawn as four bars, with a
     * small solid ember square in the middle. Purely a recognizable, obviously
     * static brand cue — the device is up and holding. */
    const int cx = FB_W / 2, cy = FB_H / 2;
    const int half = 190;          /* outer frame is 380x380, centered */
    const int th = 18;             /* bar thickness */
    const int fx0 = cx - half, fy0 = cy - half;
    const int fx1 = cx + half, fy1 = cy + half;
    /* top / bottom bars */
    fill_rect(page, stride, fx0, fy0, fx1, fy0 + th, EM_R, EM_G, EM_B);
    fill_rect(page, stride, fx0, fy1 - th, fx1, fy1, EM_R, EM_G, EM_B);
    /* left / right bars */
    fill_rect(page, stride, fx0, fy0, fx0 + th, fy1, EM_R, EM_G, EM_B);
    fill_rect(page, stride, fx1 - th, fy0, fx1, fy1, EM_R, EM_G, EM_B);
    /* center solid square */
    fill_rect(page, stride, cx - 46, cy - 46, cx + 46, cy + 46, EM_R, EM_G, EM_B);
}

int main(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = on_signal;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT,  &sa, NULL);

    hide_fbcon();

    int fb = open("/dev/fb0", O_RDWR | O_CLOEXEC);
    if (fb < 0) {
        fprintf(stderr, "placeholder: open /dev/fb0: %s\n", strerror(errno));
        return 1;
    }

    struct fb_var_screeninfo vinfo;
    struct fb_fix_screeninfo finfo;
    if (ioctl(fb, FBIOGET_VSCREENINFO, &vinfo) < 0 ||
        ioctl(fb, FBIOGET_FSCREENINFO, &finfo) < 0) {
        fprintf(stderr, "placeholder: FBIOGET_*SCREENINFO: %s\n", strerror(errno));
        close(fb);
        return 1;
    }
    if (vinfo.xres != FB_W || vinfo.yres != FB_H || vinfo.bits_per_pixel != 32) {
        fprintf(stderr, "placeholder: unexpected fb0 geometry %ux%u @%ubpp; "
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
        fprintf(stderr, "placeholder: mmap fb0: %s\n", strerror(errno));
        close(fb);
        return 1;
    }

    const unsigned int n_pages =
        (vinfo.yres_virtual >= 2 * vinfo.yres) ? 2 : 1;

    /* Draw the identical static screen into every page, then pan to the last
     * one — a single present is enough since nothing changes after this. */
    for (unsigned int p = 0; p < n_pages; p++)
        draw_screen(fbmap + (size_t)p * page_bytes, finfo.line_length);
    msync(fbmap, map_bytes, MS_SYNC);

    vinfo.xoffset = 0;
    vinfo.yoffset = (n_pages - 1) * vinfo.yres;   /* yoffset change forces the g2d-rot refresh */
    if (ioctl(fb, FBIOPAN_DISPLAY, &vinfo) < 0)
        fprintf(stderr, "placeholder: FBIOPAN_DISPLAY: %s "
                "(screen may not reach the panel)\n", strerror(errno));

    fprintf(stderr, "placeholder: static screen presented (%u page(s)); holding\n",
            n_pages);

    /* Hold the screen until the unit is stopped. There is nothing to animate —
     * the panel keeps scanning out the presented page while we sleep. */
    while (!g_stop) pause();

    munmap(fbmap, map_bytes);
    close(fb);
    return 0;
}
