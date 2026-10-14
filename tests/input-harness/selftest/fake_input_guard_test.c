#define _GNU_SOURCE
#include "../tools/pf_uinput_domain_guard.h"

static struct pf_uinput_probe test_probe;
static int opener_calls;
static struct pf_uinput_verdict last_verdict;

static int mock_open(const char *path, int flags, void *ctx)
{
	(void)path;
	(void)flags;
	(void)ctx;
	opener_calls++;
	return 71;
}

static int test_guarded_open(const char *path, int flags,
			     pf_uinput_open_fn opener, void *ctx,
			     struct pf_uinput_verdict *reported)
{
	(void)opener;
	(void)ctx;
	int fd = pf_uinput_guarded_open_probe(&test_probe, path, flags,
					     mock_open, NULL, reported);
	last_verdict = *reported;
	return fd;
}

#define PF_FAKE_INPUT_GUARDED_OPEN test_guarded_open
#define main fake_input_program_main
#include "../tools/fake-input.c"
#undef main

static enum pf_uinput_check check(const char *s)
{
	return !strcmp(s, "yes") ? PF_CHECK_YES :
	       !strcmp(s, "no") ? PF_CHECK_NO : PF_CHECK_ERROR;
}

static enum pf_uinput_state state(const char *s)
{
	return !strcmp(s, "ok") || !strcmp(s, "valid") ? PF_STATE_OK :
	       !strcmp(s, "missing") ? PF_STATE_MISSING :
	       !strcmp(s, "invalid") ? PF_STATE_INVALID : PF_STATE_ERROR;
}

static enum pf_uinput_logind logind(const char *s)
{
	return !strcmp(s, "no-seat") || !strcmp(s, "mir-seatless") ? PF_LOGIND_NO_SEAT :
	       strstr(s, "-seat") ? PF_LOGIND_SEAT :
	       !strcmp(s, "not-probed") ? PF_LOGIND_NOT_PROBED : PF_LOGIND_UNREADABLE;
}

static int selected_case(const char *name)
{
	return !strcmp(name, "bare-metal-desktop") ||
	       !strcmp(name, "vm-wayland-seat") ||
	       !strcmp(name, "pfvd-guest") ||
	       !strcmp(name, "dut-current");
}

int main(int argc, char **argv)
{
	if (argc != 2)
		return 2;
	FILE *fixture = fopen(argv[1], "r");
	if (!fixture)
		return 2;
	char line[2048];
	if (!fgets(line, sizeof line, fixture))
		return 2;
	int tested = 0;
	while (fgets(line, sizeof line, fixture)) {
		char *field[11], *save = NULL;
		char *part = strtok_r(line, "\t\r\n", &save);
		for (int i = 0; i < 11; i++) {
			if (!part)
				return 3;
			field[i] = part;
			part = strtok_r(NULL, "\t\r\n", &save);
		}
		if (!selected_case(field[0]))
			continue;
		test_probe = (struct pf_uinput_probe) {
			check(field[1]), check(field[2]), state(field[3]),
			strstr(field[4], "pocketforge,tsp") &&
				strstr(field[4], "allwinner,sun50i-a133") &&
				strstr(field[4], "allwinner,sun50i-a100"),
			strstr(field[4], "allwinner,a133") &&
				strstr(field[4], "arm,sun50iw10p1"),
			strcmp(field[4], "-") != 0, state(field[5]), logind(field[6])
		};
		opener_calls = 0;
		errno = 0;
		int fd = fake_input_open_uinput();
		int allowed = !strcmp(field[7], "allow");
		if (allowed) {
			if (fd != 71 || opener_calls != 1)
				return 4;
		} else if (fd != -1 || errno != EPERM || opener_calls != 0 ||
			   strcmp(last_verdict.reason, "unsafe_uinput_domain") ||
			   strcmp(pf_uinput_domain_name(last_verdict.domain), field[9])) {
			return 5;
		}
		tested++;
	}
	fclose(fixture);
	printf("fake-input-guard: PASS cases=%d refused_openers=0 allowed_openers=1 device=mocked\n",
	       tested);
	return tested == 4 ? 0 : 6;
}
