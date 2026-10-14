#define _GNU_SOURCE
#include "transcript.h"

#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define SCHEMA_ID "pf-input-harness.transcript/v1"
#define MAX_PENDING 64
#define MAX_LINE 8192

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static FILE *g_fp;
static char g_client[64];
static long g_seq;
static struct timespec g_t0;
static int g_have_t0;
static char *g_pending[MAX_PENDING];
static int g_pending_n;
static char g_stop_line[MAX_LINE];
static int g_stop_fd = -1;

static long long now_us(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	if (!g_have_t0) {
		g_t0 = ts;
		g_have_t0 = 1;
	}
	return (long long)(ts.tv_sec - g_t0.tv_sec) * 1000000LL +
	       (ts.tv_nsec - g_t0.tv_nsec) / 1000;
}

void pf_tx_jstr(char *out, size_t outsz, const char *s)
{
	size_t o = 0;
	if (o + 1 < outsz)
		out[o++] = '"';
	for (; s && *s; s++) {
		unsigned char c = (unsigned char)*s;
		const char *esc = NULL;
		char buf[8];
		switch (c) {
		case '"': esc = "\\\""; break;
		case '\\': esc = "\\\\"; break;
		case '\n': esc = "\\n"; break;
		case '\r': esc = "\\r"; break;
		case '\t': esc = "\\t"; break;
		case '\b': esc = "\\b"; break;
		case '\f': esc = "\\f"; break;
		default:
			if (c < 0x20) {
				snprintf(buf, sizeof buf, "\\u%04x", c);
				esc = buf;
			}
			break;
		}
		if (esc) {
			for (; *esc && o + 1 < outsz; )
				out[o++] = *esc++;
		} else if (o + 1 < outsz) {
			out[o++] = (char)c;
		}
	}
	if (o + 1 < outsz)
		out[o++] = '"';
	out[o < outsz ? o : outsz - 1] = '\0';
}

/* Caller must hold g_lock. Queue "event<fields>\n" verbatim for replay by
 * flush_pending_locked() once the transcript file is open. */
static void queue_pending_locked(const char *event, const char *fields)
{
	if (g_pending_n >= MAX_PENDING)
		return;
	size_t evlen = strlen(event);
	size_t fldlen = fields ? strlen(fields) : 0;
	char *copy = malloc(evlen + fldlen + 2);
	if (!copy)
		return;
	memcpy(copy, event, evlen);
	if (fldlen)
		memcpy(copy + evlen, fields, fldlen);
	copy[evlen + fldlen] = '\n';
	copy[evlen + fldlen + 1] = '\0';
	g_pending[g_pending_n++] = copy;
}

/* Caller must hold g_lock. Builds and writes one envelope line. */
static void emit_locked(const char *event, const char *fields)
{
	char line[MAX_LINE];
	if (!g_fp) {
		queue_pending_locked(event, fields);
		return;
	}
	snprintf(line, sizeof line,
		 "{\"schema\":\"%s\",\"client\":\"%s\",\"seq\":%ld,\"t_mono_us\":%lld,\"event\":\"%s\"%s}\n",
		 SCHEMA_ID, g_client, ++g_seq, now_us(), event,
		 fields ? fields : "");
	fputs(line, g_fp);
	fflush(g_fp);
}

static void flush_pending_locked(void)
{
	for (int i = 0; i < g_pending_n; i++) {
		char *p = g_pending[i];
		const char *nl = strchr(p, '\n');
		size_t evlen = nl ? (size_t)(nl - p) : strlen(p);
		char *ev = strndup(p, evlen);
		if (!ev) {
			free(p);
			continue;
		}
		/* split stored form "event,fields" */
		char *comma = strchr(ev, ',');
		const char *fields = comma;
		if (comma)
			*comma = '\0';
		emit_locked(ev, fields);
		free(ev);
		free(p);
	}
	g_pending_n = 0;
}

