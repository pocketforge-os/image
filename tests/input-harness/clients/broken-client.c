/* Deliberately broken client: the harness negative control. Emits a
 * transcript with a seq gap, an unknown event name, a field with the wrong
 * JSON type, and no stop event. The validator must flag it, and report.py
 * must confirm the negative control triggered.
 */
#define _GNU_SOURCE
#include "../tools/transcript.h"

#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv)
{
	if (pf_tx_begin("broken-client", "headless", "", argc, argv) != 0)
		return 1;
	FILE *fp = pf_tx_file();
	if (!fp)
		return 1;

	/* seq jumps from 1 (start) to 99: validator reason seq_gap */
	fprintf(fp,
		"{\"schema\":\"pf-input-harness.transcript/v1\","
		"\"client\":\"broken-client\",\"seq\":99,\"t_mono_us\":1000,"
		"\"event\":\"enter\",\"serial\":1}\n");
	/* unknown event name: validator reason unknown_event */
	fprintf(fp,
		"{\"schema\":\"pf-input-harness.transcript/v1\","
		"\"client\":\"broken-client\",\"seq\":100,\"t_mono_us\":2000,"
		"\"event\":\"bogus\"}\n");
	/* wrong field type: keycode as string -> event_field_type */
	fprintf(fp,
		"{\"schema\":\"pf-input-harness.transcript/v1\","
		"\"client\":\"broken-client\",\"seq\":101,\"t_mono_us\":3000,"
		"\"event\":\"key\",\"keycode\":\"35\",\"keysym\":\"h\","
		"\"state\":\"pressed\",\"mods\":0}\n");
	fflush(fp);
	/* exits without stop: validator reason stop_not_last */
	return 0;
}
