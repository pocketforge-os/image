/*
 * pocketforge-menu (bd: tsp-ga7s.1)
 * -----------------------------------------------------------------------------
 * MVP static launcher. Three HARDCODED rows — "Button Tester", "Steam Link",
 * "poolside.fm". LRADC volume keys navigate (KEY_VOLUMEUP → up, KEY_VOLUMEDOWN
 * → down, wrapping); the gamepad A button (BTN_SOUTH) selects. Highlight
 * inverts the selected row (charcoal-on-ember). Redraw ONLY on state change.
 *
 * fb0 handoff from pocketforge-boot-animator.service is done by systemd (this
 * unit declares Conflicts=/After= on ITSELF, per the reliable direction proven
 * by tsp-ikk0.11) — exactly one fb0 writer, no pan-fight (root cause tsp-7kpp).
 *
 * Selecting a row (bd: tsp-1cl7.1) hands the panel to the row's command through
 * that SAME seam — see launch_in_foreground_slot() for why it is systemd-run
 * and not a bare fork+exec. The menu does not manage the app's lifetime and
 * does not resume: systemd stops us, and restores us on the app's exit.
 *
 * Pan-to-present (tsp-woy3): fb0's scan-out is a g2d-rotated copy of fb0 that
 * refreshes ONLY on FBIOPAN_DISPLAY, so we redraw the inactive page and pan.
 *
 * Font: 8x16 monospace bitmap, hand-crafted for the ~22 glyphs the three
 * labels use plus space and '.'. Rendered at scale 4 → 32x64 per glyph, plenty
 * readable on the 1280x720 landscape panel. libc only — no freetype/harfbuzz.
 */

#define _GNU_SOURCE           /* ppoll(2) */
#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <fcntl.h>
#include <linux/fb.h>
#include <linux/input.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/wait.h>
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

/* Command launched when a row is selected; NULL = nothing configured yet.
 *
 * HONEST STATE OF THE CATALOGUE (bd: tsp-1cl7.1): none of the three labelled
 * apps exists — there is no button-tester, Steam Link or poolside.fm binary
 * anywhere in this repo or in pocketforge-os/runtime. This bead is about the
 * LAUNCH MECHANISM, not the catalogue, so rows 1 and 2 are deliberately left
 * unconfigured (pressing A logs and does nothing) rather than pointed at a
 * binary that has nothing to do with their label.
 *
 * Row 0 launches pocketforge-placeholder purely as a STAND-IN: it is the one
 * display app installed on every image variant (build-rootfs.sh keeps it as
 * one-symlink-swap recovery), it is libc-only, it draws a screen visually
 * distinct from this menu and PANS it (so it is actually visible, tsp-woy3),
 * and it exits 0 on SIGTERM. It holds the panel until its transient unit is
 * stopped. On a dev image, testgles2 --quit-after-ms is the self-exiting
 * alternative and is also the mandated boot-lottery positive control; it is
 * not wired here because it does not exist on a stock image. */
static const char *const COMMANDS[ROW_COUNT] = {
    "/opt/pocketforge/bin/pocketforge-placeholder",
    NULL,
    NULL,
};

static volatile sig_atomic_t g_stop = 0;
static void on_signal(int sig) { (void)sig; g_stop = 1; }

/* Signal mask in force before we blocked SIGTERM/SIGINT — handed to ppoll(2)
 * during the wait, and restored in a forked child before exec so nothing we
 * launch inherits a blocked SIGTERM. */
static sigset_t g_prev_mask;

/* Hand the panel to `cmd` through the pocketforge-foreground.target seam.
 *
 * NOT a bare fork+exec, deliberately: a plain fork leaves the app inside
 * pocketforge-menu.service's cgroup (which carries MemoryMax=16M), so the very
 * act of stopping this menu would kill the app it just launched. systemd-run
 * puts the app in its OWN transient unit, outside our cgroup, joined to the
 * seam with the same two properties /usr/bin/pf-take-panel uses. Activating
 * that target Conflicts-stops US first and After= orders the app behind our
 * stop, so fb0 keeps exactly one writer (tsp-ikk0.11 / tsp-7kpp). The menu
 * therefore has no waitpid, no fb0 suspend/resume and no crash-vs-clean-exit
 * logic: OnSuccess= on the target restores the previous owner.
 *
 * --no-block is REQUIRED, not an optimisation. Without it systemd-run waits
 * for the start job to finish — and that job is ordered BEHIND our own stop,
 * so we would be blocking on a job that cannot complete until we exit. Enqueue
 * and return; the D-Bus call has already created the job by the time we do.
 *
 * pf-take-panel is the sibling MANUAL/HIL path (--pipe, synchronous, forwards
 * stdio to the caller). It is left untouched: piping an app's stdio through a
 * process systemd is about to stop is not what a launcher wants. */
