#ifndef POCKETFORGE_XRADIO_HCIATTACH_H
#define POCKETFORGE_XRADIO_HCIATTACH_H

#include <stdint.h>
#include <sys/ioctl.h>
#include <termios.h>

#ifndef N_HCI
#define N_HCI 15
#endif

#define HCIUARTSETPROTO _IOW('U', 200, int)
#define HCI_UART_H4 0

int set_speed(int fd, struct termios *ti, int speed);
int xradio_xr829_init(int fd, int def_speed, int speed, struct termios *ti,
		const char *bdaddr);

#endif
