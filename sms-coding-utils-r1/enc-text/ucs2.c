/*
 * In this module we implement SMS encoding in UCS-2.
 */

#include <sys/types.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>
#include "defs.h"

extern int allow_escape;
extern int concat_enable, concat_refno_set;
extern char msgtext[MAX_MSG_CHARS*2+2];
extern u_char concat_refno;

ucs2_mode_main()
{
	u_short msgtext_uni[MAX_MSG_UNI];
	unsigned msgtext_unilen;
	int rc;
	unsigned nparts, n;
	u_char udh[6], ucs2_be[140];
	unsigned pos, remain, chunk;

	rc = utf8_to_ucs2(msgtext, msgtext_uni, MAX_MSG_UNI, &msgtext_unilen,
			  allow_escape);
	if (rc == -1) {
		fprintf(stderr, "error: invalid UTF-8 message\n");
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
	if (msgtext_unilen <= 70) {
		fputs("dcs 8 octet\nmsg ", stdout);
		if (msgtext_unilen) {
			ucs2_out_bigend(msgtext_uni, ucs2_be, msgtext_unilen);
			emit_hex_out(ucs2_be, msgtext_unilen * 2, stdout);
		} else {
			putchar('"');
			putchar('"');
		}
		putchar('\n');
		exit(0);
	}
	if (!concat_enable) {
		fprintf(stderr, "error: message exceeds 70 UCS-2 chars\n");
		exit(1);
	}
	if (!concat_refno_set)
		concat_refno = get_concsms_refno_from_host_fs();
	puts("dcs 8 octet");
	nparts = (msgtext_unilen + 66) / 67;
	udh[0] = 5;
	udh[1] = 0x00;
	udh[2] = 0x03;
	udh[3] = concat_refno;
	udh[4] = nparts;
	pos = 0;
	remain = msgtext_unilen;
	for (n = 1; n <= nparts; n++) {
		udh[5] = n;
		chunk = 67;
		if (chunk > remain)
			chunk = remain;
		fputs("msg-udh ", stdout);
		emit_hex_out(udh, 6, stdout);
		ucs2_out_bigend(msgtext_uni + pos, ucs2_be, chunk);
		emit_hex_out(ucs2_be, chunk * 2, stdout);
		putchar('\n');
		pos += chunk;
		remain -= chunk;
	}
	exit(0);
}