static void launch_in_foreground_slot(const char *cmd) {
    fprintf(stderr, "menu: launching %s via pocketforge-foreground.target\n", cmd);

    pid_t pid = fork();
    if (pid < 0) {
        fprintf(stderr, "menu: fork: %s\n", strerror(errno));
        return;
    }
    if (pid == 0) {
        sigprocmask(SIG_SETMASK, &g_prev_mask, NULL);
        execl("/usr/bin/systemd-run", "systemd-run",
              "--collect", "--quiet", "--no-block",
              "--property=Requires=pocketforge-foreground.target",
              "--property=After=pocketforge-foreground.target",
              "--", cmd, (char *)NULL);
        fprintf(stderr, "menu: exec systemd-run: %s\n", strerror(errno));
        _exit(127);
    }

    /* Reap the short-lived systemd-run client (--no-block returns as soon as
     * the transient unit is enqueued). We never wait on the APP. */
    int status = 0;
    if (waitpid(pid, &status, 0) != pid)
        fprintf(stderr, "menu: waitpid: %s\n", strerror(errno));
    else if (!WIFEXITED(status) || WEXITSTATUS(status) != 0)
        fprintf(stderr, "menu: launch of %s failed (systemd-run status %d); "
                        "staying on the menu\n", cmd, status);
}

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

static int has_key(const uint8_t *keybits, unsigned int code) {
    return (keybits[code / 8] >> (code % 8)) & 1u;
}

/* Scan /dev/input/event0..event15 ONCE and pick, BY CAPABILITY, the node that
 * reports KEY_VOLUMEUP (the LRADC nav keys) and the node that reports
 * BTN_SOUTH (the gamepad A/confirm button). On this device those are two
 * DIFFERENT nodes, and evdev numbering shifts across boots with probe order
 * (SD hotplug etc.), so neither index may ever be hard-coded.
 *
 * If one node happens to report both, it is opened ONCE and both roles share
 * the fd — two fds on the same node would deliver every event twice.
 *
 * Sets *nav_fd and/or *sel_fd to -1 when nothing advertises that capability;
 * the caller decides what is fatal. Nav keeps the historical
 * /dev/input/event0 fallback; select has none, because launching the wrong
 * thing on a stray keycode is worse than having no select. */
static void open_inputs(int *nav_fd, int *sel_fd) {
    *nav_fd = -1;
    *sel_fd = -1;

    for (int i = 0; i < 16 && (*nav_fd < 0 || *sel_fd < 0); i++) {
        char path[32];
        snprintf(path, sizeof path, "/dev/input/event%d", i);
        int fd = open(path, O_RDONLY | O_CLOEXEC);
        if (fd < 0) continue;

        uint8_t keybits[(KEY_MAX + 7) / 8];
        memset(keybits, 0, sizeof keybits);
        if (ioctl(fd, EVIOCGBIT(EV_KEY, sizeof keybits), keybits) < 0) {
            close(fd);
            continue;
        }

        int want_nav = (*nav_fd < 0) && has_key(keybits, KEY_VOLUMEUP);
        int want_sel = (*sel_fd < 0) && has_key(keybits, BTN_SOUTH);

        if (want_nav && want_sel) {
            fprintf(stderr, "menu: nav+select via %s (one node)\n", path);
            *nav_fd = fd;
            *sel_fd = fd;
        } else if (want_nav) {
            fprintf(stderr, "menu: nav (KEY_VOLUMEUP) via %s\n", path);
            *nav_fd = fd;
        } else if (want_sel) {
            fprintf(stderr, "menu: select (BTN_SOUTH) via %s\n", path);
            *sel_fd = fd;
        } else {
            close(fd);
        }
    }
    if (*nav_fd < 0) {
        *nav_fd = open("/dev/input/event0", O_RDONLY | O_CLOEXEC);
        if (*nav_fd >= 0)
            fprintf(stderr, "menu: no VOLUMEUP-capable device found; "
                            "falling back to /dev/input/event0\n");
    }
    if (*sel_fd < 0)
        fprintf(stderr, "menu: no BTN_SOUTH-capable device found; "
                        "navigation only, select disabled\n");
}

