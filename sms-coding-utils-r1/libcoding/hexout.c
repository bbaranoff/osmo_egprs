/*
 * The function implemented in this module emits hex bytes to a stdio output.
 */

#include <sys/types.h>
#include <stdio.h>

emit_hex_out(buf, buflen, outf)
	u_char *buf;
	unsigned buflen;
	FILE *outf;
{
	unsigned n;

	for (n = 0; n < buflen; n++)
		fprintf(outf, "%02X", buf[n]);
}
