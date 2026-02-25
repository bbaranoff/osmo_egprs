/*
 * This module implements a function for decoding GSM7 strings
 * to ASCII with output to a stdio file; it is an implementation
 * of lossless conversion per our SIM-data-formats spec
 * in freecalypso-docs.
 */

#include <sys/types.h>
#include <stdio.h>

static char basic_table[128] = {
	'@', 0,   '$',      0,   0,   0,        0,   0,
	0,   0,   'n'|0x80, 0,   0,   'r'|0x80, 0,   0,
	0,   '_', 0,        0,   0,   0,        0,   0,
	0,   0,   0,        0,   0,   0,        0,   0,
	' ', '!', '"'|0x80, '#', 0,   '%',      '&', 0x27,
	'(', ')', '*',      '+', ',', '-',      '.', '/',
	'0', '1', '2',      '3', '4', '5',      '6', '7',
	'8', '9', ':',      ';', '<', '=',      '>', '?',
	0,   'A', 'B',      'C', 'D', 'E',      'F', 'G',
	'H', 'I', 'J',      'K', 'L', 'M',      'N', 'O',
	'P', 'Q', 'R',      'S', 'T', 'U',      'V', 'W',
	'X', 'Y', 'Z',      0,   0,   0,        0,   0,
	0,   'a', 'b',      'c', 'd', 'e',      'f', 'g',
	'h', 'i', 'j',      'k', 'l', 'm',      'n', 'o',
	'p', 'q', 'r',      's', 't', 'u',      'v', 'w',
	'x', 'y', 'z',      0,   0,   0,        0,   0
};

static char escape_table[128] = {
	0,   0, 0, 0, 0,   0,    0, 0, 0,   0,   0, 0, 0,   0,   0,   0,
	0,   0, 0, 0, '^', 0,    0, 0, 0,   0,   0, 0, 0,   0,   0,   0,
	0,   0, 0, 0, 0,   0,    0, 0, '{', '}', 0, 0, 0,   0,   0,   '\\'|0x80,
	0,   0, 0, 0, 0,   0,    0, 0, 0,   0,   0, 0, '[', '~', ']', 0,
	'|', 0, 0, 0, 0,   0,    0, 0, 0,   0,   0, 0, 0,   0,   0,   0,
	0,   0, 0, 0, 0,   0,    0, 0, 0,   0,   0, 0, 0,   0,   0,   0,
	0,   0, 0, 0, 0,'E'|0x80,0, 0, 0,   0,   0, 0, 0,   0,   0,   0,
	0,   0, 0, 0, 0,   0,    0, 0, 0,   0,   0, 0, 0,   0,   0,   0
};

void
print_gsm7_string_to_file(data, nbytes, outf)
	u_char *data;
	unsigned nbytes;
	FILE *outf;
{
	u_char *dp, *endp;
	int b, c;

	dp = data;
	endp = data + nbytes;
	putc('"', outf);
	while (dp < endp) {
		b = *dp++;
		if (b == 0x1B) {
			if (dp >= endp || *dp == 0x1B || *dp == '\n' ||
			    *dp == '\r') {
				putc('\\', outf);
				putc('e', outf);
				continue;
			}
			b = *dp++;
			c = escape_table[b];
			if (!c) {
				fprintf(outf, "\\e\\%02X", b);
				continue;
			}
		} else {
			c = basic_table[b];
			if (!c) {
				fprintf(outf, "\\%02X", b);
				continue;
			}
		}
		if (c & 0x80) {
			putc('\\', outf);
			c &= 0x7F;
		}
		putc(c, outf);
	}
	putc('"', outf);
}
