/*
 * fakefb.so -- LD_PRELOAD test double for pocketforge-boot-animator
 * (bd tsp-3rd3.6). The animator binary under test is the production build,
 * unmodified: this library interposes libc's open/close/ioctl/mmap and
 * answers for
 *
 *   /dev/fb0        a regular backing file plus scripted fb ioctls
 *                   (FBIOGET_VSCREENINFO/FSCREENINFO, FBIOPAN_DISPLAY,
 *                   FBIO_WAITFORVSYNC); every pan is logged with a hash of the
 *                   page it presents, optionally snapshotted, optionally
 *                   followed by raise(SIGTERM)
 *   /dev/dri/card0  a scripted KMS device answering MODE_GETRESOURCES,
 *                   MODE_GETCONNECTOR and MODE_GETPROPERTY with the kernel's
 *                   copy semantics (drm_mode_getresources /
 *                   drm_mode_getconnector / drm_mode_getproperty_ioctl)
 *   other paths     rewritten by prefix (FAKEFB_REDIRECT), e.g. /sys and
 *                   /dev/kmsg into a per-test directory
 *
 * Environment (all set by tests/test_animator.py):
 *   FAKEFB_STATE     directory for events.log, pan snapshots
 *   FAKEFB_BACKING   backing file for /dev/fb0 (absent -> ENOENT)
 *   FAKEFB_GEOM      "xres,yres,xres_virtual,yres_virtual,bpp,line_length"
 *   FAKEFB_ID        fix.id string (e.g. "sun4i-drmdrmfb")
 *   FAKEFB_DRM       absent | eio | noprop | prop:<name> | conflict |
 *                    unknown-status:<name> | badname
 *   FAKEFB_REDIRECT  "from=to;from=to" path-prefix rewrites
 *   FAKEFB_SNAP      comma list of pan numbers to snapshot (pan-NNNN.raw)
 *   FAKEFB_TERM_AT_PAN  raise(SIGTERM) right after pan N (snapshot term.raw)
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/fb.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include <drm/drm.h>
#include <drm/drm_mode.h>

static int (*real_openat)(int, const char *, int, ...);
static int (*real_close)(int);
static int (*real_ioctl)(int, unsigned long, ...);
static void *(*real_mmap)(void *, size_t, int, int, int, off_t);

static int fb_fd = -1, drm_fd = -1;
static unsigned pan_count = 0;
static unsigned event_seq = 0;

static void init_real(void) {
    if (real_openat) return;
    real_openat = dlsym(RTLD_NEXT, "openat");
    real_close = dlsym(RTLD_NEXT, "close");
    real_ioctl = dlsym(RTLD_NEXT, "ioctl");
    real_mmap = dlsym(RTLD_NEXT, "mmap");
}

static void event(const char *fmt, ...) {
    const char *dir = getenv("FAKEFB_STATE");
    if (!dir) return;
    char path[4096], line[1024];
    snprintf(path, sizeof(path), "%s/events.log", dir);
    va_list ap;
    va_start(ap, fmt);
    int n = snprintf(line, sizeof(line), "%u ", event_seq++);
    n += vsnprintf(line + n, sizeof(line) - (size_t)n, fmt, ap);
    va_end(ap);
    if (n >= (int)sizeof(line) - 1) n = (int)sizeof(line) - 2;
    line[n++] = '\n';
    int fd = real_openat(AT_FDCWD, path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
    if (fd < 0) return;
    ssize_t w = write(fd, line, (size_t)n);
    (void)w;
    real_close(fd);
}

/* ---- path handling ------------------------------------------------------- */

