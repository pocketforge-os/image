/*
 * pocketforge-boot-animator (bd: tsp-3rd3.4)
 * -----------------------------------------------------------------------------
 * Kernel-handoff fb0 boot animator. Streams the tsp-3rd3.2 48-frame ember-sweep
 * animation to /dev/fb0 at 16 fps: frames 000..015 play ONCE (intro), then
 * frames 016..047 loop seamlessly until SIGTERM. Frame 000 is byte-identical to
 * the u-boot static logo (sha ed689555…), so the u-boot -> animator handoff is
 * seamless by construction.
 *
 * Exit contract (Conflicts=pocketforge-splash-handoff.target): on SIGTERM the
 * animator clears fb0 to black and exits 0, leaving a clean panel for any
 * successor UI. A future kiosk/MainUI wires itself in with
 *   Requires=pocketforge-splash-handoff.target
 *   After=pocketforge-splash-handoff.target
 * and the boot ordering hands off automatically.
 *
 * Framebuffer console (fbcon) is unbound from fb0 at startup so kernel console
 * text cannot bleed through between frames — this is the reason we are
 * retiring pocketforge-fb-clear (which used to hide the noise by zeroing).
 *
 * Streaming-decode: exactly ONE decoded RGBA frame is resident at a time
 * (3.52 MiB), decoded synchronously from the PNG file with a vendored
 * stb_image (single-header, public-domain, no external deps beyond libc).
 * Whole-program RSS steady-state is well under the 20 MiB ceiling.
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
#include <time.h>
#include <unistd.h>

#define STB_IMAGE_IMPLEMENTATION
#define STBI_ONLY_PNG
#define STBI_NO_STDIO
#define STBI_NO_LINEAR
#define STBI_NO_HDR
#include "stb_image.h"

/* Frame set contract (tsp-3rd3.2 / assets/boot-anim/README.md).  If these
 * numbers ever change, update this whole block; the animator's playback
 * schedule keys off them. */
#define FRAME_W       1280
#define FRAME_H       720
#define FRAME_STRIDE  (FRAME_W * 4)   /* 5120: RGBA/BGRA 4 bytes per pixel */
#define FRAME_BYTES   (FRAME_STRIDE * FRAME_H)  /* 3,686,400 = 3.52 MiB */
#define INTRO_FRAMES  16              /* 000..015: play ONCE */
#define LOOP_START    16              /* loop begins here */
#define TOTAL_FRAMES  48              /* 000..047 */
#define TARGET_FPS    16
#define TICK_NS       (1000000000L / TARGET_FPS)

/* Cap on a single PNG file — the whole 48-frame set is 5.5 MiB, so 8 MiB per
 * file is orders of magnitude of headroom against a corrupted asset. */
#define PNG_MAX_BYTES (8 * 1024 * 1024)

static const char *g_frames_dir = "/opt/pocketforge/boot-anim/frames";
static volatile sig_atomic_t g_stop = 0;

static void on_signal(int sig) { (void)sig; g_stop = 1; }

/* Unbind the framebuffer console from fb0 so kernel console messages cannot
 * flash between animation frames.  Best-effort — a kernel built without
 * CONFIG_FRAMEBUFFER_CONSOLE has no vtcon1 to unbind and this is a no-op. */
static void hide_fbcon(void) {
    int fd = open("/sys/class/vtconsole/vtcon1/bind", O_WRONLY | O_CLOEXEC);
    if (fd < 0) return;
    ssize_t n = write(fd, "0\n", 2);
    (void)n;
    close(fd);
}

static long ns_since(const struct timespec *base) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (now.tv_sec - base->tv_sec) * 1000000000L
         + (now.tv_nsec - base->tv_nsec);
}

/* Load a whole file into a caller-owned buffer.  Returns bytes read on success,
 * -1 on error. */
static long slurp(const char *path, unsigned char **out) {
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    off_t sz = lseek(fd, 0, SEEK_END);
    if (sz <= 0 || sz > PNG_MAX_BYTES) { close(fd); return -1; }
    if (lseek(fd, 0, SEEK_SET) != 0) { close(fd); return -1; }
    unsigned char *buf = malloc((size_t)sz);
    if (!buf) { close(fd); return -1; }
    long done = 0;
    while (done < sz) {
        ssize_t n = read(fd, buf + done, (size_t)(sz - done));
        if (n < 0) { if (errno == EINTR) continue; free(buf); close(fd); return -1; }
        if (n == 0) break;
        done += n;
    }
    close(fd);
    *out = buf;
    return done;
}

/* Decode a PNG at `path` to RGBA (8 bpc). On success returns a malloc'd buffer
 * of exactly FRAME_BYTES that the caller must free; on failure returns NULL. */
static unsigned char *decode_frame(unsigned int fidx) {
    char path[256];
    snprintf(path, sizeof(path), "%s/frame-%03u.png", g_frames_dir, fidx);
    unsigned char *raw = NULL;
    long sz = slurp(path, &raw);
    if (sz < 0) return NULL;
    int w = 0, h = 0, comp = 0;
    unsigned char *rgba = stbi_load_from_memory(raw, (int)sz, &w, &h, &comp, 4);
    free(raw);
    if (!rgba) return NULL;
    if (w != FRAME_W || h != FRAME_H) { stbi_image_free(rgba); return NULL; }
    return rgba;
}

/* Blit one RGBA frame to the fb0 mmap, converting to the sunxi DE2.0
 * XRGB8888 memory layout (bytes B,G,R,X per pixel).  fb_stride typically
 * equals FRAME_STRIDE; the per-row path is kept for a hypothetical padded
 * variant of fb0. */
