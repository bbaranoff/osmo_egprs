/*
 * This library module implements the decoding of number (address) digits.
 */

#include <sys/types.h>

char gsm_address_digits[16] =
	{'0','1','2','3','4','5','6','7','8','9','*','#','a','b','c','?'};

decode_address_digits(inbuf, outbuf, ndigits)
	u_char *inbuf;
	char *outbuf;
	unsigned ndigits;
{
	u_char *inp = inbuf;
	char *outp = outbuf;
	unsigned n = 0, b;

	while (n < ndigits) {
		b = *inp++;
		*outp++ = gsm_address_digits[b & 0xF];
		n++;
		if (n >= ndigits)
			break;
		*outp++ = gsm_address_digits[b >> 4];
		n++;
	}
	*outp = '\0';
}
