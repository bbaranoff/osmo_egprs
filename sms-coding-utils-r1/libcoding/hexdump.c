/*
 * This library module implements a simple hex dump facility.
 */

#include <sys/types.h>
#include <stdio.h>

msg_bits_hexdump(dumpbuf, dumplen)
	u_char *dumpbuf;
	unsigned dumplen;
{
	u_char *buf = dumpbuf;
	unsigned lineoff, linelen, i, c;

	for (lineoff = 0; lineoff < dumplen; ) {
		linelen = dumplen - lineoff;
		if (linelen > 16)
			linelen = 16;
		printf("%02X:  ", lineoff);
		for (i = 0; i < 16; i++) {
			if (i < linelen)
				printf("%02X ", buf[i]);
			else
				fputs("   ", stdout);
			if (i == 7 || i == 15)
				putchar(' ');
		}
		for (i = 0; i < linelen; i++) {
			c = buf[i];
			if (c < ' ' || c > '~')
				c = '.';
			putchar(c);
		}
		putchar('\n');
		buf += linelen;
		lineoff += linelen;
	}
}
