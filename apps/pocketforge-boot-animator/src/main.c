/*
 * pocketforge-boot-animator (bd: tsp-3rd3.4; open-7.x port: tsp-3rd3.6)
 * -----------------------------------------------------------------------------
 * Boot animator for /dev/fb0. Streams the tsp-3rd3.2 48-frame ember-sweep
 * animation at 16 fps: frames 000..015 play ONCE (intro), then frames
 * 016..047 loop seamlessly until SIGTERM. The logical scene is always
 * 1280x720; frame 000 is byte-identical to the u-boot static logo
 * (sha ed689555...).
 *
 * Two presentation paths, selected by what fb0 IS, never by its geometry:
 *
 *  - DRM fbdev emulation (open 7.x kernel). The kernel names such an fb
 *    "<driver>drmfb" and documents that name as uAPI (kernel-sunxi-7.x
 *    drm_fb_helper.c:1627-1634). The buffer is in native panel coordinates
 *    (720x1280 on the TSP), so the scene is rotated in software by the
 *    connector's "panel orientation" property, with the kernel's own meaning
 *    of that property (table k_orientations below). If the orientation
 *    cannot be read, NOTHING is painted and the animator exits 0: a guessed
 *    rotation is how a silent 180-degree flip ships.
 *
 *  - Legacy fbdev (vendor 4.9 disp2). fb0 is already landscape 1280x720 and
 *    its driver presents it through a g2d-rotated copy refreshed only on
 *    FBIOPAN_DISPLAY (bd tsp-woy3). This path is today's behaviour: blit the
 *    back page, pan to it, alternating pages. The fb bytes presented at every
 *    pan are identical to the pre-port animator (hermetic test).
 *
 * Cost (design note section 1.3): only 8.9 % of the scene changes after
 * frame 000. The image build crops frames 001..047 to that one rectangle
 * (tools/crop_frames.py; the rectangle's position rides a PNG oFFs chunk), so
 * after painting frame 000 in full once, each tick decodes and blits only the
 * rectangle. Uncropped frames still work (they are treated as full-scene
 * regions).
 *
 * Exit contract: SIGTERM/SIGINT HOLD the last presented frame (no clear, no
 * pan), munmap and exit 0. The successor (MainUI, a foreground app, the
 * menu) overwrites the whole buffer on its first present, so the panel goes
 * splash -> successor with no black gap (design note section 3.5; supersedes
 * the tsp-3rd3.4 clear-to-black contract, docs/FB0-CONTRACT.md).
 *
 * --first-frame: resolve orientation, unbind fbcon, paint frame 000, emit the
 * marker, exit 0. For the initrd first-light helper (bd tsp-3rd3.7).
 * --measure:     per-tick decode/blit timing plus a CPU/RSS summary on exit.
 * --frames-dir D: read frame-NNN.png from D instead of the installed set.
 *
 * After frame 000 first reaches the buffer, ONE line goes to /dev/kmsg:
 *   pf-boot-splash: first-frame presented src=<animator|first-frame> ...
 * (kernel clock; the tsp-3rd3.9 boot-splash harness keys the lit-black gap on
 * it).
 *
 * Only libc/libm are used, and every path goes through open/read/write/ioctl/
 * mmap, so the binary links statically for the initrd and the hermetic tests
 * can interpose those calls (tests/fakefb.c) without a single test hook here.
 */

#define _POSIX_C_SOURCE 200809L
#define _DEFAULT_SOURCE

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
#include <sys/resource.h>
#include <time.h>
#include <unistd.h>

#include <drm/drm.h>
#include <drm/drm_mode.h>

#define STB_IMAGE_IMPLEMENTATION
#define STBI_ONLY_PNG
#define STBI_NO_STDIO
#define STBI_NO_LINEAR
#define STBI_NO_HDR
#include "stb_image.h"

/* Frame set contract (tsp-3rd3.2 / assets/boot-anim/README.md). */
#define SCENE_W       1280
#define SCENE_H       720
#define INTRO_FRAMES  16              /* 000..015: play ONCE */
#define LOOP_START    16              /* loop begins here */
#define TOTAL_FRAMES  48              /* 000..047 */
#define TARGET_FPS    16
#define TICK_NS       (1000000000L / TARGET_FPS)

/* Cap on a single PNG file: the whole 48-frame set is 5.5 MiB. */
#define PNG_MAX_BYTES (8 * 1024 * 1024)

