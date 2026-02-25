/*
 * This library module implements the function for converting UTF-8 input
 * to UCS-2 in outgoing SMS composition.
 */

#include <sys/types.h>
#include <ctype.h>

static int
handle_escape(ipp, outp)
	u_char **ipp;
	unsigned *outp;
{
	unsigned c, n, acc;

	c = *(*ipp)++;
	switch (c) {
	case '"':
	case '\\':
		*outp = c;
		return(0);
	case 'n':
		*outp = '\n';
		return(0);
	case 'r':
		*outp = '\r';
		return(0);
	case 'u':
		acc = 0;
		for (n = 0; n < 4; n++) {
			c = *(*ipp)++;
			if (!isxdigit(c))
				return(-3);
			acc <<= 4;
			acc |= decode_hex_digit(c);
		}
		*outp = acc;
		return(0);
	default:
		return(-3);
	}
}

utf8_to_ucs2(inbuf, outbuf, outmax, outlenp, allow_escape)
	u_char *inbuf;
	u_short *outbuf;
	unsigned outmax, *outlenp;
{
	u_char *ip = inbuf;
	u_short *op = outbuf;
	unsigned outcnt = 0, c, n, uni;
	int rc;

	while (c = *ip++) {
		if (c == '\\' && allow_escape) {
			rc = handle_escape(&ip, &uni);
			if (rc < 0)
				return(rc);
			goto gotuni;
		}
		if (c < 0x80) {
			uni = c;
			goto gotuni;
		}
		if (c < 0xC0 || c > 0xEF)
			return(-1);
		uni = c & 0x1F;
		if (c >= 0xE0)
			n = 2;
		else
			n = 1;
		for (; n; n--) {
			c = *ip++;
			if (c < 0x80 || c > 0xBF)
				return(-1);
			uni <<= 6;
			uni |= c & 0x3F;
		}
gotuni:		if (outcnt >= outmax)
			return(-2);
		*op++ = uni;
		outcnt++;
	}
	*outlenp = outcnt;
	return(0);
}
