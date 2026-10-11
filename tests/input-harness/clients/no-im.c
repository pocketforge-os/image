/* no-IM Wayland client (row 'app with no input method'). Raw libwayland:
 * binds only wl_compositor/wl_seat/xdg_wm_base, never any text-input or
 * input-method protocol. Records keyboard enter/leave/key and pointer
 * events; the LD_PRELOAD transcript lib notes text-input-v3 unavailability.
 */
#define _GNU_SOURCE
#include "../tools/transcript.h"

#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/mman.h>
#include <wayland-client.h>
#include <wayland-client-protocol.h>

#include "xdg-shell-client-protocol.h"

static struct wl_display *g_display;
static struct wl_registry *g_registry;
static struct wl_compositor *g_compositor;
static struct wl_seat *g_seat;
static struct wl_shm *wl_registry_shm;
static struct xdg_wm_base *g_xdg_wm_base;
static struct wl_surface *g_surface;
static struct xdg_surface *g_xdg_surface;
static struct xdg_toplevel *g_toplevel;
static volatile sig_atomic_t g_stop;
static int g_configured;

static void on_sigterm(int sig)
{
	(void)sig;
	g_stop = 1;
}

static void noop(void)
{
}

static void xdg_surface_configure(void *data, struct xdg_surface *xs,
				  uint32_t serial)
{
	(void)data;
	xdg_surface_ack_configure(xs, serial);
	if (!g_configured) {
		g_configured = 1;
		pf_tx_emitf("mapped", ",\"width\":%d,\"height\":%d", 640, 480);
	}
}

static const struct xdg_surface_listener xdg_surface_listener = {
	.configure = xdg_surface_configure,
};

static void xdg_toplevel_configure(void *data, struct xdg_toplevel *tl,
				   int32_t width, int32_t height,
				   struct wl_array *states)
{
	(void)data; (void)tl; (void)width; (void)height; (void)states;
}

static void xdg_toplevel_close(void *data, struct xdg_toplevel *tl)
{
	(void)data; (void)tl;
	g_stop = 1;
}

static void xdg_toplevel_bounds(void *data, struct xdg_toplevel *tl,
				int32_t width, int32_t height)
{
	(void)data; (void)tl; (void)width; (void)height;
}

static void xdg_toplevel_caps(void *data, struct xdg_toplevel *tl,
			      uint32_t caps)
{
	(void)data; (void)tl; (void)caps;
}

static const struct xdg_toplevel_listener xdg_toplevel_listener = {
	.configure = xdg_toplevel_configure,
	.close = xdg_toplevel_close,
	.configure_bounds = xdg_toplevel_bounds,
	.capabilities = xdg_toplevel_caps,
};

static void xdg_wm_base_ping(void *data, struct xdg_wm_base *wm, uint32_t serial)
{
	(void)data;
	xdg_wm_base_pong(wm, serial);
}

static const struct xdg_wm_base_listener xdg_wm_base_listener = {
	.ping = xdg_wm_base_ping,
};

static void keyboard_keymap(void *data, struct wl_keyboard *kb,
			    uint32_t format, int32_t fd, uint32_t size)
{
	(void)data; (void)kb; (void)format; (void)size;
	close(fd);
}

static void keyboard_enter(void *data, struct wl_keyboard *kb, uint32_t serial,
			   struct wl_surface *surface, struct wl_array *keys)
{
	(void)data; (void)kb; (void)surface; (void)keys;
	pf_tx_emitf("enter", ",\"serial\":%u", serial);
}

static void keyboard_leave(void *data, struct wl_keyboard *kb, uint32_t serial,
			   struct wl_surface *surface)
{
	(void)data; (void)kb; (void)surface;
	pf_tx_emitf("leave", ",\"serial\":%u", serial);
}

static void keyboard_key(void *data, struct wl_keyboard *kb, uint32_t serial,
			 uint32_t time, uint32_t key, uint32_t state)
{
	(void)data; (void)kb; (void)serial; (void)time;
	pf_tx_emitf("key",
		    ",\"keycode\":%u,\"keysym\":\"\",\"state\":\"%s\",\"mods\":0",
		    key + 8,
		    state == WL_KEYBOARD_KEY_STATE_PRESSED ? "pressed"
							   : "released");
}

static void keyboard_modifiers(void *data, struct wl_keyboard *kb,
			       uint32_t serial, uint32_t depressed,
			       uint32_t latched, uint32_t locked,
			       uint32_t group)
{
	(void)data; (void)kb; (void)serial; (void)depressed; (void)latched;
	(void)locked; (void)group;
}

static void keyboard_repeat(void *data, struct wl_keyboard *kb, int32_t rate,
			    int32_t delay)
{
	(void)data; (void)kb; (void)rate; (void)delay;
}

