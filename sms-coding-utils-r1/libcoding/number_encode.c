/*
 * This module implements functions for encoding phone numbers.
 */

#include <sys/types.h>
#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>

digit_char_to_gsm(ch)
{
	switch (ch) {
	case '0':
	case '1':
	case '2':
	case '3':
	case '4':
	case '5':
	case '6':
	case '7':
	case '8':
	case '9':
		return (ch - '0');
	case '*':
		return 0xA;
	case '#':
		return 0xB;
	case 'a':
	case 'b':
	case 'c':
		return (ch - 'a' + 0xC);
	case 'A':
	case 'B':
	case 'C':
		return (ch - 'A' + 0xC);
	}
	return (-1);
}

void
pack_digit_bytes(digits, dest, num_digit_bytes)
	u_char *digits, *dest;
	unsigned num_digit_bytes;
{
	u_char *sp, *dp;
	unsigned n;

	sp = digits;
	dp = dest;
	for (n = 0; n < num_digit_bytes; n++) {
		*dp++ = sp[0] | (sp[1] << 4);
		sp += 2;
	}
}

encode_phone_number_arg(arg, fixp, mode)
	char *arg;
	u_char *fixp;
{
	u_char digits[20];
	unsigned ndigits, num_digit_bytes;
	char *cp, *endp;
	int c;

	cp = arg;
	if (*cp == '+') {
		fixp[1] = 0x91;
		cp++;
	} else
		fixp[1] = 0x81;
	if (digit_char_to_gsm(*cp) < 0)
		return(-1);
	for (ndigits = 0; ; ndigits++) {
		c = digit_char_to_gsm(*cp);
		if (c < 0)
			break;
		cp++;
		if (ndigits >= 20)
			return(-1);
		digits[ndigits] = c;
	}
	if (mode)
		fixp[0] = ndigits;
	if (ndigits & 1)
		digits[ndigits++] = 0xF;
	num_digit_bytes = ndigits >> 1;
	if (!mode)
		fixp[0] = num_digit_bytes + 1;
	pack_digit_bytes(digits, fixp + 2, num_digit_bytes);
	if (*cp == ',') {
		cp++;
		if (!isdigit(*cp))
			return(-1);
		fixp[1] = strtoul(cp, &endp, 0);
		if (*endp)
			return(-1);
	} else if (*cp)
		return(-1);
	return(0);
}