static const char *redirect(const char *path, char *buf, size_t cap) {
    const char *spec = getenv("FAKEFB_REDIRECT");
    if (!spec || !path || path[0] != '/') return path;
    const char *p = spec;
    while (*p) {
        const char *eq = strchr(p, '=');
        if (!eq) break;
        const char *end = strchr(eq, ';');
        if (!end) end = eq + strlen(eq);
        size_t flen = (size_t)(eq - p), tlen = (size_t)(end - eq - 1);
        if (strncmp(path, p, flen) == 0 && (path[flen] == '\0' || path[flen] == '/')) {
            snprintf(buf, cap, "%.*s%s", (int)tlen, eq + 1, path + flen);
            return buf;
        }
        p = *end ? end + 1 : end;
    }
    return path;
}

static int fake_open(int dirfd, const char *path, int flags, mode_t mode) {
    init_real();
    if (path && strcmp(path, "/dev/fb0") == 0) {
        const char *backing = getenv("FAKEFB_BACKING");
        if (!backing) { errno = ENOENT; return -1; }
        int fd = real_openat(AT_FDCWD, backing, O_RDWR | O_CLOEXEC);
        if (fd >= 0) fb_fd = fd;
        event("fb-open flags=0x%x", flags);
        return fd;
    }
    if (path && strcmp(path, "/dev/dri/card0") == 0) {
        const char *drm = getenv("FAKEFB_DRM");
        if (!drm || strcmp(drm, "absent") == 0) { event("drm-open-enoent"); errno = ENOENT; return -1; }
        int fd = real_openat(AT_FDCWD, "/dev/null", O_RDONLY | O_CLOEXEC);
        if (fd >= 0) drm_fd = fd;
        event("drm-open accmode=%s", (flags & O_ACCMODE) == O_RDONLY ? "rdonly" : "write");
        return fd;
    }
    char buf[4096];
    const char *real = redirect(path, buf, sizeof(buf));
    int fd = real_openat(dirfd, real, flags, mode);
    if (real != path)
        event("open %s %s -> %d", path, (flags & O_ACCMODE) == O_RDONLY ? "r" : "w", fd < 0 ? -errno : 0);
    return fd;
}

#define MODE_ARG(flags) \
    mode_t mode = 0; \
    if ((flags) & (O_CREAT | O_TMPFILE)) { va_list ap; va_start(ap, flags); mode = va_arg(ap, mode_t); va_end(ap); }

int open(const char *path, int flags, ...) { MODE_ARG(flags); return fake_open(AT_FDCWD, path, flags, mode); }
int open64(const char *path, int flags, ...) { MODE_ARG(flags); return fake_open(AT_FDCWD, path, flags, mode); }
int openat(int dirfd, const char *path, int flags, ...) { MODE_ARG(flags); return fake_open(dirfd, path, flags, mode); }
int openat64(int dirfd, const char *path, int flags, ...) { MODE_ARG(flags); return fake_open(dirfd, path, flags, mode); }
int __open_2(const char *path, int flags) { return fake_open(AT_FDCWD, path, flags, 0); }
int __open64_2(const char *path, int flags) { return fake_open(AT_FDCWD, path, flags, 0); }
int __openat_2(int dirfd, const char *path, int flags) { return fake_open(dirfd, path, flags, 0); }
int __openat64_2(int dirfd, const char *path, int flags) { return fake_open(dirfd, path, flags, 0); }

int close(int fd) {
    init_real();
    if (fd >= 0 && fd == drm_fd) { event("drm-close"); drm_fd = -1; }
    if (fd >= 0 && fd == fb_fd) { event("fb-close"); fb_fd = -1; }
    return real_close(fd);
}

void *mmap(void *addr, size_t len, int prot, int flags, int fd, off_t off) {
    init_real();
    if (fd >= 0 && fd == fb_fd) event("fb-mmap len=%zu", len);
    return real_mmap(addr, len, prot, flags, fd, off);
}
void *mmap64(void *addr, size_t len, int prot, int flags, int fd, off_t off) {
    return mmap(addr, len, prot, flags, fd, off);
}

/* ---- fb ------------------------------------------------------------------ */

