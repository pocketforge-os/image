#ifndef PF_TRANSCRIPT_H
#define PF_TRANSCRIPT_H

#include <stddef.h>
#include <stdio.h>

/* Writer for pf-input-harness.transcript/v1 (see schema/transcript-schema.md).
 *
 * Built as libpf-transcript.so so that a test client and the interposing
 * libpf-transcript-preload.so in the same process share ONE sequence
 * counter and one output file.
 *
 * The transcript path is $PF_TRANSCRIPT_DIR/<client>.jsonl. Events emitted
 * before pf_tx_begin() (e.g. by the preload library during early startup)
 * are queued and flushed right after the start event.
 */

#ifdef __cplusplus
extern "C" {
#endif

/* Open the transcript and emit the start event (always line 1).
 * backend: "wayland" | "x11" | "headless". display: WAYLAND_DISPLAY or
 * DISPLAY value the client connected to. */
int pf_tx_begin(const char *client, const char *backend,
                const char *display, int argc, char **argv);

/* Emit the stop event and close the file. Must be the last event. */
void pf_tx_stop(int rc);

/* Install a SIGTERM handler that emits stop{rc:0} and exits 0, so the
 * session driver can end a client cleanly at any point. */
void pf_tx_arm_sigterm(void);

/* Emit one event. fmt may be NULL/"" or must start with ',' and contain
 * the event's JSON fields, e.g.
 *   pf_tx_emitf("key", ",\"keycode\":%u,\"keysym\":\"%s\",...", ...) */
void pf_tx_emitf(const char *event, const char *fmt, ...);

/* JSON-escape s into out (NUL-terminated, including quotes); truncates
 * safely. */
void pf_tx_jstr(char *out, size_t outsz, const char *s);

/* Raw file handle (only for deliberately-broken negative-control clients).
 * Returns NULL before pf_tx_begin(). */
FILE *pf_tx_file(void);

#ifdef __cplusplus
}
#endif

#endif /* PF_TRANSCRIPT_H */