#define FB_PATH            "/dev/fb0"
#define DRM_CARD_PATH      "/dev/dri/card0"
#define FBCON_ROTATE_PATH  "/sys/class/graphics/fbcon/rotate"
#define VTCON_PATH_FMT     "/sys/class/vtconsole/vtcon%d/%s"
#define VTCON_MAX          16         /* MAX_NR_CON_DRIVER */
#define FBCON_VTCON_NAME   "frame buffer device"
#define KMSG_PATH          "/dev/kmsg"
#define DRM_MAX_CONNECTORS 16
#define DRM_MAX_PROPS      64
#define DRM_MAX_ENUMS      16

static const char *g_frames_dir = "/opt/pocketforge/boot-anim/frames";
static volatile sig_atomic_t g_stop = 0;

static void on_signal(int sig) { (void)sig; g_stop = 1; }

/* ---- orientation: the kernel's table, nothing local ----------------------
 *
 * Scene (u,v), u in [0,SCENE_W), v in [0,SCENE_H), maps to buffer (x,y):
 *
 *  property value (drm_connector.c:1241-1244)  drm_client_rotation   fbcon hint           buffer (x, y)
 *  "Normal"        PANEL_ORIENTATION_NORMAL     ROTATE_0   (:981-982) FB_ROTATE_UR  (:1683) (u, v)
 *  "Upside Down"   PANEL_ORIENTATION_BOTTOM_UP  ROTATE_180 (:972-973) FB_ROTATE_UD  (:1689) (W-1-u, H-1-v)
 *  "Left Side Up"  PANEL_ORIENTATION_LEFT_UP    ROTATE_90  (:975-976) FB_ROTATE_CCW (:1686) (v, W-1-u)
 *  "Right Side Up" PANEL_ORIENTATION_RIGHT_UP   ROTATE_270 (:978-979) FB_ROTATE_CW  (:1692) (H-1-v, u)
 *
 * (drm_client_modeset.c:971-983 and drm_fb_helper.c:1682-1702 at
 * kernel-sunxi-7.x@03822b3f.) DRM_MODE_ROTATE_<n> is counter-clockwise
 * (uapi drm_mode.h:159-163). The buffer column is exactly where fbcon draws
 * the same console cell: fbcon_ccw.c:150-151 puts console row r at
 * x = r*font_h and column c at y = vyres - (c+1)*font_w (content top on the
 * native LEFT edge, which is the documented meaning of LEFT_UP,
 * drm_connector.h:369-370); fbcon_cw.c:135-136 and fbcon_ud.c:172-173
 * likewise for the other two. The tests check every pixel against those
 * fbcon formulas.
 */
enum rot { ROT_0 = 0, ROT_90 = 1, ROT_180 = 2, ROT_270 = 3 };

struct orientation_row {
    const char *prop_name;   /* connector "panel orientation" enum name */
    unsigned fbcon_rotate;   /* /sys/class/graphics/fbcon/rotate value */
    enum rot rot;
    const char *rot_name;
};

static const struct orientation_row k_orientations[] = {
    { "Normal",        FB_ROTATE_UR,  ROT_0,   "ROTATE_0"   },
    { "Upside Down",   FB_ROTATE_UD,  ROT_180, "ROTATE_180" },
    { "Left Side Up",  FB_ROTATE_CCW, ROT_90,  "ROTATE_90"  },
    { "Right Side Up", FB_ROTATE_CW,  ROT_270, "ROTATE_270" },
};
#define N_ORIENTATIONS (sizeof(k_orientations) / sizeof(k_orientations[0]))

struct orientation {
    const struct orientation_row *row;  /* NULL: unknown -> do not paint */
    const char *source;                 /* drm-connector | fbcon | legacy-fbdev */
    char why[160];                      /* human reason when row == NULL */
};

static long ns_since(const struct timespec *base) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (now.tv_sec - base->tv_sec) * 1000000000L
         + (now.tv_nsec - base->tv_nsec);
}

/* Read a small text file (sysfs attribute). Returns bytes read, -1 on error. */
static ssize_t read_small(const char *path, char *buf, size_t cap) {
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    ssize_t n;
    do { n = read(fd, buf, cap - 1); } while (n < 0 && errno == EINTR);
    close(fd);
    if (n < 0) return -1;
    buf[n] = '\0';
    return n;
}

static int drm_ioctl(int fd, unsigned long req, void *arg) {
    int r;
    do { r = ioctl(fd, req, arg); } while (r == -1 && (errno == EINTR || errno == EAGAIN));
    return r;
}

/* Read one connector's status and "panel orientation" value. Returns 0 and
 * sets *status and *row (NULL when the property is absent), -1 on error. */
