/*
 * This library module implements the function for encoding from ISO 8859-1
 * into the GSM 7-bit default alphabet (03.38 or 23.038).
 */

#include <sys/types.h>
#include <ctype.h>

extern u_char gsm7_encode_table[256];

static unsigned
handle_escape(ipp)
	u_char **ipp;
{
	unsigned c;

	c = *(*ipp)++;
	if (c >= '0' && c <= '7' && isxdigit(**ipp)) {
		c = ((c - '0') << 4) | decode_hex_digit(*(*ipp)++);
		return c;
	}
	switch (c) {
	case 'n':
		return '\n';
	case 'r':
		return '\r';
	case 'e':
		return 0x1B;
	case 'E':		/* Euro currency symbol */
		return 0xE5;
	case '"':
	case '\\':
		c = gsm7_encode_table[c];
		return c;
	default:
		return 0xFF;
	}
}

latin1_to_gsm7(inbuf, outbuf, outmax, outlenp, allow_escape)
	u_char *inbuf, *outbuf;
	unsigned outmax, *outlenp;
{
	u_char *ip = inbuf, *op = outbuf;
	unsigned outcnt = 0, c, n;

	while (c = *ip++) {
		if (c == '\\' && allow_escape) {
			c = handle_escape(&ip);
			if (c == 0xFF)
				return(-3);
		} else {
			c = gsm7_encode_table[c];
			if (c == 0xFF)
				return(-1);
		}
		if (c & 0x80)
			n = 2;
		else
			n = 1;
		if (outcnt + n > outmax)
			return(-2);
		if (c & 0x80) {
			*op++ = 0x1B;
			*op++ = c & 0x7F;
		} else
			*op++ = c;
		outcnt += n;
	}
	*outlenp = outcnt;
	return(0);
}
