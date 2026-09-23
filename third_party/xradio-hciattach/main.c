/*
 * PocketForge XR829 attach wrapper.
 *
 * Copyright (C) 2026 PocketForge OS contributors
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>

#include "hciattach.h"

static int serial_fd = -1;

static speed_t baud_constant(int speed)
{
	switch (speed) {
	case 115200:
		return B115200;
#ifdef B1500000
	case 1500000:
		return B1500000;
#endif
	default:
		return 0;
	}
}

int set_speed(int fd, struct termios *ti, int speed)
{
	speed_t baud = baud_constant(speed);

	if (!baud) {
		errno = EINVAL;
		return -1;
	}
	if (cfsetospeed(ti, baud) < 0 || cfsetispeed(ti, baud) < 0)
		return -1;
	return tcsetattr(fd, TCSANOW, ti);
}

static void stop_handler(int signal_number)
{
	(void)signal_number;
	if (serial_fd >= 0)
		close(serial_fd);
	_exit(0);
}

static void timeout_handler(int signal_number)
{
	static const char message[] =
		"xr829-hciattach: initialization timed out waiting for the controller\n";
	ssize_t ignored;
	(void)signal_number;
	ignored = write(STDERR_FILENO, message, sizeof(message) - 1);
	(void)ignored;
	_exit(1);
}

int main(int argc, char **argv)
{
	struct termios ti;
	struct sigaction action = {0};
	int line_discipline = N_HCI;
	int protocol = HCI_UART_H4;
	const char *device;

	if (argc != 2) {
		fprintf(stderr, "usage: %s /dev/ttyS1\n", argv[0]);
		return 2;
	}
	device = argv[1];
	setvbuf(stdout, NULL, _IONBF, 0);
	setvbuf(stderr, NULL, _IONBF, 0);

	action.sa_handler = timeout_handler;
	sigemptyset(&action.sa_mask);
	sigaction(SIGALRM, &action, NULL);
	alarm(30);

	serial_fd = open(device, O_RDWR | O_NOCTTY);
	if (serial_fd < 0) {
		fprintf(stderr, "xr829-hciattach: cannot open %s: %s\n",
			device, strerror(errno));
		return 1;
	}
	if (tcgetattr(serial_fd, &ti) < 0) {
		fprintf(stderr, "xr829-hciattach: cannot read %s settings: %s\n",
			device, strerror(errno));
		return 1;
	}
	cfmakeraw(&ti);
	ti.c_cflag |= CLOCAL | CS8;
	ti.c_cflag &= ~(PARENB | PARODD | CSTOPB | CRTSCTS);
	if (set_speed(serial_fd, &ti, 115200) < 0) {
		fprintf(stderr, "xr829-hciattach: cannot configure %s at 115200 baud: %s\n",
			device, strerror(errno));
		return 1;
	}
	tcflush(serial_fd, TCIOFLUSH);

	if (xradio_xr829_init(serial_fd, 115200, 1500000, &ti, NULL) < 0) {
		fprintf(stderr, "xr829-hciattach: XR829 vendor initialization failed\n");
		return 1;
	}
	if (set_speed(serial_fd, &ti, 1500000) < 0) {
		fprintf(stderr, "xr829-hciattach: cannot switch %s to 1500000 baud: %s\n",
			device, strerror(errno));
		return 1;
	}
	if (ioctl(serial_fd, TIOCSETD, &line_discipline) < 0) {
		fprintf(stderr, "xr829-hciattach: cannot set N_HCI on %s: %s\n",
			device, strerror(errno));
		return 1;
	}
	if (ioctl(serial_fd, HCIUARTSETPROTO, protocol) < 0) {
		fprintf(stderr, "xr829-hciattach: cannot select H4 on %s: %s\n",
			device, strerror(errno));
		return 1;
	}

	alarm(0);
	fprintf(stderr, "xr829-hciattach: attached %s as XR829 H4 controller\n", device);
	action.sa_handler = stop_handler;
	sigaction(SIGTERM, &action, NULL);
	sigaction(SIGINT, &action, NULL);
	for (;;)
		pause();
}