static int read_connector(int fd, uint32_t id, uint32_t *status,
                          const struct orientation_row **row, char *why, size_t whylen) {
    /* count_modes = 1 with a scratch mode: never request the forced probe a
     * zero count asks for (drm_connector.c drm_mode_getconnector). */
    struct drm_mode_modeinfo scratch_mode;
    uint32_t prop_ids[DRM_MAX_PROPS];
    uint64_t prop_vals[DRM_MAX_PROPS];
    struct drm_mode_get_connector conn;
    memset(&conn, 0, sizeof(conn));
    conn.connector_id = id;
    conn.count_modes = 1;
    conn.modes_ptr = (uint64_t)(uintptr_t)&scratch_mode;
    conn.count_props = DRM_MAX_PROPS;
    conn.props_ptr = (uint64_t)(uintptr_t)prop_ids;
    conn.prop_values_ptr = (uint64_t)(uintptr_t)prop_vals;
    if (drm_ioctl(fd, DRM_IOCTL_MODE_GETCONNECTOR, &conn) < 0) {
        snprintf(why, whylen, "DRM_IOCTL_MODE_GETCONNECTOR %u: %s", id, strerror(errno));
        return -1;
    }
    *status = conn.connection;
    *row = NULL;
    uint32_t n_props = conn.count_props;
    if (n_props > DRM_MAX_PROPS) n_props = DRM_MAX_PROPS;
    for (uint32_t p = 0; p < n_props; p++) {
        struct drm_mode_get_property prop;
        memset(&prop, 0, sizeof(prop));
        prop.prop_id = prop_ids[p];
        if (drm_ioctl(fd, DRM_IOCTL_MODE_GETPROPERTY, &prop) < 0) continue;
        prop.name[DRM_PROP_NAME_LEN - 1] = '\0';
        if (strcmp(prop.name, "panel orientation") != 0) continue;
        if (!(prop.flags & DRM_MODE_PROP_ENUM) ||
            prop.count_enum_blobs == 0 || prop.count_enum_blobs > DRM_MAX_ENUMS) {
            snprintf(why, whylen, "connector %u: \"panel orientation\" is not a known enum", id);
            return -1;
        }
        struct drm_mode_property_enum enums[DRM_MAX_ENUMS];
        uint32_t n_enum = prop.count_enum_blobs;
        memset(&prop, 0, sizeof(prop));
        prop.prop_id = prop_ids[p];
        prop.count_enum_blobs = n_enum;
        prop.enum_blob_ptr = (uint64_t)(uintptr_t)enums;
        if (drm_ioctl(fd, DRM_IOCTL_MODE_GETPROPERTY, &prop) < 0) {
            snprintf(why, whylen, "DRM_IOCTL_MODE_GETPROPERTY %u: %s", prop_ids[p], strerror(errno));
            return -1;
        }
        if (prop.count_enum_blobs < n_enum) n_enum = prop.count_enum_blobs;
        for (uint32_t e = 0; e < n_enum; e++) {
            if (enums[e].value != prop_vals[p]) continue;
            enums[e].name[DRM_PROP_NAME_LEN - 1] = '\0';
            for (size_t k = 0; k < N_ORIENTATIONS; k++)
                if (strcmp(enums[e].name, k_orientations[k].prop_name) == 0)
                    *row = &k_orientations[k];
            if (!*row) {
                snprintf(why, whylen, "connector %u: unknown panel orientation \"%s\"",
                         id, enums[e].name);
                return -1;
            }
        }
        if (!*row) {
            snprintf(why, whylen, "connector %u: panel orientation value %llu has no enum name",
                     id, (unsigned long long)prop_vals[p]);
            return -1;
        }
    }
    return 0;
}

/* Read the "panel orientation" of the connector(s) the kernel's own fbdev
 * client would enable: the connected ones, or the status-unknown ones when
 * none is connected (drm_client_modeset.c drm_client_connectors_enabled).
 * card0 is opened read-only and closed before returning; the caller paints
 * only afterwards. Returns 1 with *out set, 0 when the kernel exposes no
 * usable value (no property means DRM_MODE_PANEL_ORIENTATION_UNKNOWN,
 * drm_connector.h:359-363), -1 when card0 cannot be read. */