struct geom { unsigned xres, yres, xv, yv, bpp, stride; };

static struct geom get_geom(void) {
    struct geom g = { 1280, 720, 1280, 1440, 32, 5120 };
    const char *s = getenv("FAKEFB_GEOM");
    if (s) sscanf(s, "%u,%u,%u,%u,%u,%u", &g.xres, &g.yres, &g.xv, &g.yv, &g.bpp, &g.stride);
    return g;
}

static uint64_t fnv1a(const unsigned char *p, size_t n) {
    uint64_t h = 1469598103934665603ULL;
    for (size_t i = 0; i < n; i++) { h ^= p[i]; h *= 1099511628211ULL; }
    return h;
}

static int in_list(const char *list, unsigned v) {
    if (!list) return 0;
    const char *p = list;
    while (*p) {
        char *end;
        unsigned long x = strtoul(p, &end, 10);
        if (end == p) break;
        if (x == v) return 1;
        p = *end ? end + 1 : end;
    }
    return 0;
}

static void write_file(const char *name, const unsigned char *buf, size_t n) {
    const char *dir = getenv("FAKEFB_STATE");
    if (!dir) return;
    char path[4096];
    snprintf(path, sizeof(path), "%s/%s", dir, name);
    int fd = real_openat(AT_FDCWD, path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd < 0) return;
    size_t done = 0;
    while (done < n) {
        ssize_t w = write(fd, buf + done, n - done);
        if (w <= 0) break;
        done += (size_t)w;
    }
    real_close(fd);
}

/* Peak and current memory of THIS process image (VmHWM is per-mm, so unlike
 * ru_maxrss it does not include the forking parent's footprint). */
static void log_memory(unsigned n) {
    char buf[8192];
    int fd = real_openat(AT_FDCWD, "/proc/self/status", O_RDONLY | O_CLOEXEC);
    if (fd < 0) return;
    ssize_t len = read(fd, buf, sizeof(buf) - 1);
    real_close(fd);
    if (len <= 0) return;
    buf[len] = '\0';
    long hwm = -1, anon = -1, file = -1;
    char *p;
    if ((p = strstr(buf, "VmHWM:"))) hwm = strtol(p + 6, NULL, 10);
    if ((p = strstr(buf, "RssAnon:"))) anon = strtol(p + 8, NULL, 10);
    if ((p = strstr(buf, "RssFile:"))) file = strtol(p + 8, NULL, 10);
    event("memory at pan n=%u vmhwm_kb=%ld rssanon_kb=%ld rssfile_kb=%ld", n, hwm, anon, file);
}

