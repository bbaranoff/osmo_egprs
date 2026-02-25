/*
 * This library module implements a function that converts text input
 * from UTF-8 to ISO 8859-1, rejecting any input Unicode characters
 * that aren't in the 8859-1 range.  The conversion in done in place.
 */

#include <sys/types.h>

utf8_to_latin1(buf)
	u_char *buf;
{
	u_char *ip = buf, *op = buf;
	int c, c2;

	while (c = *ip++) {
		if (c < 0x80) {
			*op++ = c;
			continue;
		}
		if (c != 0xC2 && c != 0xC3)
			return(-1);
		c2 = *ip++;
		if (c2 < 0x80 || c2 > 0xBF)
			return(-1);
		*op++ = ((c & 3) << 6) | (c2 & 0x3F);
	}
	*op = '\0';
	return(0);
}