static const struct wl_keyboard_listener keyboard_listener = {
	.keymap = keyboard_keymap,
	.enter = keyboard_enter,
	.leave = keyboard_leave,
	.key = keyboard_key,
	.modifiers = keyboard_modifiers,
	.repeat_info = keyboard_repeat,
};

static void pointer_enter(void *data, struct wl_pointer *p, uint32_t serial,
			  struct wl_surface *surface, wl_fixed_t sx,
			  wl_fixed_t sy)
{
	(void)data; (void)p; (void)serial; (void)surface; (void)sx; (void)sy;
}

static void pointer_leave(void *data, struct wl_pointer *p, uint32_t serial,
			  struct wl_surface *surface)
{
	(void)data; (void)p; (void)serial; (void)surface;
}

static void pointer_motion(void *data, struct wl_pointer *p, uint32_t time,
			   wl_fixed_t sx, wl_fixed_t sy)
{
	(void)data; (void)p; (void)time;
	pf_tx_emitf("pointer_motion", ",\"x\":%.1f,\"y\":%.1f",
		    wl_fixed_to_double(sx), wl_fixed_to_double(sy));
}

static void pointer_button(void *data, struct wl_pointer *p, uint32_t serial,
			   uint32_t time, uint32_t button, uint32_t state)
{
	(void)data; (void)p; (void)serial; (void)time;
	pf_tx_emitf("pointer_button",
		    ",\"button\":%u,\"state\":\"%s\",\"x\":0.0,\"y\":0.0",
		    button,
		    state == WL_POINTER_BUTTON_STATE_PRESSED ? "pressed"
							     : "released");
}

static void pointer_axis(void *data, struct wl_pointer *p, uint32_t time,
			 uint32_t axis, wl_fixed_t value)
{
	(void)data; (void)p; (void)time;
	pf_tx_emitf("pointer_axis", ",\"axis\":\"%s\",\"value\":%.1f",
		    axis == WL_POINTER_AXIS_VERTICAL_SCROLL ? "vertical"
							    : "horizontal",
		    wl_fixed_to_double(value));
}

static void pointer_frame(void *data, struct wl_pointer *p)
{
	(void)data; (void)p;
}

static void pointer_axis_source(void *data, struct wl_pointer *p, uint32_t time,
				uint32_t axis, uint32_t source)
{
	(void)data; (void)p; (void)time; (void)axis; (void)source;
}

static void pointer_axis_stop(void *data, struct wl_pointer *p, uint32_t time,
			      uint32_t axis)
{
	(void)data; (void)p; (void)time; (void)axis;
}

static void pointer_axis_discrete(void *data, struct wl_pointer *p,
				  uint32_t axis, int32_t discrete)
{
	(void)data; (void)p; (void)axis; (void)discrete;
}

static const struct wl_pointer_listener pointer_listener = {
	.enter = pointer_enter,
	.leave = pointer_leave,
	.motion = pointer_motion,
	.button = pointer_button,
	.axis = pointer_axis,
	.frame = pointer_frame,
	.axis_source = pointer_axis_source,
	.axis_stop = pointer_axis_stop,
	.axis_discrete = pointer_axis_discrete,
};

static int g_have_keyboard, g_have_pointer;

static void seat_capabilities(void *data, struct wl_seat *seat, uint32_t caps)
{
	(void)data;
	if ((caps & WL_SEAT_CAPABILITY_KEYBOARD) && !g_have_keyboard) {
		g_have_keyboard = 1;
		struct wl_keyboard *kb = wl_seat_get_keyboard(seat);
		wl_keyboard_add_listener(kb, &keyboard_listener, NULL);
	}
	if ((caps & WL_SEAT_CAPABILITY_POINTER) && !g_have_pointer) {
		g_have_pointer = 1;
		struct wl_pointer *p = wl_seat_get_pointer(seat);
		wl_pointer_add_listener(p, &pointer_listener, NULL);
	}
}

static const struct wl_seat_listener seat_listener = {
	.capabilities = seat_capabilities,
	.name = noop,
};

static void registry_global(void *data, struct wl_registry *reg, uint32_t id,
			    const char *iface, uint32_t version)
{
	(void)data;
	if (!strcmp(iface, wl_compositor_interface.name)) {
		g_compositor = wl_registry_bind(reg, id, &wl_compositor_interface,
						version < 4 ? version : 4);
	} else if (!strcmp(iface, "wl_shm")) {
		wl_registry_shm = wl_registry_bind(reg, id, &wl_shm_interface,
						   1);
	} else if (!strcmp(iface, wl_seat_interface.name)) {
		g_seat = wl_registry_bind(reg, id, &wl_seat_interface,
					  version < 5 ? version : 5);
		wl_seat_add_listener(g_seat, &seat_listener, NULL);
	} else if (!strcmp(iface, xdg_wm_base_interface.name)) {
		g_xdg_wm_base = wl_registry_bind(
			reg, id, &xdg_wm_base_interface,
			version < 2 ? version : 2);
		xdg_wm_base_add_listener(g_xdg_wm_base, &xdg_wm_base_listener,
					 NULL);
	}
	/* Deliberately ignores zwp_text_input_manager_v3 /
	 * zwp_input_method_manager_v2: this client has no input method. */
}

