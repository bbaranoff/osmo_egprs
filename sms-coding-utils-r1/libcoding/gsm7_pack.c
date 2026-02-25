/*
 * This library module implements the function for packing septets into octets.
 */

#include <sys/types.h>

gsm7_pack(inbuf, outbuf, noctets)
	u_char *inbuf, *outbuf;
	unsigned noctets;
{
	u_char *ip = inbuf, *op = outbuf;
	unsigned n, c;

	for (n = 0; n < noctets; n++) {
		c = n % 7;
		*op++ = ((ip[1] << 7) | ip[0]) >> c;
		if (c == 6)
			ip += 2;
		else
			ip += 1;
	}
}
