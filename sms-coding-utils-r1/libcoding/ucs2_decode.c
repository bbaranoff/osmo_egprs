/*
 * This library module implements the conversion of UCS2-encoded data
 * (typically received in SMS) into ASCII, ISO 8859-1 or UTF-8,
 * maintaining parallelism with the corresponding function for decoding
 * GSM7-encoded data.
 */

#include <sys/types.h>
#include <stdio.h>

ucs2_to_ascii_or_ext(inbuf, inlen, outbuf, outlenp, ascii_ext, newline_ok)
	u_char *inbuf, *outbuf;
	unsigned inlen, *outlenp;
{
	u_char *inp, *endp, *outp;
	unsigned uni;

	inp = inbuf;
	endp = inbuf + (inlen & ~1);
	outp = outbuf;
	while (inp < endp) {
		if ((endp - inp) >= 4 && (inp[0] & 0xFC) == 0xD8 &&
		    (inp[2] & 0xFC) == 0xDC) {
			uni = ((inp[0] & 3) << 18) | (inp[1] << 10) |
			      ((inp[2] & 3) << 8) | inp[3];
			inp += 4;
			uni += 0x10000;
			if (ascii_ext == 2)
				outp += emit_utf8_char(uni, outp);
			else {
				sprintf(outp, "\\U%06X", uni);
				outp += 8;
			}
			continue;
		}
		uni = (inp[0] << 8) | inp[1];
		inp += 2;
		if (uni == '\\') {
			*outp++ = '\\';
			*outp++ = '\\';
		} else if (uni == '\r') {
			*outp++ = '\\';
			*outp++ = 'r';
		} else if (uni == '\n') {
			if (newline_ok)
				*outp++ = '\n';
			else {
				*outp++ = '\\';
				*outp++ = 'n';
			}
		} else if (!is_decoded_char_ok(uni, ascii_ext)) {
			sprintf(outp, "\\u%04X", uni);
			outp += 6;
		} else if (ascii_ext == 2)
			outp += emit_utf8_char(uni, outp);
		else
			*outp++ = uni;
	}
	*outp = '\0';
	if (outlenp)
		*outlenp = outp - outbuf;
}