void pf_tx_emitf(const char *event, const char *fmt, ...)
{
	char fields[MAX_LINE];
	fields[0] = '\0';
	if (fmt && *fmt) {
		va_list ap;
		va_start(ap, fmt);
		vsnprintf(fields, sizeof fields, fmt, ap);
		va_end(ap);
	}
	pthread_mutex_lock(&g_lock);
	if (!g_fp) {
		/* queue as "event<fields>\n" so flush can replay verbatim */
		queue_pending_locked(event, fields);
		pthread_mutex_unlock(&g_lock);
		return;
	}
	emit_locked(event, fields);
	pthread_mutex_unlock(&g_lock);
}

static void build_stop_line(int rc)
{
	snprintf(g_stop_line, sizeof g_stop_line,
		 "{\"schema\":\"%s\",\"client\":\"%s\",\"seq\":%ld,\"t_mono_us\":%lld,\"event\":\"stop\",\"rc\":%d}\n",
		 SCHEMA_ID, g_client, g_seq + 1, now_us(), rc);
}

void pf_tx_stop(int rc)
{
	pthread_mutex_lock(&g_lock);
	if (!g_fp) {
		pthread_mutex_unlock(&g_lock);
		return;
	}
	build_stop_line(rc);
	fputs(g_stop_line, g_fp);
	fflush(g_fp);
	fclose(g_fp);
	g_fp = NULL;
	g_stop_fd = -1;
	pthread_mutex_unlock(&g_lock);
}

static void sigterm_handler(int sig)
{
	(void)sig;
	pthread_mutex_lock(&g_lock);
	if (g_fp && g_stop_fd >= 0) {
		build_stop_line(0);
		g_seq++;
		ssize_t ignored = write(g_stop_fd, g_stop_line, strlen(g_stop_line));
		(void)ignored;
		fflush(g_fp);
	}
	pthread_mutex_unlock(&g_lock);
	_exit(0);
}

void pf_tx_arm_sigterm(void)
{
	struct sigaction sa;
	memset(&sa, 0, sizeof sa);
	sa.sa_handler = sigterm_handler;
	sigaction(SIGTERM, &sa, NULL);
}

int pf_tx_begin(const char *client, const char *backend, const char *display,
		int argc, char **argv)
{
	pthread_mutex_lock(&g_lock);
	snprintf(g_client, sizeof g_client, "%s", client);
	now_us();

	const char *dir = getenv("PF_TRANSCRIPT_DIR");
	if (!dir || !*dir) {
		fprintf(stderr, "pf_tx_begin: PF_TRANSCRIPT_DIR not set\n");
		pthread_mutex_unlock(&g_lock);
		return -1;
	}
	char path[512];
	snprintf(path, sizeof path, "%s/%s.jsonl", dir, client);
	g_fp = fopen(path, "w");
	if (!g_fp) {
		fprintf(stderr, "pf_tx_begin: cannot open %s: %s\n", path,
			strerror(errno));
		pthread_mutex_unlock(&g_lock);
		return -1;
	}
	g_stop_fd = fileno(g_fp);

	char jdisplay[256], argvs[MAX_LINE];
	pf_tx_jstr(jdisplay, sizeof jdisplay, display ? display : "");
	size_t off = 0;
	off += snprintf(argvs + off, sizeof argvs - off, "[");
	for (int i = 0; i < argc && off + 128 < sizeof argvs; i++) {
		char j[128];
		pf_tx_jstr(j, sizeof j, argv[i]);
		off += snprintf(argvs + off, sizeof argvs - off, "%s%s",
				i ? "," : "", j);
	}
	off += snprintf(argvs + off, sizeof argvs - off, "]");

	g_seq = 0;
	fprintf(g_fp,
		"{\"schema\":\"%s\",\"client\":\"%s\",\"seq\":%ld,\"t_mono_us\":%lld,\"event\":\"start\",\"pid\":%d,\"argv\":%s,\"backend\":\"%s\",\"display\":%s}\n",
		SCHEMA_ID, g_client, ++g_seq, now_us(), (int)getpid(),
		argvs, backend, jdisplay);
	fflush(g_fp);
	flush_pending_locked();
	pthread_mutex_unlock(&g_lock);
	return 0;
}

FILE *pf_tx_file(void)
{
	pthread_mutex_lock(&g_lock);
	FILE *fp = g_fp;
	pthread_mutex_unlock(&g_lock);
	return fp;
}