static int read_drm_orientation(const struct orientation_row **out, char *why, size_t whylen) {
    int fd = open(DRM_CARD_PATH, O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        snprintf(why, whylen, "open %s: %s", DRM_CARD_PATH, strerror(errno));
        return -1;
    }
    int ret = 0;
    uint32_t conn_ids[DRM_MAX_CONNECTORS];
    uint32_t statuses[DRM_MAX_CONNECTORS];
    const struct orientation_row *rows[DRM_MAX_CONNECTORS];

    struct drm_mode_card_res res;
    memset(&res, 0, sizeof(res));
    res.count_connectors = DRM_MAX_CONNECTORS;
    res.connector_id_ptr = (uint64_t)(uintptr_t)conn_ids;
    if (drm_ioctl(fd, DRM_IOCTL_MODE_GETRESOURCES, &res) < 0) {
        snprintf(why, whylen, "DRM_IOCTL_MODE_GETRESOURCES: %s", strerror(errno));
        ret = -1;
        goto out;
    }
    uint32_t n_conn = res.count_connectors;
    if (n_conn > DRM_MAX_CONNECTORS) n_conn = DRM_MAX_CONNECTORS;

    unsigned n_connected = 0, n_unknown = 0;
    for (uint32_t i = 0; i < n_conn; i++) {
        if (read_connector(fd, conn_ids[i], &statuses[i], &rows[i], why, whylen) < 0) {
            ret = -1;
            goto out;
        }
        if (statuses[i] == 1 /* DRM_MODE_CONNECTED */) n_connected++;
        else if (statuses[i] == 3 /* DRM_MODE_UNKNOWNCONNECTION */) n_unknown++;
    }
    const uint32_t want = n_connected ? 1 : 3;
    const struct orientation_row *found = NULL;
    int conflict = 0;
    unsigned n_considered = 0;
    for (uint32_t i = 0; i < n_conn; i++) {
        if (statuses[i] != want) continue;
        n_considered++;
        if (!rows[i]) continue;
        if (found && found != rows[i]) conflict = 1;
        found = rows[i];
    }
    if (conflict) {
        snprintf(why, whylen, "enabled connectors disagree on panel orientation");
    } else if (!found) {
        snprintf(why, whylen, "no \"panel orientation\" on %u %s connector(s) of %u",
                 n_considered, want == 1 ? "connected" : "status-unknown", n_conn);
    } else {
        *out = found;
        ret = 1;
    }
out:
    close(fd);
    return ret;
}

/* Find the vtconsole driven by fbcon, by name, not by index. Returns the
 * vtcon index or -1; *bound is its bind state (1/0) when found. */
static int find_fbcon_vtcon(int *bound) {
    char path[96], buf[96];
    for (int i = 0; i < VTCON_MAX; i++) {
        snprintf(path, sizeof(path), VTCON_PATH_FMT, i, "name");
        if (read_small(path, buf, sizeof(buf)) < 0) continue;
        if (!strstr(buf, FBCON_VTCON_NAME)) continue;
        snprintf(path, sizeof(path), VTCON_PATH_FMT, i, "bind");
        if (read_small(path, buf, sizeof(buf)) < 0) return -1;
        *bound = (buf[0] == '1');
        return i;
    }
    return -1;
}

/* fbcon's rotation is derived from the same connector property
 * (drm_fb_helper.c:1682-1702), but rotate_show reports 0 whenever fbcon is
 * not bound to a framebuffer: a default, not a reading. So it counts only
 * while the fbcon vtconsole is bound. */
static int read_fbcon_orientation(const struct orientation_row **out, char *why, size_t whylen) {
    int bound = 0;
    int vt = find_fbcon_vtcon(&bound);
    if (vt < 0) {
        snprintf(why, whylen, "no \"%s\" vtconsole", FBCON_VTCON_NAME);
        return -1;
    }
    if (!bound) {
        snprintf(why, whylen, "fbcon (vtcon%d) is not bound, so %s is not a reading",
                 vt, FBCON_ROTATE_PATH);
        return -1;
    }
    char buf[32];
    if (read_small(FBCON_ROTATE_PATH, buf, sizeof(buf)) < 0) {
        snprintf(why, whylen, "read %s: %s", FBCON_ROTATE_PATH, strerror(errno));
        return -1;
    }
    char *end = NULL;
    long v = strtol(buf, &end, 10);
    if (end == buf || (*end != '\0' && *end != '\n')) {
        snprintf(why, whylen, "%s: unparsable \"%.16s\"", FBCON_ROTATE_PATH, buf);
        return -1;
    }
    for (size_t k = 0; k < N_ORIENTATIONS; k++) {
        if ((long)k_orientations[k].fbcon_rotate == v) {
            *out = &k_orientations[k];
            return 1;
        }
    }
    snprintf(why, whylen, "%s: out-of-range value %ld", FBCON_ROTATE_PATH, v);
    return -1;
}