static void blit_bgra(unsigned char *fbmap, unsigned int fb_stride,
                      const unsigned char *rgba) {
    for (int y = 0; y < FRAME_H; y++) {
        const unsigned char *sp = rgba  + (size_t)y * FRAME_STRIDE;
        unsigned char       *dp = fbmap + (size_t)y * fb_stride;
        for (int x = 0; x < FRAME_W; x++) {
            dp[0] = sp[2];   /* B <- R */
            dp[1] = sp[1];   /* G <- G */
            dp[2] = sp[0];   /* R <- B */
            dp[3] = 0xFF;    /* X (opaque; the source is fully-opaque per contract) */
            sp += 4; dp += 4;
        }
    }
}

/* Choose the frame index for tick k under the animator contract:
 *   k in [0, INTRO_FRAMES)         -> frame k                      (intro, once)
 *   k >= INTRO_FRAMES              -> LOOP_START + (k - INTRO_FRAMES) % LOOP_LEN
 *                                                                  (seamless loop)
 */
static unsigned int frame_for_tick(unsigned int k) {
    if (k < INTRO_FRAMES) return k;
    const unsigned int loop_len = TOTAL_FRAMES - LOOP_START;
    return LOOP_START + ((k - INTRO_FRAMES) % loop_len);
}

int main(int argc, char **argv) {
    /* --measure prints per-frame decode/blit timings to stderr (systemd will
     * capture them into the journal). Off by default so a normal boot log
     * stays quiet. */
    int measure = 0;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--measure") == 0) measure = 1;
    }

    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = on_signal;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT,  &sa, NULL);

    hide_fbcon();

    int fb = open("/dev/fb0", O_RDWR | O_CLOEXEC);
    if (fb < 0) {
        fprintf(stderr, "animator: open /dev/fb0: %s\n", strerror(errno));
        return 1;
    }

    struct fb_var_screeninfo vinfo;
    struct fb_fix_screeninfo finfo;
    if (ioctl(fb, FBIOGET_VSCREENINFO, &vinfo) < 0 ||
        ioctl(fb, FBIOGET_FSCREENINFO, &finfo) < 0) {
        fprintf(stderr, "animator: FBIOGET_*SCREENINFO: %s\n", strerror(errno));
        close(fb);
        return 1;
    }
    fprintf(stderr,
            "animator: fb0 %ux%u @%ubpp stride=%u channels R=%u/%u G=%u/%u B=%u/%u A=%u/%u\n",
            vinfo.xres, vinfo.yres, vinfo.bits_per_pixel, finfo.line_length,
            vinfo.red.offset,   vinfo.red.length,
            vinfo.green.offset, vinfo.green.length,
            vinfo.blue.offset,  vinfo.blue.length,
            vinfo.transp.offset, vinfo.transp.length);

    if (vinfo.xres != FRAME_W || vinfo.yres != FRAME_H || vinfo.bits_per_pixel != 32) {
        fprintf(stderr,
                "animator: unexpected fb0 geometry; expected %ux%u @32bpp\n",
                FRAME_W, FRAME_H);
        close(fb);
        return 1;
    }

    /* The full mapping — double-buffered virtual y is common on this SoC.
     * We only ever draw into the first (yres_visible rows) buffer. */
    size_t map_bytes = (size_t)finfo.line_length * vinfo.yres_virtual;
    if (map_bytes == 0) map_bytes = (size_t)finfo.line_length * vinfo.yres;
    unsigned char *fbmap = mmap(NULL, map_bytes, PROT_READ | PROT_WRITE,
                                MAP_SHARED, fb, 0);
    if (fbmap == MAP_FAILED) {
        fprintf(stderr, "animator: mmap fb0: %s\n", strerror(errno));
        close(fb);
        return 1;
    }

    struct timespec t0;
    clock_gettime(CLOCK_MONOTONIC, &t0);

    for (unsigned int k = 0; !g_stop; k++) {
        unsigned int fidx = frame_for_tick(k);

        struct timespec td0; clock_gettime(CLOCK_MONOTONIC, &td0);
        unsigned char *rgba = decode_frame(fidx);
        long decode_ns = ns_since(&td0);

        long blit_ns = 0;
        if (rgba) {
            struct timespec tb0; clock_gettime(CLOCK_MONOTONIC, &tb0);
            blit_bgra(fbmap, finfo.line_length, rgba);
            blit_ns = ns_since(&tb0);
            stbi_image_free(rgba);
        } else {
            fprintf(stderr, "animator: decode failed for frame %u; holding previous\n", fidx);
        }

        if (measure) {
            fprintf(stderr,
                    "animator: tick=%u frame=%u decode=%.2fms blit=%.2fms\n",
                    k, fidx, decode_ns / 1e6, blit_ns / 1e6);
        }

        /* Deadline schedule: wait until (k+1) * TICK_NS since t0. Absolute
         * schedule (not relative) so a single slow decode does not desync
         * the whole animation — the next frame catches up. */
        long target_ns  = (long)(k + 1) * TICK_NS;
        long elapsed_ns = ns_since(&t0);
        long sleep_ns   = target_ns - elapsed_ns;
        if (sleep_ns > 0) {
            struct timespec ts = { sleep_ns / 1000000000L,
                                   sleep_ns % 1000000000L };
            while (!g_stop && nanosleep(&ts, &ts) == -1 && errno == EINTR) {}
        }
    }

    /* Handoff: leave the panel clean-black for the successor UI. */
    memset(fbmap, 0, map_bytes);
    msync(fbmap, map_bytes, MS_SYNC);
    munmap(fbmap, map_bytes);
    close(fb);
    return 0;
}