int main(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = on_signal;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT,  &sa, NULL);

    /* Block SIGTERM/SIGINT and hand the ORIGINAL mask to ppoll(2) below.
     * A plain poll()/read() has a lost-wakeup race: a SIGTERM delivered
     * between the `!g_stop` test and entering the syscall sets g_stop, then
     * the syscall blocks anyway — and the menu sits there until the next
     * input event. That matters exactly when the seam wants a fast hand-off:
     * pocketforge-menu.service has TimeoutStopSec=2s, so a menu that only
     * notices SIGTERM on the next keypress gets SIGKILLed 2s into a handoff
     * the launched app is ordered behind. ppoll's atomic mask swap closes the
     * window: the signal stays pending while we are outside the syscall and
     * is delivered the instant we enter it, returning EINTR. */
    sigset_t block_mask;
    sigemptyset(&block_mask);
    sigaddset(&block_mask, SIGTERM);
    sigaddset(&block_mask, SIGINT);
    sigprocmask(SIG_BLOCK, &block_mask, &g_prev_mask);

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

    int nav_fd = -1, sel_fd = -1;
    open_inputs(&nav_fd, &sel_fd);
    if (nav_fd < 0) {
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

    /* Poll set: nav, plus select when it is a DISTINCT node (a shared node is
     * listed once — polling the same fd twice would double-handle events). */
    struct pollfd pfds[2];
    nfds_t nfds = 0;
    pfds[nfds].fd = nav_fd; pfds[nfds].events = POLLIN; nfds++;
    if (sel_fd >= 0 && sel_fd != nav_fd) {
        pfds[nfds].fd = sel_fd; pfds[nfds].events = POLLIN; nfds++;
    }

    while (!g_stop) {
        if (ppoll(pfds, nfds, NULL, &g_prev_mask) < 0) {
            if (errno == EINTR) continue;   /* re-tests !g_stop; see above */
            fprintf(stderr, "menu: ppoll: %s\n", strerror(errno));
            break;
        }

        int new_hl = highlight;
        int selected = 0;
        int fatal = 0;

        for (nfds_t i = 0; i < nfds && !fatal; i++) {
            if (!(pfds[i].revents & (POLLIN | POLLERR | POLLHUP)))
                continue;
            if (pfds[i].revents & (POLLERR | POLLHUP)) {
                fprintf(stderr, "menu: input fd %d hung up\n", pfds[i].fd);
                fatal = 1;
                break;
            }

            struct input_event ev;
            ssize_t n = read(pfds[i].fd, &ev, sizeof ev);
            if (n < 0) {
                if (errno == EINTR || errno == EAGAIN) continue;
                fprintf(stderr, "menu: read input: %s\n", strerror(errno));
                fatal = 1;
                break;
            }
            if (n != (ssize_t)sizeof ev) continue;
            if (ev.type != EV_KEY || ev.value != 1) continue; /* press-edge only */

            if (ev.code == KEY_VOLUMEUP)
                new_hl = (new_hl + ROW_COUNT - 1) % ROW_COUNT;
            else if (ev.code == KEY_VOLUMEDOWN)
                new_hl = (new_hl + 1) % ROW_COUNT;
            else if (ev.code == BTN_SOUTH)
                selected = 1;
        }
        if (fatal) break;

        /* Select acts on the highlight as it stood when A was pressed. */
        if (selected) {
            const char *cmd = COMMANDS[highlight];
            if (cmd) {
                launch_in_foreground_slot(cmd);
                /* Nothing to resume: starting the app activates
                 * pocketforge-foreground.target, which Conflicts-stops this
                 * unit. We keep serving input until that SIGTERM lands. */
            } else {
                fprintf(stderr, "menu: row %d (\"%s\") has no command "
                                "configured\n", highlight, LABELS[highlight]);
            }
            continue;
        }

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

    /* Handoff: leave the panel clean-black for the successor, the same exit
     * contract the boot animator already honours. Clear every page, then pan
     * to a DIFFERENT yoffset so the black actually propagates through the
     * g2d-rot scan-out (a bare memset is invisible — tsp-woy3).
     *
     * This is load-bearing for diagnosis, not cosmetics: without it the last
     * menu frame stays on the panel after we exit, so "the app never
     * presented" is indistinguishable from "the app never launched" — the
     * exact ambiguity that burned an owner actuation window on 2026-07-27. A
     * brief black flash at handoff is accepted by the tsp-ikk0.11 design. */
    memset(fbmap, 0, map_bytes);
    msync(fbmap, map_bytes, MS_SYNC);
    vinfo.xoffset = 0;
    vinfo.yoffset = (n_pages > 1) ? ((page ^ 1u) * vinfo.yres) : 0;
    if (ioctl(fb, FBIOPAN_DISPLAY, &vinfo) < 0)
        fprintf(stderr, "menu: handoff FBIOPAN_DISPLAY: %s\n", strerror(errno));

    if (sel_fd >= 0 && sel_fd != nav_fd) close(sel_fd);
    close(nav_fd);
    munmap(fbmap, map_bytes);
    close(fb);
    return 0;
}