static void resolve_drm_orientation(struct orientation *o) {
    char why_drm[160] = "", why_fbcon[160] = "";
    const struct orientation_row *row = NULL;
    memset(o, 0, sizeof(*o));
    if (read_drm_orientation(&row, why_drm, sizeof(why_drm)) == 1) {
        o->row = row;
        o->source = "drm-connector";
        return;
    }
    if (read_fbcon_orientation(&row, why_fbcon, sizeof(why_fbcon)) == 1) {
        o->row = row;
        o->source = "fbcon";
        return;
    }
    snprintf(o->why, sizeof(o->why), "drm: %s; fbcon: %s", why_drm, why_fbcon);
}

/* Unbind fbcon from the framebuffer, found by vtconsole name, so console text
 * cannot bleed through. Called only after the orientation has been read. */
static void hide_fbcon(void) {
    int bound = 0;
    int vt = find_fbcon_vtcon(&bound);
    if (vt < 0 || !bound) return;
    char path[96];
    snprintf(path, sizeof(path), VTCON_PATH_FMT, vt, "bind");
    int fd = open(path, O_WRONLY | O_CLOEXEC);
    if (fd < 0) {
        fprintf(stderr, "animator: unbind fbcon vtcon%d: %s\n", vt, strerror(errno));
        return;
    }
    ssize_t n = write(fd, "0\n", 2);
    if (n != 2)
        fprintf(stderr, "animator: unbind fbcon vtcon%d: %s\n", vt,
                n < 0 ? strerror(errno) : "short write");
    close(fd);
}

/* ---- frames ------------------------------------------------------------- */

struct frame {
    unsigned char *rgba;   /* w*h*4, stbi-allocated */
    unsigned w, h;         /* region size */
    unsigned ox, oy;       /* region origin in the scene */
};

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

static uint32_t be32(const unsigned char *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3];
}

/* Find an oFFs chunk (pixel units) before the image data. Returns 1 found,
 * 0 absent, -1 malformed. */
