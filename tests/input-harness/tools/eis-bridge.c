/* PocketForge EIS bridge: forwards uinput evdev events into gamescope's
 * headless input path over libeis (EIS_EVENT_* sender protocol).
 *
 * Usage: eis-bridge <eis-socket> <keyboard-event-node> <mouse-event-node>
 *
 * Headless gamescope has no libinput session backend, so the harness feeds
 * real kernel evdev devices (created by fake-input) through this bridge,
 * which is a libeis *sender* client. Prints READY on stdout once the
 * virtual device is emulating.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <libei.h>
#include <linux/input.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static struct ei *g_ei;
static struct ei_device *g_dev;
static int g_emulating;
static uint32_t g_seq = 1;

static void die(const char *msg)
{
	fprintf(stderr, "eis-bridge: %s: %s\n", msg, strerror(errno));
	exit(1);
}

static int open_evdev(const char *path)
{
	int fd = open(path, O_RDONLY | O_NONBLOCK);
	if (fd < 0) {
		fprintf(stderr, "eis-bridge: cannot open %s: %s\n", path,
			strerror(errno));
		exit(1);
	}
	return fd;
}

static void handle_ei_events(void)
{
	struct ei_event *event;
	while ((event = ei_get_event(g_ei)) != NULL) {
		enum ei_event_type type = ei_event_get_type(event);
		if (type == EI_EVENT_CONNECT) {
			/* wait for seat */
		} else if (type == EI_EVENT_DISCONNECT) {
			fprintf(stderr, "eis-bridge: EIS disconnected\n");
			exit(1);
		} else if (type == EI_EVENT_SEAT_ADDED) {
			struct ei_seat *seat = ei_event_get_seat(event);
			ei_seat_bind_capabilities(
				seat, EI_DEVICE_CAP_POINTER,
				EI_DEVICE_CAP_POINTER_ABSOLUTE,
				EI_DEVICE_CAP_KEYBOARD,
				EI_DEVICE_CAP_BUTTON,
				EI_DEVICE_CAP_SCROLL, NULL);
		} else if (type == EI_EVENT_DEVICE_ADDED) {
			if (g_dev)
				g_dev = ei_device_unref(g_dev);
			g_dev = ei_device_ref(ei_event_get_device(event));
		} else if (type == EI_EVENT_DEVICE_REMOVED) {
			if (ei_event_get_device(event) == g_dev)
				g_dev = ei_device_unref(g_dev);
			g_emulating = 0;
		} else if (type == EI_EVENT_DEVICE_PAUSED) {
			g_emulating = 0;
		} else if (type == EI_EVENT_DEVICE_RESUMED) {
			if (g_dev && !g_emulating) {
				ei_device_start_emulating(g_dev, g_seq++);
				g_emulating = 1;
				printf("READY\n");
				fflush(stdout);
			}
		}
		ei_event_unref(event);
	}
}

static void forward_keyboard(int fd)
{
	struct input_event ev[16];
	ssize_t n = read(fd, ev, sizeof ev);
	if (n <= 0)
		return;
	for (ssize_t i = 0; i + (ssize_t)sizeof(struct input_event) <= n;
	     i += sizeof(struct input_event)) {
		const struct input_event *e =
			(const struct input_event *)((char *)ev + i);
		if (e->type != EV_KEY || !g_emulating)
			continue;
		if (e->value != 0 && e->value != 1)
			continue;
		ei_device_keyboard_key(g_dev, e->code, e->value == 1);
		ei_device_frame(g_dev, ei_now(g_ei));
	}
}

static void forward_mouse(int fd)
{
	struct input_event ev[64];
	ssize_t n = read(fd, ev, sizeof ev);
	if (n <= 0)
		return;
	int have = 0;
	static int last_x = -1, last_y = -1;
	for (ssize_t i = 0; i + (ssize_t)sizeof(struct input_event) <= n;
	     i += sizeof(struct input_event)) {
		const struct input_event *e =
			(const struct input_event *)((char *)ev + i);
		if (!g_emulating)
			continue;
		if (e->type == EV_REL) {
			if (e->code == REL_X || e->code == REL_Y) {
				ei_device_pointer_motion(
					g_dev,
					e->code == REL_X ? e->value : 0,
					e->code == REL_Y ? e->value : 0);
				have = 1;
			} else if (e->code == REL_WHEEL) {
				ei_device_scroll_discrete(g_dev, 0,
							  e->value * 120);
				have = 1;
			}
		} else if (e->type == EV_ABS) {
			if (e->code == ABS_X)
				last_x = e->value;
			else if (e->code == ABS_Y)
				last_y = e->value;
			if (last_x >= 0 && last_y >= 0) {
				ei_device_pointer_motion_absolute(
					g_dev, (double)last_x, (double)last_y);
				have = 1;
			}
		} else if (e->type == EV_KEY) {
			if (e->code == BTN_LEFT || e->code == BTN_RIGHT ||
			    e->code == BTN_MIDDLE) {
				ei_device_button_button(g_dev, e->code,
							e->value == 1);
				have = 1;
			}
		} else if (e->type == EV_SYN && e->code == SYN_REPORT &&
			   have) {
			ei_device_frame(g_dev, ei_now(g_ei));
			have = 0;
		}
	}
}

int main(int argc, char **argv)
{
	if (argc != 4) {
		fprintf(stderr,
			"usage: eis-bridge <eis-socket> <kbd-node> <mouse-node>\n");
		return 2;
	}
	g_ei = ei_new_sender(NULL);
	if (!g_ei)
		die("ei_new_sender");
	ei_configure_name(g_ei, "pocketforge-input-harness");
	ei_setup_backend_socket(g_ei, argv[1]);

	int kfd = open_evdev(argv[2]);
	int mfd = open_evdev(argv[3]);
	int efd = ei_get_fd(g_ei);

	for (;;) {
		struct pollfd pfds[3] = {
			{ .fd = efd, .events = POLLIN },
			{ .fd = kfd, .events = POLLIN },
			{ .fd = mfd, .events = POLLIN },
		};
		int rc = poll(pfds, 3, -1);
		if (rc < 0) {
			if (errno == EINTR)
				continue;
			die("poll");
		}
		if (pfds[0].revents & POLLIN) {
			ei_dispatch(g_ei);
			handle_ei_events();
		}
		if (pfds[1].revents & POLLIN)
			forward_keyboard(kfd);
		if (pfds[2].revents & POLLIN)
			forward_mouse(mfd);
	}
	return 0;
}
