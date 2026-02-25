/*
 * This library module implements decoding of GSM timestamps.
 */

#include <sys/types.h>
#include <stdio.h>

gsm_timestamp_decode(inbuf, outbuf)
	u_char *inbuf;
	char *outbuf;
{
	u_char rev[7];
	int i, d1, d2, tzsign;

	for (i = 0; i < 7; i++) {
		d1 = inbuf[i] & 0xF;
		d2 = inbuf[i] >> 4;
		rev[i] = (d1 << 4) | d2;
	}
	if (rev[6] & 0x80) {
		rev[6] &= 0x7F;
		tzsign = '-';
	} else
		tzsign = '+';
	sprintf(outbuf, "%02X/%02X/%02X,%02X:%02X:%02X%c%02X", rev[0], rev[1],
		rev[2], rev[3], rev[4], rev[5], tzsign, rev[6]);
}