static int fb_ioctl(unsigned long req, void *arg) {
    struct geom g = get_geom();
    switch (req) {
    case FBIOGET_VSCREENINFO: {
        struct fb_var_screeninfo *v = arg;
        memset(v, 0, sizeof(*v));
        v->xres = g.xres; v->yres = g.yres;
        v->xres_virtual = g.xv; v->yres_virtual = g.yv;
        v->bits_per_pixel = g.bpp;
        v->red.offset = 16; v->red.length = 8;
        v->green.offset = 8; v->green.length = 8;
        v->blue.offset = 0; v->blue.length = 8;
        event("fb-get-var");
        return 0;
    }
    case FBIOGET_FSCREENINFO: {
        struct fb_fix_screeninfo *f = arg;
        memset(f, 0, sizeof(*f));
        const char *id = getenv("FAKEFB_ID");
        strncpy(f->id, id ? id : "", sizeof(f->id));
        f->line_length = g.stride;
        f->smem_len = g.stride * g.yv;
        f->ypanstep = 1;
        event("fb-get-fix");
        return 0;
    }
    case FBIOPAN_DISPLAY: {
        struct fb_var_screeninfo *v = arg;
        unsigned n = pan_count++;
        if (v->yoffset + g.yres > g.yv || v->xoffset != 0) {
            event("pan n=%u yoffset=%u EINVAL", n, v->yoffset);
            errno = EINVAL;
            return -1;
        }
        size_t page = (size_t)g.stride * g.yres;
        /* FAKEFB_NOHASH: cost runs keep the shim's own work out of the
         * animator's CPU and RSS. */
        unsigned char *buf = getenv("FAKEFB_NOHASH") ? NULL : malloc(page);
        uint64_t h = 0;
        if (buf && pread(fb_fd, buf, page, (off_t)v->yoffset * g.stride) == (ssize_t)page) {
            h = fnv1a(buf, page);
            if (in_list(getenv("FAKEFB_SNAP"), n)) {
                char name[64];
                snprintf(name, sizeof(name), "pan-%04u.raw", n);
                write_file(name, buf, page);
            }
        }
        free(buf);
        event("pan n=%u yoffset=%u fnv=%016llx", n, v->yoffset, (unsigned long long)h);
        const char *term = getenv("FAKEFB_TERM_AT_PAN");
        if (term && (unsigned)strtoul(term, NULL, 10) == n) {
            log_memory(n);
            struct stat st;
            if (fstat(fb_fd, &st) == 0) {
                unsigned char *all = malloc((size_t)st.st_size);
                if (all && pread(fb_fd, all, (size_t)st.st_size, 0) == st.st_size)
                    write_file("term.raw", all, (size_t)st.st_size);
                free(all);
            }
            event("raise SIGTERM after pan n=%u", n);
            raise(SIGTERM);
        }
        return 0;
    }
    case FBIO_WAITFORVSYNC:
        event("vsync");
        return 0;
    default:
        event("fb-ioctl-unknown 0x%lx", req);
        errno = ENOTTY;
        return -1;
    }
}

/* ---- drm ----------------------------------------------------------------- */

struct fprop {
    uint32_t id;
    const char *name;
    uint32_t flags;
    const char *const *enums;   /* NULL-terminated, value = index */
};

static const char *const k_orient_enums[] = { "Normal", "Upside Down", "Left Side Up", "Right Side Up", NULL };
static const char *const k_dpms_enums[] = { "On", "Standby", "Suspend", "Off", NULL };
static const struct fprop k_props[] = {
    { 2, "DPMS", DRM_MODE_PROP_ENUM, k_dpms_enums },
    { 5, "non-desktop", DRM_MODE_PROP_RANGE | DRM_MODE_PROP_IMMUTABLE, NULL },
    { 40, "panel orientation", DRM_MODE_PROP_ENUM | DRM_MODE_PROP_IMMUTABLE, k_orient_enums },
};

struct fconn { uint32_t id; uint32_t status; int orient; /* -1: no property */ };

static int orient_index(const char *name) {
    for (int i = 0; k_orient_enums[i]; i++)
        if (strcmp(k_orient_enums[i], name) == 0) return i;
    return 7;   /* a value with no enum name */
}

static unsigned drm_connectors(struct fconn *c) {
    const char *spec = getenv("FAKEFB_DRM");
    if (!spec) return 0;
    if (strcmp(spec, "noprop") == 0) { c[0] = (struct fconn){ 31, 1, -1 }; return 1; }
    if (strcmp(spec, "badname") == 0) { c[0] = (struct fconn){ 31, 1, 7 }; return 1; }
    if (strcmp(spec, "conflict") == 0) {
        c[0] = (struct fconn){ 31, 1, 2 };
        c[1] = (struct fconn){ 32, 1, 3 };
        return 2;
    }
    if (strncmp(spec, "prop:", 5) == 0) {
        /* a disconnected HDMI-like connector that says the opposite, plus
         * the connected panel: only the connected one may count */
        c[0] = (struct fconn){ 30, 2, 0 };
        c[1] = (struct fconn){ 31, 1, orient_index(spec + 5) };
        return 2;
    }
    if (strncmp(spec, "unknown-status:", 15) == 0) {
        c[0] = (struct fconn){ 31, 3, orient_index(spec + 15) };
        return 1;
    }
    return 0;
}

