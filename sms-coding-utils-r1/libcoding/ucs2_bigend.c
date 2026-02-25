/*
 * This library module implements the function for converting a UCS-2
 * string from native 16-bit words into a byte buffer for SMS.
 */

#include <sys/types.h>

ucs2_out_bigend(inbuf, outbuf, nuni)
	u_short *inbuf;
	u_char *outbuf;
	unsigned nuni;
{
	u_short *ip = inbuf;
	u_char *op = outbuf;
	unsigned n, uni;

	for (n = 0; n < nuni; n++) {
		uni = *ip++;
		*op++ = uni >> 8;
		*op++ = uni;
	}
}
