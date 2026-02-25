/*
 * This library module implements the decoding of GSM7-encoded data
 * into ASCII, ISO 8859-1 or UTF-8.
 */

#include <sys/types.h>
#include <stdio.h>

extern u_short gsm7_decode_table[128];
extern u_short gsm7ext_decode_table[128];

gsm7_to_ascii_or_ext(inbuf, inlen, outbuf, outlenp, ascii_ext, newline_ok)
	u_char *inbuf, *outbuf;
	unsigned inlen, *outlenp;
{
	u_char *inp, *endp, *outp;
	unsigned gsm, uni;
	int is_ext;

	inp = inbuf;
	endp = inbuf + inlen;
	outp = outbuf;
	while (inp < endp) {
		gsm = *inp++;
		if (gsm == 0x1B && inp < endp && *inp != 0x1B && *inp != '\n'
		    && *inp != '\r') {
			gsm = *inp++;
			uni = gsm7ext_decode_table[gsm];
			if (uni == '\\') {
				*outp++ = '\\';
				*outp++ = '\\';
				continue;
			}
			if (uni == 0x20AC && ascii_ext < 2) {
				*outp++ = '\\';
				*outp++ = 'E';
				continue;
			}
			is_ext = 1;
		} else {
			switch (gsm) {
			case 0x1B:
				*outp++ = '\\';
				*outp++ = 'e';
				continue;
			case '\n':
				if (newline_ok)
					*outp++ = '\n';
				else {
					*outp++ = '\\';
					*outp++ = 'n';
				}
				continue;
			case '\r':
				*outp++ = '\\';
				*outp++ = 'r';
				continue;
			}
			uni = gsm7_decode_table[gsm];
			is_ext = 0;
		}
		if (!uni || !is_decoded_char_ok(uni, ascii_ext)) {
			if (is_ext) {
				*outp++ = '\\';
				*outp++ = 'e';
			}
			sprintf(outp, "\\%02X", gsm);
			outp += 3;
		} else if (ascii_ext == 2)
			outp += emit_utf8_char(uni, outp);
		else
			*outp++ = uni;
	}
	*outp = '\0';
	if (outlenp)
		*outlenp = outp - outbuf;
}
