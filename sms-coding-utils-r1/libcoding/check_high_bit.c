/*
 * The function implemented in this module is intended for validating inputs
 * that are expected to be in the form of GSM7 characters carried in an octet
 * string, where the high bit of every octet is expected to be cleared.
 */

#include <sys/types.h>

check_high_bit(buf, len)
	u_char *buf;
	unsigned len;
{
	unsigned n;

	for (n = 0; n < len; n++) {
		if (buf[n] & 0x80)
			return(-1);
	}
	return(0);
}
