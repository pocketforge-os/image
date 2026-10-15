/* XIM-only X11 client (row 'X11 XIM-only apps'). Pure Xlib: opens an XIM
 * connection if one exists, records keys verbatim, never enables a text
 * input protocol otherwise. No commits/content ever.
 */
#define _GNU_SOURCE
#include "../tools/transcript.h"

#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/keysym.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static volatile sig_atomic_t g_stop;
static Display *g_dpy;
static Window g_win;
static GC g_gc;
static char g_widget_text[64];

static void draw_widget_text(void)
{
	XClearWindow(g_dpy, g_win);
	XDrawString(g_dpy, g_win, g_gc, 48, 240, g_widget_text,
		    (int)strlen(g_widget_text));
	XFlush(g_dpy);
}

static void append_widget_text(const char *text, int length)
{
	size_t used = strlen(g_widget_text);
	if (length < 0)
		return;
	if ((size_t)length > sizeof g_widget_text - used - 1)
		length = (int)(sizeof g_widget_text - used - 1);
	memcpy(g_widget_text + used, text, (size_t)length);
	g_widget_text[used + (size_t)length] = '\0';
	draw_widget_text();
	char j[256];
	pf_tx_jstr(j, sizeof j, g_widget_text);
	pf_tx_emitf("widget_text", ",\"text\":%s", j);
}

static void on_sigterm(int sig)
{
	(void)sig;
	g_stop = 1;
}

static void on_sigalrm(int sig)
{
	(void)sig;
	g_stop = 1;
}

int main(int argc, char **argv)
{
	if (pf_tx_begin("xim-only", "x11", getenv("DISPLAY"), argc, argv) != 0)
		return 1;
	signal(SIGTERM, on_sigterm);
	struct sigaction sa;
	memset(&sa, 0, sizeof sa);
	sa.sa_handler = on_sigalrm;
	sigaction(SIGALRM, &sa, NULL);
	alarm(120);

	Display *dpy = XOpenDisplay(NULL);
	if (!dpy) {
		pf_tx_emitf("error", ",\"message\":\"XOpenDisplay failed\"");
		pf_tx_stop(1);
		return 1;
	}
	g_dpy = dpy;

	XIM xim = XOpenIM(dpy, NULL, NULL, NULL);
	if (xim)
		pf_tx_emitf("im_state",
			    ",\"protocol\":\"xim\",\"state\":\"available\"");
	else
		pf_tx_emitf("im_state",
			    ",\"protocol\":\"xim\",\"state\":\"unavailable\"");

	int screen = DefaultScreen(dpy);
	Window win = XCreateSimpleWindow(
		dpy, RootWindow(dpy, screen), 0, 0, 640, 480, 0,
		BlackPixel(dpy, screen), WhitePixel(dpy, screen));
	g_win = win;
	g_gc = XCreateGC(dpy, win, 0, NULL);
	XSetForeground(dpy, g_gc, BlackPixel(dpy, screen));
	XStoreName(dpy, win, "pf-input-harness xim-only");
	XSelectInput(dpy, win,
		     ExposureMask | KeyPressMask | KeyReleaseMask |
			     FocusChangeMask | StructureNotifyMask);
	XMapWindow(dpy, win);

	XIC xic = NULL;
	if (xim) {
		xic = XCreateIC(xim, XNInputStyle,
				XIMPreeditNothing | XIMStatusNothing,
				XNClientWindow, win, NULL);
		if (xic)
			XSetICFocus(xic);
	}

	int xfd = ConnectionNumber(dpy);
	while (!g_stop) {
		while (XPending(dpy) > 0) {
			XEvent ev;
			XNextEvent(dpy, &ev);
			if (xic && XFilterEvent(&ev, None))
				continue;
			switch (ev.type) {
			case MapNotify: {
				/* XMapEvent carries no geometry; ask X. */
				XWindowAttributes wa;
				int w = 640, h = 480;
				if (XGetWindowAttributes(dpy, ev.xmap.window,
							 &wa)) {
					w = wa.width;
					h = wa.height;
				}
				pf_tx_emitf("mapped",
					    ",\"width\":%d,\"height\":%d",
					    w, h);
				break;
			}
			case ConfigureNotify:
				/* geometry changes are not transcribed; the
				 * MapNotify size is what the harness asserts */
				break;
			case Expose:
				draw_widget_text();
				break;
			case FocusIn:
				pf_tx_emitf("enter", ",\"serial\":%lu",
					    (unsigned long)ev.xfocus.serial);
				break;
			case FocusOut:
				pf_tx_emitf("leave", ",\"serial\":%lu",
					    (unsigned long)ev.xfocus.serial);
				break;
			case KeyPress:
			case KeyRelease: {
				KeySym ks = XLookupKeysym(&ev.xkey, 0);
				const char *name = ks ? XKeysymToString(ks) : NULL;
				char j[64];
				pf_tx_jstr(j, sizeof j, name ? name : "");
				pf_tx_emitf("key",
					    ",\"keycode\":%u,\"keysym\":%s,\"state\":\"%s\",\"mods\":%u",
					    ev.xkey.keycode, j,
					    ev.type == KeyPress ? "pressed"
								: "released",
					    (unsigned)ev.xkey.state);
				if (ev.type == KeyPress) {
					char text[32];
					KeySym looked_up = NoSymbol;
					int length = XLookupString(&ev.xkey, text,
							   sizeof text, &looked_up, NULL);
					if (length > 0)
						append_widget_text(text, length);
				}
				break;
			}
			default:
				break;
			}
		}
		if (g_stop)
			break;
		struct pollfd pfd = { .fd = xfd, .events = POLLIN };
		poll(&pfd, 1, 1000);
	}

	if (xic)
		XDestroyIC(xic);
	if (xim)
		XCloseIM(xim);
	XFreeGC(dpy, g_gc);
	XDestroyWindow(dpy, win);
	XCloseDisplay(dpy);
	pf_tx_stop(0);
	return 0;
}
