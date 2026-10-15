/* Private input-event writer for the hermetic gamescope harness.
 *
 * Usage: private-input --event-fd FD <keyboard|pointer>
 *
 * FD must be an inherited SOCK_SEQPACKET socket. Commands arrive on stdin;
 * each command becomes one packet containing complete native
 * struct input_event records followed by SYN_REPORT. This helper never opens
 * an input device and cannot create a kernel-visible input device.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

enum source_kind {
	SOURCE_KEYBOARD,
	SOURCE_POINTER,
};

static void fail(const char *message)
{
	fprintf(stderr, "private-input: %s\n", message);
	exit(1);
}

static int parse_fd(const char *text)
{
	char *end = NULL;
	errno = 0;
	long value = strtol(text, &end, 10);
	if (errno || !end || *end || value < 0 || value > 0x7fffffffL)
		fail("invalid --event-fd");
	if (fcntl((int)value, F_GETFD) < 0)
		fail("--event-fd is not open");
	return (int)value;
}

static struct input_event event(unsigned short type, unsigned short code,
				int value)
{
	struct input_event ev = { 0 };
	ev.type = type;
	ev.code = code;
	ev.value = value;
	return ev;
}

static void send_events(int fd, struct input_event *events, size_t count)
{
	events[count++] = event(EV_SYN, SYN_REPORT, 0);
	size_t size = count * sizeof(*events);
	ssize_t written = send(fd, events, size, MSG_NOSIGNAL);
	if (written < 0) {
		char message[160];
		snprintf(message, sizeof message, "send: %s", strerror(errno));
		fail(message);
	}
	if ((size_t)written != size)
		fail("short SOCK_SEQPACKET send");
}

static int parse_three(const char *line, const char *command, int *a, int *b)
{
	char extra;
	char format[64];
	snprintf(format, sizeof format, "%s %%d %%d %%c", command);
	return sscanf(line, format, a, b, &extra) == 2;
}

static int parse_two(const char *line, const char *command, int *value)
{
	char extra;
	char format[64];
	snprintf(format, sizeof format, "%s %%d %%c", command);
	return sscanf(line, format, value, &extra) == 1;
}

int main(int argc, char **argv)
{
	if (argc != 4 || strcmp(argv[1], "--event-fd")) {
		fprintf(stderr,
			"usage: private-input --event-fd FD <keyboard|pointer>\n");
		return 2;
	}

	int fd = parse_fd(argv[2]);
	enum source_kind kind;
	if (!strcmp(argv[3], "keyboard"))
		kind = SOURCE_KEYBOARD;
	else if (!strcmp(argv[3], "pointer"))
		kind = SOURCE_POINTER;
	else
		fail("source must be keyboard or pointer");

	char line[256];
	while (fgets(line, sizeof line, stdin)) {
		struct input_event events[3];
		int a, b;
		if (kind == SOURCE_KEYBOARD && parse_three(line, "key", &a, &b)) {
			if (a < 0 || a > KEY_MAX || (b != 0 && b != 1))
				fail("invalid key command");
			events[0] = event(EV_KEY, (unsigned short)a, b);
			send_events(fd, events, 1);
		} else if (kind == SOURCE_POINTER &&
			   parse_three(line, "abs", &a, &b)) {
			events[0] = event(EV_ABS, ABS_X, a);
			events[1] = event(EV_ABS, ABS_Y, b);
			send_events(fd, events, 2);
		} else if (kind == SOURCE_POINTER &&
			   parse_three(line, "rel", &a, &b)) {
			events[0] = event(EV_REL, REL_X, a);
			events[1] = event(EV_REL, REL_Y, b);
			send_events(fd, events, 2);
		} else if (kind == SOURCE_POINTER &&
			   parse_three(line, "btn", &a, &b)) {
			if (a < BTN_MISC || a > KEY_MAX || (b != 0 && b != 1))
				fail("invalid button command");
			events[0] = event(EV_KEY, (unsigned short)a, b);
			send_events(fd, events, 1);
		} else if (kind == SOURCE_POINTER && parse_two(line, "wheel", &a)) {
			events[0] = event(EV_REL, REL_WHEEL, a);
			send_events(fd, events, 1);
		} else {
			fail("invalid command for source");
		}
	}

	if (ferror(stdin))
		fail("stdin read failed");
	close(fd);
	return 0;
}
