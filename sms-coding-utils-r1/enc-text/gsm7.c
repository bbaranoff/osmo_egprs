/*
 * In this module we implement SMS encoding in GSM7.
 */

#include <sys/types.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>
#include "defs.h"

extern int utf8_input, allow_escape;
extern int concat_enable, concat_refno_set;
extern char msgtext[MAX_MSG_CHARS*2+2];
extern u_char concat_refno;

gsm7_mode_main()
{
	u_char msgtext_gsm7[MAX_MSG_CHARS];
	unsigned msgtext_gsmlen;
	int rc;
	unsigned nparts, n;
	u_char udh[6];
	unsigned pos, remain, chunk;

	if (utf8_input && utf8_to_latin1(msgtext) < 0) {
		fprintf(stderr, "error: invalid UTF-8 message\n");
		exit(1);
	}
	rc = latin1_to_gsm7(msgtext, msgtext_gsm7, MAX_MSG_CHARS,
				&msgtext_gsmlen, allow_escape);
	if (rc == -1) {
		fprintf(stderr, "error: message not valid for GSM7 charset\n");
		exit(1);
	}
	if (rc == -2) {
		fprintf(stderr, "error: message too long for max concat SMS\n");
		exit(1);
	}
	if (rc == -3) {
		fprintf(stderr,
			"error: message contains invalid backslash escape\n");
		exit(1);
	}
	if (msgtext_gsmlen <= 160) {
		fputs("dcs 0 septet\nmsg ", stdout);
		if (msgtext_gsmlen)
			emit_hex_out(msgtext_gsm7, msgtext_gsmlen, stdout);
		else {
			putchar('"');
			putchar('"');
		}
		putchar('\n');
		exit(0);
	}
	if (!concat_enable) {
		fprintf(stderr, "error: message exceeds 160 chars\n");
		exit(1);
	}
	if (!concat_refno_set)
		concat_refno = get_concsms_refno_from_host_fs();
	puts("dcs 0 septet");
	nparts = (msgtext_gsmlen + 152) / 153;
	udh[0] = 5;
	udh[1] = 0x00;
	udh[2] = 0x03;
	udh[3] = concat_refno;
	udh[4] = nparts;
	pos = 0;
	remain = msgtext_gsmlen;
	for (n = 1; n <= nparts; n++) {
		udh[5] = n;
		chunk = 153;
		if (chunk > remain)
			chunk = remain;
		fputs("msg-udh ", stdout);
		emit_hex_out(udh, 6, stdout);
		emit_hex_out(msgtext_gsm7 + pos, chunk, stdout);
		putchar('\n');
		pos += chunk;
		remain -= chunk;
	}
	exit(0);
}
