/*
 * This library module implements unpacking of GSM 7-bit data
 * from packed octets.
 */

#include <sys/types.h>

static u_char shift[8] = {0, 7, 6, 5, 4, 3, 2, 1};

gsm7_unpack(inbuf, outbuf, nseptets)
	u_char *inbuf, *outbuf;
	unsigned nseptets;
{
	u_char *inp = inbuf, *outp = outbuf;
	unsigned n;

	for (n = 0; n < nseptets; n++) {
		*outp++ = (((inp[1] << 8) | inp[0]) >> shift[n&7]) & 0x7F;
		if (n & 7)
			inp++;
	}
}