static int png_offset(const unsigned char *png, long len, unsigned *ox, unsigned *oy) {
    static const unsigned char sig[8] = { 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n' };
    if (len < 8 || memcmp(png, sig, 8) != 0) return -1;
    long pos = 8;
    while (pos + 12 <= len) {
        uint32_t clen = be32(png + pos);
        const unsigned char *type = png + pos + 4;
        if (clen > (uint32_t)(len - pos - 12)) return -1;
        if (memcmp(type, "IDAT", 4) == 0 || memcmp(type, "IEND", 4) == 0) return 0;
        if (memcmp(type, "oFFs", 4) == 0) {
            const unsigned char *d = png + pos + 8;
            if (clen != 9 || d[8] != 0) return -1;          /* unit 0 = pixel */
            int32_t x = (int32_t)be32(d), y = (int32_t)be32(d + 4);
            if (x < 0 || y < 0) return -1;
            *ox = (unsigned)x;
            *oy = (unsigned)y;
            return 1;
        }
        pos += 12 + (long)clen;
    }
    return -1;
}

/* Decode frame fidx. Frame 000 must be the full scene; any other frame may be
 * a cropped region (oFFs) or a full scene. Returns 0 on success. */
static int decode_frame(unsigned fidx, struct frame *f) {
    char path[512];
    snprintf(path, sizeof(path), "%s/frame-%03u.png", g_frames_dir, fidx);
    unsigned char *raw = NULL;
    long sz = slurp(path, &raw);
    if (sz < 0) return -1;
    unsigned ox = 0, oy = 0;
    int has_offs = png_offset(raw, sz, &ox, &oy);
    int w = 0, h = 0, comp = 0;
    unsigned char *rgba = has_offs < 0 ? NULL
                        : stbi_load_from_memory(raw, (int)sz, &w, &h, &comp, 4);
    free(raw);
    if (!rgba) return -1;
    if (has_offs == 0) {
        if (w != SCENE_W || h != SCENE_H) { stbi_image_free(rgba); return -1; }
        ox = oy = 0;
    } else if (fidx == 0 || w <= 0 || h <= 0 ||
               ox > SCENE_W || (unsigned)w > SCENE_W - ox ||
               oy > SCENE_H || (unsigned)h > SCENE_H - oy) {
        stbi_image_free(rgba);
        return -1;
    }
    f->rgba = rgba;
    f->w = (unsigned)w;
    f->h = (unsigned)h;
    f->ox = ox;
    f->oy = oy;
    return 0;
}

/* ---- blit ----------------------------------------------------------------
 * RGBA source -> XRGB8888 memory layout (bytes B,G,R,X), X = 0xFF (the frame
 * set is fully opaque). Same conversion the pre-port animator used, on both
 * the vendor DE2.0 fb and the DRM fbdev XRGB8888 buffer. */
static inline void px(unsigned char *dp, const unsigned char *sp) {
    dp[0] = sp[2];
    dp[1] = sp[1];
    dp[2] = sp[0];
    dp[3] = 0xFF;
}

static void blit_frame(unsigned char *page, unsigned stride, enum rot rot, const struct frame *f) {
    const unsigned sstride = f->w * 4;
    switch (rot) {
    case ROT_0:
        for (unsigned r = 0; r < f->h; r++) {
            const unsigned char *sp = f->rgba + (size_t)r * sstride;
            unsigned char *dp = page + (size_t)(f->oy + r) * stride + (size_t)f->ox * 4;
            for (unsigned c = 0; c < f->w; c++, sp += 4, dp += 4) px(dp, sp);
        }
        break;
    case ROT_180:          /* (u,v) -> (W-1-u, H-1-v) */
        for (unsigned r = 0; r < f->h; r++) {
            const unsigned char *sp = f->rgba + (size_t)r * sstride;
            unsigned char *dp = page + (size_t)(SCENE_H - 1 - (f->oy + r)) * stride
                                     + (size_t)(SCENE_W - 1 - f->ox) * 4;
            for (unsigned c = 0; c < f->w; c++, sp += 4, dp -= 4) px(dp, sp);
        }
        break;
    case ROT_90:           /* (u,v) -> (v, W-1-u): one source column per buffer row */
        for (unsigned c = 0; c < f->w; c++) {
            const unsigned char *sp = f->rgba + (size_t)c * 4;
            unsigned char *dp = page + (size_t)(SCENE_W - 1 - (f->ox + c)) * stride
                                     + (size_t)f->oy * 4;
            for (unsigned r = 0; r < f->h; r++, sp += sstride, dp += 4) px(dp, sp);
        }
        break;
    case ROT_270:          /* (u,v) -> (H-1-v, u) */
        for (unsigned c = 0; c < f->w; c++) {
            const unsigned char *sp = f->rgba + (size_t)c * 4;
            unsigned char *dp = page + (size_t)(f->ox + c) * stride
                                     + (size_t)(SCENE_H - 1 - f->oy) * 4;
            for (unsigned r = 0; r < f->h; r++, sp += sstride, dp -= 4) px(dp, sp);
        }
        break;
    }
}

/* Choose the frame index for tick k:
 *   k in [0, INTRO_FRAMES) -> frame k                             (intro, once)
 *   k >= INTRO_FRAMES      -> LOOP_START + (k - INTRO_FRAMES) % LOOP_LEN (loop) */
static unsigned frame_for_tick(unsigned k) {
    if (k < INTRO_FRAMES) return k;
    const unsigned loop_len = TOTAL_FRAMES - LOOP_START;
    return LOOP_START + ((k - INTRO_FRAMES) % loop_len);
}

static void emit_first_frame_marker(const char *mode, const struct orientation *o, int pan_ok) {
    char line[256];
    int n = snprintf(line, sizeof(line),
                     "<6>pf-boot-splash: first-frame presented src=%s rotation=%s orientation=\"%s\" source=%s pan=%s\n",
                     mode, o->row ? o->row->rot_name : "ROTATE_0",
                     o->row ? o->row->prop_name : "legacy", o->source,
                     pan_ok ? "ok" : "failed");
    if (n <= 0 || (size_t)n >= sizeof(line)) return;
    fprintf(stderr, "animator: %s", line + 3);
    int fd = open(KMSG_PATH, O_WRONLY | O_CLOEXEC);
    if (fd < 0) {
        fprintf(stderr, "animator: open %s: %s\n", KMSG_PATH, strerror(errno));
        return;
    }
    if (write(fd, line, (size_t)n) != n)
        fprintf(stderr, "animator: write %s: %s\n", KMSG_PATH, strerror(errno));
    close(fd);
}

static void usage(void) {
    fprintf(stderr, "usage: pocketforge-boot-animator [--measure] [--first-frame] [--frames-dir DIR]\n");
}

int main(int argc, char **argv) {
    int measure = 0, first_frame = 0;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--measure") == 0) measure = 1;
        else if (strcmp(argv[i], "--first-frame") == 0) first_frame = 1;
        else if (strcmp(argv[i], "--frames-dir") == 0 && i + 1 < argc) g_frames_dir = argv[++i];
        else { usage(); return 2; }
    }
    const char *mode = first_frame ? "first-frame" : "animator";

    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = on_signal;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT,  &sa, NULL);

    int fb = open(FB_PATH, O_RDWR | O_CLOEXEC);
    if (fb < 0) {
        fprintf(stderr, "animator: open %s: %s\n", FB_PATH, strerror(errno));
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
    char fb_id[sizeof(finfo.id) + 1];
    memcpy(fb_id, finfo.id, sizeof(finfo.id));
    fb_id[sizeof(finfo.id)] = '\0';
    size_t id_len = strlen(fb_id);
    const int is_drm = id_len >= 5 && strcmp(fb_id + id_len - 5, "drmfb") == 0;
    fprintf(stderr,
            "animator: fb0 id=\"%s\" %ux%u virtual %ux%u @%ubpp stride=%u "
            "channels R=%u/%u G=%u/%u B=%u/%u A=%u/%u path=%s\n",
            fb_id, vinfo.xres, vinfo.yres, vinfo.xres_virtual, vinfo.yres_virtual,
            vinfo.bits_per_pixel, finfo.line_length,
            vinfo.red.offset,   vinfo.red.length,
            vinfo.green.offset, vinfo.green.length,
            vinfo.blue.offset,  vinfo.blue.length,
            vinfo.transp.offset, vinfo.transp.length,
            is_drm ? "drm-fbdev" : "legacy-fbdev");

    struct orientation orient;
    memset(&orient, 0, sizeof(orient));
    if (is_drm) {
        /* card0 is opened and closed inside; nothing is painted before. */
        resolve_drm_orientation(&orient);
        if (!orient.row) {
            fprintf(stderr, "animator: panel orientation unknown (%s); painting nothing\n",
                    orient.why);
            close(fb);
            return 0;
        }
        fprintf(stderr, "animator: panel orientation \"%s\" from %s -> %s\n",
                orient.row->prop_name, orient.source, orient.row->rot_name);
    } else {
        /* Legacy fbdev has no connector: its driver presents fb0 upright
         * (vendor disp2 g2d rotation), exactly as before this port. */
        orient.row = &k_orientations[0];
        orient.source = "legacy-fbdev";
    }
    const enum rot rot = orient.row->rot;
    const int swap = (rot == ROT_90 || rot == ROT_270);
    const unsigned need_x = swap ? SCENE_H : SCENE_W;
    const unsigned need_y = swap ? SCENE_W : SCENE_H;

    if (vinfo.xres != need_x || vinfo.yres != need_y || vinfo.bits_per_pixel != 32 ||
        finfo.line_length < need_x * 4) {
        fprintf(stderr,
                "animator: unexpected fb0 geometry; expected %ux%u @32bpp for %s (%s)\n",
                need_x, need_y, orient.row->rot_name, is_drm ? orient.row->prop_name : "legacy");
        close(fb);
        return 1;
    }

    hide_fbcon();

    size_t map_bytes = (size_t)finfo.line_length * vinfo.yres_virtual;
    if (map_bytes == 0) map_bytes = (size_t)finfo.line_length * vinfo.yres;
    unsigned char *fbmap = mmap(NULL, map_bytes, PROT_READ | PROT_WRITE, MAP_SHARED, fb, 0);
    if (fbmap == MAP_FAILED) {
        fprintf(stderr, "animator: mmap fb0: %s\n", strerror(errno));
        close(fb);
        return 1;
    }
    const size_t page_bytes = (size_t)vinfo.yres * finfo.line_length;

    /* Legacy: alternate pages when double-buffered (the pre-port pan path).
     * DRM fbdev: draw in place and pan(0) (OVERALLOC=100 is a single page). */
    const unsigned n_pages =
        (!is_drm && vinfo.yres_virtual >= 2 * vinfo.yres) ? 2 : 1;
    fprintf(stderr, "animator: presenting via FBIOPAN_DISPLAY, %u page(s) (yres_virtual=%u)%s\n",
            n_pages, vinfo.yres_virtual, is_drm ? ", region blit after FBIO_WAITFORVSYNC" : "");

    struct rusage ru0;
    getrusage(RUSAGE_SELF, &ru0);
    struct timespec t0;
    clock_gettime(CLOCK_MONOTONIC, &t0);

    unsigned page = 0;          /* page we blit into (then pan to) */
    int pan_err_logged = 0, vsync_err_logged = 0, painted = 0;
    unsigned last_frame = 0, k = 0;

    for (k = 0; !g_stop; k++) {
        const unsigned fidx = frame_for_tick(k);
        struct frame f;

        struct timespec td0; clock_gettime(CLOCK_MONOTONIC, &td0);
        int ok = decode_frame(fidx, &f) == 0;
        long decode_ns = ns_since(&td0);
        long vsync_ns = 0, blit_ns = 0;

        if (ok) {
            if (is_drm && painted) {
                /* Region update: wait for vblank so the small blit lands
                 * while the scan-out is at the top of the panel. */
                struct timespec tv0; clock_gettime(CLOCK_MONOTONIC, &tv0);
                __u32 crtc = 0;
                if (ioctl(fb, FBIO_WAITFORVSYNC, &crtc) < 0 && !vsync_err_logged) {
                    fprintf(stderr, "animator: FBIO_WAITFORVSYNC: %s (continuing)\n",
                            strerror(errno));
                    vsync_err_logged = 1;
                }
                vsync_ns = ns_since(&tv0);
            }
            struct timespec tb0; clock_gettime(CLOCK_MONOTONIC, &tb0);
            blit_frame(fbmap + (size_t)page * page_bytes, finfo.line_length, rot, &f);
            if (k == 0 && n_pages == 2)   /* base for region updates on the other page */
                blit_frame(fbmap + page_bytes, finfo.line_length, rot, &f);
            blit_ns = ns_since(&tb0);
            stbi_image_free(f.rgba);

            /* Present: pan to the page just blitted. On a decode failure the
             * pan is skipped too, so the panel keeps the last good frame. */
            vinfo.yoffset = page * vinfo.yres;
            vinfo.xoffset = 0;
            int pan_ok = ioctl(fb, FBIOPAN_DISPLAY, &vinfo) == 0;
            if (!pan_ok) {
                if (!pan_err_logged) {
                    fprintf(stderr, "animator: FBIOPAN_DISPLAY: %s "
                            "(frames may not reach the panel)\n", strerror(errno));
                    pan_err_logged = 1;
                }
            } else if (n_pages == 2) {
                page ^= 1;
            }
            if (!painted) {
                painted = 1;
                emit_first_frame_marker(mode, &orient, pan_ok);
            }
            last_frame = fidx;
        } else {
            fprintf(stderr, "animator: decode failed for frame %u; holding previous\n", fidx);
            if (k == 0) {
                /* Frame 000 is the base every region update composes onto. */
                fprintf(stderr, "animator: frame 000 unusable; stopping without painting\n");
                munmap(fbmap, map_bytes);
                close(fb);
                return 1;
            }
        }

        if (measure) {
            fprintf(stderr,
                    "animator: tick=%u frame=%u decode=%.2fms blit=%.2fms vsync=%.2fms\n",
                    k, fidx, decode_ns / 1e6, blit_ns / 1e6, vsync_ns / 1e6);
        }
        if (first_frame) { k++; break; }

        /* Deadline schedule: wait until (k+1) * TICK_NS since t0. Absolute,
         * so a slow tick is caught up by the next one (frames may drop under
         * boot load; the animator never holds anything up). */
        long target_ns  = (long)(k + 1) * TICK_NS;
        long sleep_ns   = target_ns - ns_since(&t0);
        if (sleep_ns > 0) {
            struct timespec ts = { sleep_ns / 1000000000L, sleep_ns % 1000000000L };
            while (!g_stop && nanosleep(&ts, &ts) == -1 && errno == EINTR) {}
        }
    }

    if (measure) {
        struct rusage ru1;
        getrusage(RUSAGE_SELF, &ru1);
        double cpu_ms = (ru1.ru_utime.tv_sec - ru0.ru_utime.tv_sec) * 1e3
                      + (ru1.ru_utime.tv_usec - ru0.ru_utime.tv_usec) / 1e3
                      + (ru1.ru_stime.tv_sec - ru0.ru_stime.tv_sec) * 1e3
                      + (ru1.ru_stime.tv_usec - ru0.ru_stime.tv_usec) / 1e3;
        /* VmHWM/RssAnon, not ru_maxrss: exec folds the forking parent's
         * peak (PID 1's) into ru_maxrss. RssFile includes the touched fb
         * mapping on a file-backed fb. */
        char st[4096];
        long hwm = -1, anon = -1;
        if (read_small("/proc/self/status", st, sizeof(st)) > 0) {
            char *p;
            if ((p = strstr(st, "VmHWM:"))) hwm = strtol(p + 6, NULL, 10);
            if ((p = strstr(st, "RssAnon:"))) anon = strtol(p + 8, NULL, 10);
        }
        fprintf(stderr, "animator: measure ticks=%u cpu_ms=%.1f wall_ms=%.1f "
                "vm_hwm_kb=%ld rss_anon_kb=%ld\n",
                k, cpu_ms, ns_since(&t0) / 1e6, hwm, anon);
    }

    /* Handoff (both paths): HOLD the last presented frame. No clear and no
     * pan: the successor overwrites the whole buffer on its first present, so
     * clearing would only insert a black gap (design note section 3.5). */
    if (!first_frame)
        fprintf(stderr, "animator: stop: holding frame %u on the panel (no clear)\n", last_frame);
    munmap(fbmap, map_bytes);
    close(fb);
    return 0;
}
