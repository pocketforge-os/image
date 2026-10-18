#define _POSIX_C_SOURCE 200809L

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <GL/gl.h>
#include <GL/glx.h>

#include "glx-renderer-policy.h"

#define PROBE_WIDTH 16
#define PROBE_HEIGHT 16
#define GLX_READBACK_CRC32 0xad849d79u

static uint32_t crc32_bytes(const unsigned char *data, size_t length)
{
    uint32_t crc = UINT32_C(0xffffffff);
    size_t i;
    unsigned int bit;

    for (i = 0; i < length; ++i) {
        crc ^= data[i];
        for (bit = 0; bit < 8; ++bit)
            crc = (crc >> 1) ^ (UINT32_C(0xedb88320) & (0u - (crc & 1u)));
    }
    return ~crc;
}

static int check_pixels(const char *stage, const unsigned char *pixels, size_t length)
{
    static const unsigned char expected[4] = { 0x3c, 0xa5, 0x7e, 0xff };
    uint32_t crc;
    size_t i;

    for (i = 0; i < length; i += sizeof(expected)) {
        if (memcmp(pixels + i, expected, sizeof(expected)) != 0) {
            fprintf(stderr,
                    "glx-readback-probe: %s pixel mismatch offset=%zu got=%02x%02x%02x%02x expected=3ca57eff\n",
                    stage, i, pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3]);
            return 1;
        }
    }
    crc = crc32_bytes(pixels, length);
    if (crc != GLX_READBACK_CRC32) {
        fprintf(stderr,
                "glx-readback-probe: %s checksum mismatch got=%08x expected=%08x\n",
                stage, crc, GLX_READBACK_CRC32);
        return 1;
    }
    return 0;
}

static void wait_for_map(Display *display, Window window)
{
    XEvent event;

    do {
        XNextEvent(display, &event);
    } while (event.type != MapNotify || event.xmap.window != window);
}

int main(void)
{
    static const int visual_attributes[] = {
        GLX_RGBA,
        GLX_DOUBLEBUFFER,
        GLX_RED_SIZE, 8,
        GLX_GREEN_SIZE, 8,
        GLX_BLUE_SIZE, 8,
        None,
    };
    unsigned char pixels[PROBE_WIDTH * PROBE_HEIGHT * 4];
    Display *display = NULL;
    XVisualInfo *visual = NULL;
    GLXContext context = NULL;
    Colormap colormap = None;
    Window window = None;
    XSetWindowAttributes attributes;
    const char *renderer;
    const char *version;
    const char *vendor;
    int major = 0, minor = 0;
    int status = 1;

    display = XOpenDisplay(NULL);
    if (display == NULL) {
        fprintf(stderr, "glx-readback-probe: cannot open DISPLAY\n");
        goto cleanup;
    }
    visual = glXChooseVisual(display, DefaultScreen(display), (int *)visual_attributes);
    if (visual == NULL) {
        fprintf(stderr, "glx-readback-probe: no RGBA double-buffered GLX visual\n");
        goto cleanup;
    }
    colormap = XCreateColormap(display, RootWindow(display, visual->screen),
                              visual->visual, AllocNone);
    attributes.colormap = colormap;
    attributes.event_mask = StructureNotifyMask;
    window = XCreateWindow(display, RootWindow(display, visual->screen), 0, 0,
                           PROBE_WIDTH, PROBE_HEIGHT, 0, visual->depth, InputOutput,
                           visual->visual, CWColormap | CWEventMask, &attributes);
    if (window == None) {
        fprintf(stderr, "glx-readback-probe: XCreateWindow failed\n");
        goto cleanup;
    }
    XStoreName(display, window, "PocketForge GLX readback probe");
    XMapWindow(display, window);
    wait_for_map(display, window);

    context = glXCreateContext(display, visual, NULL, True);
    if (context == NULL || !glXMakeCurrent(display, window, context)) {
        fprintf(stderr, "glx-readback-probe: direct GLX context creation failed\n");
        goto cleanup;
    }
    if (!glXIsDirect(display, context)) {
        fprintf(stderr, "glx-readback-probe: indirect GLX context rejected\n");
        goto cleanup;
    }

    version = (const char *)glGetString(GL_VERSION);
    renderer = (const char *)glGetString(GL_RENDERER);
    vendor = (const char *)glGetString(GL_VENDOR);
    if (version == NULL || renderer == NULL || vendor == NULL) {
        fprintf(stderr, "glx-readback-probe: GL identity string is missing\n");
        goto cleanup;
    }
    if (sscanf(version, "%d.%d", &major, &minor) != 2 ||
        major < 2 || (major == 2 && minor < 1)) {
        fprintf(stderr, "glx-readback-probe: OpenGL 2.1 floor not met: %s\n", version);
        goto cleanup;
    }
    if (!pf_glx_renderer_is_owned(renderer)) {
        fprintf(stderr, "glx-readback-probe: unowned or software renderer rejected: %s\n",
                renderer);
        goto cleanup;
    }
    if (!pf_ascii_contains_folded(vendor, "mesa")) {
        fprintf(stderr, "glx-readback-probe: non-Mesa GL vendor rejected: %s\n", vendor);
        goto cleanup;
    }

    glDrawBuffer(GL_BACK);
    glReadBuffer(GL_BACK);
    glDisable(GL_BLEND);
    glDisable(GL_DEPTH_TEST);
    glDisable(GL_DITHER);
    glDisable(GL_SCISSOR_TEST);
#ifdef GL_MULTISAMPLE
    glDisable(GL_MULTISAMPLE);
#endif
    glViewport(0, 0, PROBE_WIDTH, PROBE_HEIGHT);
    glMatrixMode(GL_PROJECTION);
    glLoadIdentity();
    glMatrixMode(GL_MODELVIEW);
    glLoadIdentity();
    glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);
    glColor4ub(0x3c, 0xa5, 0x7e, 0xff);
    glBegin(GL_TRIANGLES);
    glVertex2f(-1.0f, -1.0f);
    glVertex2f(3.0f, -1.0f);
    glVertex2f(-1.0f, 3.0f);
    glEnd();
    glFinish();
    if (glGetError() != GL_NO_ERROR) {
        fprintf(stderr, "glx-readback-probe: GL draw failed\n");
        goto cleanup;
    }
    glReadPixels(0, 0, PROBE_WIDTH, PROBE_HEIGHT, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
    glFinish();
    if (glGetError() != GL_NO_ERROR || check_pixels("back", pixels, sizeof(pixels)) != 0)
        goto cleanup;

    glXSwapBuffers(display, window);
    glXWaitGL();
    XSync(display, False);
    glReadBuffer(GL_FRONT);
    glReadPixels(0, 0, PROBE_WIDTH, PROBE_HEIGHT, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
    glFinish();
    if (glGetError() != GL_NO_ERROR || check_pixels("front", pixels, sizeof(pixels)) != 0)
        goto cleanup;

    printf("glx_version=%s vendor=%s renderer=%s draw=ok back_crc32=%08x present=ok front_crc32=%08x\n",
           version, vendor, renderer, GLX_READBACK_CRC32, GLX_READBACK_CRC32);
    status = 0;

cleanup:
    if (display != NULL && context != NULL) {
        glXMakeCurrent(display, None, NULL);
        glXDestroyContext(display, context);
    }
    if (display != NULL && window != None)
        XDestroyWindow(display, window);
    if (display != NULL && colormap != None)
        XFreeColormap(display, colormap);
    if (visual != NULL)
        XFree(visual);
    if (display != NULL)
        XCloseDisplay(display);
    return status;
}
