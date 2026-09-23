CC ?= cc
CFLAGS ?= -O2
CPPFLAGS ?=
LDFLAGS ?=

all: xr829-hciattach

xr829-hciattach: main.c hciattach_xradio.c hciattach.h
	$(CC) $(CPPFLAGS) $(CFLAGS) -std=gnu11 -Wall -Wextra \
		-Wno-unused-parameter -Wno-unused-function $(LDFLAGS) \
		-o $@ main.c hciattach_xradio.c

clean:
	find . -maxdepth 1 -type f -name xr829-hciattach -delete

.PHONY: all clean