static int drm_ioctl_fake(unsigned long req, void *arg) {
    const char *spec = getenv("FAKEFB_DRM");
    struct fconn conns[4];
    unsigned n = drm_connectors(conns);
    if (spec && strcmp(spec, "eio") == 0) { event("drm-ioctl EIO"); errno = EIO; return -1; }
    if (req == DRM_IOCTL_MODE_GETRESOURCES) {
        struct drm_mode_card_res *r = arg;
        uint32_t *ids = (uint32_t *)(uintptr_t)r->connector_id_ptr;
        for (unsigned i = 0; i < n; i++)
            if (i < r->count_connectors) ids[i] = conns[i].id;
        r->count_connectors = n;
        r->count_fbs = r->count_crtcs = r->count_encoders = 0;
        event("drm-getresources");
        return 0;
    }
    if (req == DRM_IOCTL_MODE_GETCONNECTOR) {
        struct drm_mode_get_connector *c = arg;
        const struct fconn *fc = NULL;
        for (unsigned i = 0; i < n; i++) if (conns[i].id == c->connector_id) fc = &conns[i];
        if (!fc) { errno = ENOENT; return -1; }
        if (c->count_modes == 0) event("drm-forced-probe connector=%u", fc->id);
        c->connection = fc->status;
        c->count_modes = 0;
        c->count_encoders = 0;
        uint32_t *ids = (uint32_t *)(uintptr_t)c->props_ptr;
        uint64_t *vals = (uint64_t *)(uintptr_t)c->prop_values_ptr;
        unsigned count = 0;
        for (unsigned i = 0; i < sizeof(k_props) / sizeof(k_props[0]); i++) {
            uint64_t val = 0;
            if (k_props[i].id == 40) {
                if (fc->orient < 0) continue;
                val = (uint64_t)fc->orient;
            }
            if (count < c->count_props) { ids[count] = k_props[i].id; vals[count] = val; }
            count++;
        }
        c->count_props = count;
        event("drm-getconnector %u", fc->id);
        return 0;
    }
    if (req == DRM_IOCTL_MODE_GETPROPERTY) {
        struct drm_mode_get_property *p = arg;
        const struct fprop *fp = NULL;
        for (unsigned i = 0; i < sizeof(k_props) / sizeof(k_props[0]); i++)
            if (k_props[i].id == p->prop_id) fp = &k_props[i];
        if (!fp) { errno = ENOENT; return -1; }
        memset(p->name, 0, sizeof(p->name));
        strncpy(p->name, fp->name, sizeof(p->name) - 1);
        p->flags = fp->flags;
        unsigned count = 0;
        if (fp->enums) {
            struct drm_mode_property_enum *e = (void *)(uintptr_t)p->enum_blob_ptr;
            for (unsigned i = 0; fp->enums[i]; i++) {
                count++;
                if (p->count_enum_blobs < count) continue;
                e[i].value = i;
                memset(e[i].name, 0, sizeof(e[i].name));
                strncpy(e[i].name, fp->enums[i], sizeof(e[i].name) - 1);
            }
        }
        p->count_enum_blobs = count;
        p->count_values = count;
        event("drm-getproperty %u", fp->id);
        return 0;
    }
    event("drm-ioctl-unknown 0x%lx", req);
    errno = ENOTTY;
    return -1;
}

int ioctl(int fd, unsigned long req, ...) {
    init_real();
    va_list ap;
    va_start(ap, req);
    void *arg = va_arg(ap, void *);
    va_end(ap);
    if (fd >= 0 && fd == fb_fd) return fb_ioctl(req, arg);
    if (fd >= 0 && fd == drm_fd) return drm_ioctl_fake(req, arg);
    return real_ioctl(fd, req, arg);
}
