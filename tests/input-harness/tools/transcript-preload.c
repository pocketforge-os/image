#define _GNU_SOURCE
#include "transcript.h"

#include <dlfcn.h>
#include <stdint.h>
#include <string.h>
#include <wayland-client-core.h>
#include <wayland-client-protocol.h>

typedef struct wl_proxy *(*marshal_flags_ctor_t)(struct wl_proxy *, uint32_t,
						 uint32_t, uint32_t,
						 const struct wl_interface *,
						 uint32_t, union wl_argument *);
typedef int (*roundtrip_t)(struct wl_display *);
typedef int (*dispatch_t)(struct wl_display *);

static marshal_flags_ctor_t real_marshal_flags_ctor;
static roundtrip_t real_roundtrip;
static dispatch_t real_dispatch;
static int ti_v3_available;
static int ti_v3_unavailable_emitted;

struct im_protocol {
	const char *iface;
	const char *name;
	int emitted;
};

static struct im_protocol g_protocols[] = {
	{ "zwp_text_input_manager_v3", "text-input-v3", 0 },
	{ "zwp_input_method_manager_v2", "input-method-v2", 0 },
	{ "gamescope_input_method_manager", "gamescope-input-method", 0 },
	{ NULL, NULL, 0 },
};

static void ensure_real(void)
{
	if (!real_marshal_flags_ctor)
		real_marshal_flags_ctor = (marshal_flags_ctor_t)dlsym(
			RTLD_NEXT,
			"wl_proxy_marshal_array_flags_constructor_versioned");
}

static void note_bind(const char *iface)
{
	if (!iface)
		return;
	for (struct im_protocol *p = g_protocols; p->iface; p++) {
		if (!strcmp(iface, p->iface)) {
			if (!p->emitted) {
				p->emitted = 1;
				if (!strcmp(p->name, "text-input-v3"))
					ti_v3_available = 1;
				pf_tx_emitf("im_state",
					    ",\"protocol\":\"%s\",\"state\":\"available\"",
					    p->name);
			}
			return;
		}
	}
}

static void maybe_emit_ti_unavailable(void)
{
	if (ti_v3_available || ti_v3_unavailable_emitted)
		return;
	ti_v3_unavailable_emitted = 1;
	pf_tx_emitf("im_state",
		    ",\"protocol\":\"text-input-v3\",\"state\":\"unavailable\"");
}

struct wl_proxy *
wl_proxy_marshal_array_flags_constructor_versioned(
	struct wl_proxy *proxy, uint32_t opcode, uint32_t version,
	uint32_t flags, const struct wl_interface *interface, uint32_t n_args,
	union wl_argument *args)
{
	ensure_real();
	const char *cls = proxy ? wl_proxy_get_class(proxy) : NULL;
	if (cls && !strcmp(cls, "wl_registry") &&
	    opcode == WL_REGISTRY_BIND && n_args >= 2 && args)
		note_bind(args[1].s);
	return real_marshal_flags_ctor(proxy, opcode, version, flags,
				       interface, n_args, args);
}

int
wl_display_roundtrip(struct wl_display *display)
{
	if (!real_roundtrip)
		real_roundtrip = (roundtrip_t)dlsym(RTLD_NEXT,
						    "wl_display_roundtrip");
	int rc = real_roundtrip(display);
	if (rc >= 0)
		maybe_emit_ti_unavailable();
	return rc;
}

int
wl_display_roundtrip_queue(struct wl_display *display, struct wl_event_queue *queue)
{
	typedef int (*rtq_t)(struct wl_display *, struct wl_event_queue *);
	static rtq_t real_rtq;
	if (!real_rtq)
		real_rtq = (rtq_t)dlsym(RTLD_NEXT, "wl_display_roundtrip_queue");
	int rc = real_rtq(display, queue);
	if (rc >= 0)
		maybe_emit_ti_unavailable();
	return rc;
}

int
wl_display_dispatch(struct wl_display *display)
{
	if (!real_dispatch)
		real_dispatch = (dispatch_t)dlsym(RTLD_NEXT,
						  "wl_display_dispatch");
	int rc = real_dispatch(display);
	if (rc > 0)
		maybe_emit_ti_unavailable();
	return rc;
}

struct wl_cursor;
struct wl_cursor_theme;

typedef struct wl_cursor *(*get_cursor_t)(struct wl_cursor_theme *,
					  const char *);

struct wl_cursor *
wl_cursor_theme_get_cursor(struct wl_cursor_theme *theme, const char *name)
{
	static get_cursor_t real_get_cursor;
	if (!real_get_cursor)
		real_get_cursor = (get_cursor_t)dlsym(
			RTLD_NEXT, "wl_cursor_theme_get_cursor");
	if (name) {
		char j[128];
		pf_tx_jstr(j, sizeof j, name);
		pf_tx_emitf("cursor", ",\"name\":%s", j);
	}
	return real_get_cursor(theme, name);
}
