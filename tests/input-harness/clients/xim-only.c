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
	XDestroyWindow(dpy, win);
	XCloseDisplay(dpy);
	pf_tx_stop(0);
	return 0;
}