static const struct wl_registry_listener registry_listener = {
	.global = registry_global,
	.global_remove = noop,
};

static void draw(void)
{
	const int width = 640, height = 480, stride = width * 4;
	struct wl_shm *shm = wl_registry_shm;
	if (!shm) {
		wl_surface_commit(g_surface);
		return;
	}
	char tmpl[] = "/tmp/pf-no-im-XXXXXX";
	int fd = mkstemp(tmpl);
	if (fd < 0) {
		wl_surface_commit(g_surface);
		return;
	}
	unlink(tmpl);
	if (ftruncate(fd, (off_t)stride * height) < 0) {
		close(fd);
		wl_surface_commit(g_surface);
		return;
	}
	uint32_t *px = mmap(NULL, (size_t)stride * height,
			    PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	if (px == MAP_FAILED) {
		close(fd);
		wl_surface_commit(g_surface);
		return;
	}
	for (int i = 0; i < width * height; i++)
		px[i] = 0xff304050; /* opaque slate */
	munmap(px, (size_t)stride * height);
	struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd,
							(int32_t)((off_t)stride * height));
	struct wl_buffer *buf =
		wl_shm_pool_create_buffer(pool, 0, width, height, stride,
					  WL_SHM_FORMAT_ARGB8888);
	wl_surface_attach(g_surface, buf, 0, 0);
	wl_surface_damage(g_surface, 0, 0, width, height);
	wl_surface_commit(g_surface);
	wl_buffer_destroy(buf);
	wl_shm_pool_destroy(pool);
	close(fd);
}

int main(int argc, char **argv)
{
	if (pf_tx_begin("no-im", "wayland", getenv("WAYLAND_DISPLAY"), argc,
			argv) != 0)
		return 1;
	signal(SIGTERM, on_sigterm);
	signal(SIGALRM, on_sigterm);
	alarm(120);

	g_display = wl_display_connect(NULL);
	if (!g_display) {
		pf_tx_emitf("error", ",\"message\":\"wl_display_connect failed\"");
		pf_tx_stop(1);
		return 1;
	}
	g_registry = wl_display_get_registry(g_display);
	wl_registry_add_listener(g_registry, &registry_listener, NULL);
	if (wl_display_roundtrip(g_display) < 0) {
		pf_tx_emitf("error", ",\"message\":\"roundtrip failed\"");
		pf_tx_stop(1);
		return 1;
	}
	if (!g_compositor || !g_xdg_wm_base || !g_seat) {
		pf_tx_emitf("error", ",\"message\":\"missing globals\"");
		pf_tx_stop(1);
		return 1;
	}
	g_surface = wl_compositor_create_surface(g_compositor);
	g_xdg_surface = xdg_wm_base_get_xdg_surface(g_xdg_wm_base, g_surface);
	xdg_surface_add_listener(g_xdg_surface, &xdg_surface_listener, NULL);
	g_toplevel = xdg_surface_get_toplevel(g_xdg_surface);
	xdg_toplevel_add_listener(g_toplevel, &xdg_toplevel_listener, NULL);
	xdg_toplevel_set_title(g_toplevel, "pf-input-harness no-im");
	draw();
	wl_display_roundtrip(g_display);

	int fd = wl_display_get_fd(g_display);
	struct timespec start;
	clock_gettime(CLOCK_MONOTONIC, &start);
	while (!g_stop) {
		while (wl_display_prepare_read(g_display) != 0)
			wl_display_dispatch_pending(g_display);
		wl_display_flush(g_display);
		struct pollfd pfd = { .fd = fd, .events = POLLIN };
		poll(&pfd, 1, 1000);
		if (pfd.revents & POLLIN)
			wl_display_read_events(g_display);
		else
			wl_display_cancel_read(g_display);
		wl_display_dispatch_pending(g_display);
		struct timespec now;
		clock_gettime(CLOCK_MONOTONIC, &now);
		if (now.tv_sec - start.tv_sec > 120)
			break;
	}

	xdg_toplevel_destroy(g_toplevel);
	xdg_surface_destroy(g_xdg_surface);
	wl_surface_destroy(g_surface);
	xdg_wm_base_destroy(g_xdg_wm_base);
	wl_seat_destroy(g_seat);
	wl_compositor_destroy(g_compositor);
	wl_registry_destroy(g_registry);
	wl_display_disconnect(g_display);
	pf_tx_stop(0);
	return 0;
}
