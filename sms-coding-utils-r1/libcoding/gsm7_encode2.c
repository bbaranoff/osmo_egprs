/*
 * This module implements functions for parsing quoted string
 * arguments intended for GSM7 string encoding, and actually
 * encoding them into GSM7 binary strings.
 */

#include <sys/types.h>
#include <ctype.h>
#include <stdio.h>

extern u_char gsm7_encode_table[256];

qstring_arg_to_gsm7(arg, record, maxlen)
	char *arg;
	u_char *record;
	unsigned maxlen;
{
	unsigned acclen, nadd;
	char *cp;
	int c;

	cp = arg;
	for (acclen = 0; *cp; ) {
		c = *cp++;
		if (c == '\\') {
			if (*cp == '\0')
				return(-1);
			c = *cp++;
			if (c >= '0' && c <= '7' && isxdigit(*cp)) {
				c = ((c - '0') << 4) | decode_hex_digit(*cp++);
				goto bypass_encoding;
			}
			switch (c) {
			case 'n':
				c = '\n';
				goto bypass_encoding;
			case 'r':
				c = '\r';
				goto bypass_encoding;
			case 'e':
				c = 0x1B;
				goto bypass_encoding;
			case 'E':		/* Euro currency symbol */
				c = 0xE5;
				goto bypass_encoding;
			case '"':
			case '\\':
				break;
			default:
				return(-1);
			}
		}
		c = gsm7_encode_table[c];
		if (c == 0xFF)
			return(-1);
bypass_encoding:
		if (c & 0x80)
			nadd = 2;
		else
			nadd = 1;
		if (acclen + nadd > maxlen)
			return(-1);
		if (c & 0x80)
			record[acclen++] = 0x1B;
		record[acclen++] = c & 0x7F;
	}
	return(acclen);
}
