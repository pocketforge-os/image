/* PocketForge fake input device daemon (uinput).
 *
 * Usage: fake-input <pad|keyboard|mouse>
 *
 * Creates a uinput device, prints one JSON line on stdout:
 *   {"kind":"pad","name":"...","event_node":"/dev/input/eventN"}
 * then reads line commands from stdin until EOF:
 *   keyboard: key <evdev-code> <1|0>
 *   mouse:    rel <dx> <dy> | abs <x> <y> | btn <code> <1|0> | wheel <v>
 *   pad:      btn <code> <1|0> | abs <axis-name-or-code> <val>
 * On EOF the device is destroyed and the daemon exits 0.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <linux/uinput.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#ifndef UI_CREATE
#define UI_CREATE _IO('U', 1)
#endif

static int g_fd = -1;

static void die(const char *msg)
{
	fprintf(stderr, "fake-input: %s: %s\n", msg, strerror(errno));
	exit(1);
}

static void wr(const struct input_event *ev)
{
	if (write(g_fd, ev, sizeof *ev) != sizeof *ev)
		die("write event");
}

static void syn(void)
{
	struct input_event ev = { 0 };
	ev.type = EV_SYN;
	ev.code = SYN_REPORT;
	wr(&ev);
}

static void emit_event(int type, int code, int value)
{
	struct input_event ev = { 0 };
	ev.type = type;
	ev.code = code;
	ev.value = value;
	wr(&ev);
}

static void find_event_node(const char *sysname, char *out, size_t outsz)
{
	char dir[256];
	/* sysname is like "input42"; resolve its device dir */
	snprintf(dir, sizeof dir, "/sys/devices/virtual/input/%s", sysname);
	char cmd[512];
	snprintf(cmd, sizeof cmd,
		 "ls %s 2>/dev/null | grep -m1 '^event'", dir);
	FILE *fp = popen(cmd, "r");
	if (fp) {
		char name[64];
		if (fgets(name, sizeof name, fp)) {
			name[strcspn(name, "\n")] = '\0';
			snprintf(out, outsz, "/dev/input/%s", name);
		}
		pclose(fp);
	}
	if (!out[0])
		fprintf(stderr, "fake-input: cannot find event node for %s\n",
			sysname);
}

