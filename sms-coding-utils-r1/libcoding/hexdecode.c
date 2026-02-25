/*
 * This library module implements decoding of long hex strings,
 * such as SMS PDUs.
 */

#include <sys/types.h>
#include <ctype.h>

decode_hex_line(inbuf, outbuf, outmax)
	char *inbuf;
	u_char *outbuf;
	unsigned outmax;
{
	char *inp = inbuf;
	u_char *outp = outbuf;
	unsigned outcnt = 0;
	int c, d[2], i;

	while (*inp) {
		if (!isxdigit(inp[0]) || !isxdigit(inp[1]))
			return(-1);
		if (outcnt >= outmax)
			break;
		for (i = 0; i < 2; i++) {
			c = *inp++;
			if (isdigit(c))
				d[i] = c - '0';
			else if (isupper(c))
				d[i] = c - 'A' + 10;
			else
				d[i] = c - 'a' + 10;
		}
		*outp++ = (d[0] << 4) | d[1];
		outcnt++;
	}
	return outcnt;
}
