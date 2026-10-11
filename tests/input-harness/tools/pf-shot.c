/* PocketForge trusted screenshot tool.
 *
 * Usage: pf-shot <path> [type]        (default type 4 = screen_buffer)
 *
 * gamescopectl cannot select a screenshot type: its Execute() forwards
 * only two strings over gamescope_private (name + one argument), so
 * `gamescopectl screenshot <path> 4` drops the "4" and the compositor's
 * cc_screenshot console command falls back to base_plane_only (type 1),
 * without overlays and without waiting for the write. This tool binds the
 * privileged gamescope_control global — visible only on trusted,
 * broker-issued connections, which the mangoapp relay provides — calls
 * take_screenshot with the requested type, and waits for the
 * screenshot_taken event, which the compositor broadcasts after the PNG
 * is on disk.
 *
 * Screenshot types (protocol/gamescope-control.xml, since v3):
 *   1 base_plane_only | 2 all_real_layers | 3 full_composition |
 *   4 screen_buffer (the buffer displayed on-screen, 1:1)
 */
#define _GNU_SOURCE
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <wayland-client.h>
#include "gamescope-control-client-protocol.h"

#define TIMEOUT_SECONDS 60

static struct gamescope_control *g_gc;
static uint32_t g_gc_version;
static int g_taken;
static char g_taken_path[1024];

static void gc_feature_support(void *data, struct gamescope_control *gc,
			       uint32_t feature, uint32_t version,
			       uint32_t flags)
{
	(void)data; (void)gc; (void)feature; (void)version; (void)flags;
}

static void gc_active_display_info(void *data, struct gamescope_control *gc,
				   const char *connector, const char *make,
				   const char *model, uint32_t flags,
				   struct wl_array *rates)
{
	(void)data; (void)gc; (void)connector; (void)make; (void)model;
	(void)flags; (void)rates;
}

static void gc_screenshot_taken(void *data, struct gamescope_control *gc,
				const char *path)
{
	(void)data; (void)gc;
	g_taken = 1;
	snprintf(g_taken_path, sizeof g_taken_path, "%s", path ? path : "");
}

static void gc_app_performance_stats(void *data, struct gamescope_control *gc,
				     uint32_t appid, uint32_t lo, uint32_t hi)
{
	(void)data; (void)gc; (void)appid; (void)lo; (void)hi;
}

static const struct gamescope_control_listener gc_listener = {
	.feature_support = gc_feature_support,
	.active_display_info = gc_active_display_info,
	.screenshot_taken = gc_screenshot_taken,
	.app_performance_stats = gc_app_performance_stats,
};

static void reg_global(void *data, struct wl_registry *reg, uint32_t name,
		       const char *iface, uint32_t version)
{
	(void)data;
	if (strcmp(iface, gamescope_control_interface.name) == 0 && !g_gc) {
		/* Bind at exactly v3: take_screenshot/screenshot_taken exist
		 * from v3, and a v3 binding never receives v4+ events. */
		g_gc_version = version < 3 ? version : 3;
		g_gc = wl_registry_bind(reg, name, &gamescope_control_interface,
					g_gc_version);
		gamescope_control_add_listener(g_gc, &gc_listener, NULL);
	}
}

static void reg_global_remove(void *data, struct wl_registry *reg,
			      uint32_t name)
{
	(void)data; (void)reg; (void)name;
}

static const struct wl_registry_listener reg_listener = {
	.global = reg_global,
	.global_remove = reg_global_remove,
};

int main(int argc, char **argv)
{
	if (argc < 2 || argc > 3) {
		fprintf(stderr, "usage: pf-shot <path> [type]\n");
		return 2;
	}
	const char *path = argv[1];
	uint32_t type = argc > 2 ? (uint32_t)strtoul(argv[2], NULL, 10) : 4;
	if (type < 1 || type > 4) {
		fprintf(stderr, "pf-shot: type must be 1..4, got %u\n", type);
		return 2;
	}

	/* The relay exports the trusted fd as WAYLAND_SOCKET; connect(NULL)
	 * honours it (and falls back to WAYLAND_DISPLAY). */
	struct wl_display *dpy = wl_display_connect(NULL);
	if (!dpy) {
		fprintf(stderr, "pf-shot: cannot connect to the compositor\n");
		return 1;
	}
	struct wl_registry *reg = wl_display_get_registry(dpy);
	wl_registry_add_listener(reg, &reg_listener, NULL);
	wl_display_roundtrip(dpy);
	if (!g_gc) {
		fprintf(stderr,
			"pf-shot: gamescope_control unavailable (needs a trusted connection)\n");
		return 1;
	}
	if (g_gc_version < 3) {
		fprintf(stderr,
			"pf-shot: gamescope_control v%u < 3, no take_screenshot\n",
			g_gc_version);
		return 1;
	}

	gamescope_control_take_screenshot(g_gc, path, type, 0);
	wl_display_flush(dpy);

	struct timespec start, now;
	clock_gettime(CLOCK_MONOTONIC, &start);
	int fd = wl_display_get_fd(dpy);
	while (!g_taken) {
		struct pollfd pfd = { .fd = fd, .events = POLLIN };
		int rc = poll(&pfd, 1, 1000);
		if (rc > 0 && wl_display_dispatch(dpy) < 0) {
			fprintf(stderr, "pf-shot: dispatch error\n");
			return 1;
		}
		clock_gettime(CLOCK_MONOTONIC, &now);
		if (now.tv_sec - start.tv_sec > TIMEOUT_SECONDS) {
			fprintf(stderr,
				"pf-shot: no screenshot_taken within %ds for %s\n",
				TIMEOUT_SECONDS, path);
			return 1;
		}
	}

	printf("pf-shot: %s (type %u)\n", g_taken_path, type);
	gamescope_control_destroy(g_gc);
	wl_registry_destroy(reg);
	wl_display_disconnect(dpy);
	return 0;
}