int main(int argc, char **argv)
{
	if (argc != 2) {
		fprintf(stderr, "usage: fake-input <pad|keyboard|mouse>\n");
		return 2;
	}
	const char *kind = argv[1];

	struct uinput_setup usetup = { 0 };
	g_fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK);
	if (g_fd < 0)
		die("open /dev/uinput");
	if (ioctl(g_fd, UI_SET_EVBIT, EV_KEY) < 0)
		die("UI_SET_EVBIT EV_KEY");

	if (!strcmp(kind, "keyboard")) {
		for (int c = 1; c < 256; c++)
			if (ioctl(g_fd, UI_SET_KEYBIT, c) < 0)
				die("UI_SET_KEYBIT");
		snprintf(usetup.name, UINPUT_MAX_NAME_SIZE,
			 "PocketForge Fake Keyboard");
	} else if (!strcmp(kind, "mouse")) {
		if (ioctl(g_fd, UI_SET_EVBIT, EV_REL) < 0)
			die("UI_SET_EVBIT EV_REL");
		if (ioctl(g_fd, UI_SET_EVBIT, EV_ABS) < 0)
			die("UI_SET_EVBIT EV_ABS");
		ioctl(g_fd, UI_SET_RELBIT, REL_X);
		ioctl(g_fd, UI_SET_RELBIT, REL_Y);
		ioctl(g_fd, UI_SET_RELBIT, REL_WHEEL);
		ioctl(g_fd, UI_SET_KEYBIT, BTN_LEFT);
		ioctl(g_fd, UI_SET_KEYBIT, BTN_RIGHT);
		ioctl(g_fd, UI_SET_KEYBIT, BTN_MIDDLE);
		struct uinput_abs_setup ax = { 0 };
		struct uinput_abs_setup ay = { 0 };
		ax.code = ABS_X;
		ax.absinfo.minimum = 0;
		ax.absinfo.maximum = 1279;
		ax.absinfo.resolution = 1;
		ay.code = ABS_Y;
		ay.absinfo.minimum = 0;
		ay.absinfo.maximum = 719;
		ay.absinfo.resolution = 1;
		if (ioctl(g_fd, UI_SET_ABSBIT, ABS_X) < 0)
			die("UI_SET_ABSBIT ABS_X");
		if (ioctl(g_fd, UI_SET_ABSBIT, ABS_Y) < 0)
			die("UI_SET_ABSBIT ABS_Y");
		if (ioctl(g_fd, UI_ABS_SETUP, &ax) < 0)
			die("UI_ABS_SETUP ABS_X");
		if (ioctl(g_fd, UI_ABS_SETUP, &ay) < 0)
			die("UI_ABS_SETUP ABS_Y");
		snprintf(usetup.name, UINPUT_MAX_NAME_SIZE,
			 "PocketForge Fake Mouse");
	} else if (!strcmp(kind, "pad")) {
		if (ioctl(g_fd, UI_SET_EVBIT, EV_ABS) < 0)
			die("UI_SET_EVBIT EV_ABS");
		int keys[] = { BTN_GAMEPAD, BTN_SOUTH, BTN_EAST, BTN_NORTH,
			       BTN_WEST, BTN_TL, BTN_TR, BTN_TL2, BTN_TR2,
			       BTN_SELECT, BTN_START, BTN_MODE, BTN_THUMBL,
			       BTN_THUMBR, BTN_DPAD_UP, BTN_DPAD_DOWN,
			       BTN_DPAD_LEFT, BTN_DPAD_RIGHT };
		for (size_t i = 0; i < sizeof keys / sizeof keys[0]; i++)
			if (ioctl(g_fd, UI_SET_KEYBIT, keys[i]) < 0)
				die("UI_SET_KEYBIT pad");
		int axes[] = { ABS_X, ABS_Y, ABS_RX, ABS_RY, ABS_Z, ABS_HAT0X,
			       ABS_HAT0Y };
		for (size_t i = 0; i < sizeof axes / sizeof axes[0]; i++) {
			struct uinput_abs_setup as = { 0 };
			as.code = axes[i];
			if (axes[i] == ABS_HAT0X || axes[i] == ABS_HAT0Y) {
				as.absinfo.minimum = -1;
				as.absinfo.maximum = 1;
			} else {
				as.absinfo.minimum = -32768;
				as.absinfo.maximum = 32767;
			}
			as.absinfo.resolution = 1;
			if (ioctl(g_fd, UI_SET_ABSBIT, axes[i]) < 0)
				die("UI_SET_ABSBIT pad");
			if (ioctl(g_fd, UI_ABS_SETUP, &as) < 0)
				die("UI_ABS_SETUP pad");
		}
		snprintf(usetup.name, UINPUT_MAX_NAME_SIZE,
			 "PocketForge Fake Pad");
	} else {
		fprintf(stderr, "fake-input: unknown kind %s\n", kind);
		return 2;
	}

	usetup.id.bustype = BUS_USB;
	usetup.id.vendor = 0x0f0f; /* PocketForge test vendor */
	usetup.id.product = 0x1202;
	if (ioctl(g_fd, UI_DEV_SETUP, &usetup) < 0)
		die("UI_DEV_SETUP");
	if (ioctl(g_fd, UI_CREATE) < 0)
		die("UI_CREATE");

	char sysname[64] = "";
	if (ioctl(g_fd, UI_GET_SYSNAME(64), sysname) < 0)
		fprintf(stderr, "fake-input: UI_GET_SYSNAME: %s\n",
			strerror(errno));
	char node[128] = "";
	if (sysname[0])
		find_event_node(sysname, node, sizeof node);
	usleep(100000); /* let the kernel settle */

	printf("{\"kind\":\"%s\",\"name\":\"%s\",\"event_node\":\"%s\"}\n",
	       kind, usetup.name, node);
	fflush(stdout);

	char line[256];
	while (fgets(line, sizeof line, stdin)) {
		char cmd[32];
		long a = 0, b = 0;
		if (sscanf(line, "%31s", cmd) != 1)
			continue;
		if (!strcmp(cmd, "key") || !strcmp(cmd, "btn")) {
			if (sscanf(line, "%*s %ld %ld", &a, &b) != 2)
				continue;
			emit_event(EV_KEY, (int)a, b ? 1 : 0);
			syn();
		} else if (!strcmp(cmd, "rel")) {
			if (sscanf(line, "%*s %ld %ld", &a, &b) != 2)
				continue;
			emit_event(EV_REL, REL_X, (int)a);
			emit_event(EV_REL, REL_Y, (int)b);
			syn();
		} else if (!strcmp(cmd, "abs")) {
			char axis[32];
			long v = 0, v2 = 0;
			int n = sscanf(line, "%*s %31s %ld %ld", axis, &v, &v2);
			if (n < 2)
				continue;
			if (axis[0] >= '0' && axis[0] <= '9') {
				/* mouse form: abs <x> <y> */
				emit_event(EV_ABS, ABS_X, atoi(axis));
				emit_event(EV_ABS, ABS_Y, (int)v);
			} else {
				/* pad form: abs <axis-name> <val> */
				int code = -1;
				if (!strcmp(axis, "x")) code = ABS_X;
				else if (!strcmp(axis, "y")) code = ABS_Y;
				else if (!strcmp(axis, "rx")) code = ABS_RX;
				else if (!strcmp(axis, "ry")) code = ABS_RY;
				else if (!strcmp(axis, "z")) code = ABS_Z;
				else if (!strcmp(axis, "hat0x")) code = ABS_HAT0X;
				else if (!strcmp(axis, "hat0y")) code = ABS_HAT0Y;
				if (code < 0)
					continue;
				emit_event(EV_ABS, code, (int)v);
			}
			syn();
		} else if (!strcmp(cmd, "wheel")) {
			if (sscanf(line, "%*s %ld", &a) != 1)
				continue;
			emit_event(EV_REL, REL_WHEEL, (int)a);
			syn();
		}
	}

	if (ioctl(g_fd, UI_DEV_DESTROY) < 0)
		fprintf(stderr, "fake-input: UI_DEV_DESTROY: %s\n",
			strerror(errno));
	close(g_fd);
	return 0;
}
