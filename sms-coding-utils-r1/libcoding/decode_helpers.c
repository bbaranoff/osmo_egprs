/*
 * This library module implements the is_decoded_char_ok() and emit_utf8_char()
 * functions used by gsm7_to_ascii_or_ext() and ucs2_to_ascii_or_ext().
 */

#include <sys/types.h>

is_decoded_char_ok(uni, ascii_ext)
	unsigned uni;
{
	unsigned upper_limit;

	/* weed out control chars first */
	if (uni < 0x20)
		return(0);
	if (uni >= 0x7F && uni <= 0x9F)
		return(0);
	/* see what range our output encoding allows */
	switch (ascii_ext) {
	case 0:
		upper_limit = 0x7F;
		break;
	case 1:
		upper_limit = 0xFF;
		break;
	case 2:
		upper_limit = 0xFFFF;
		break;
	default:
		upper_limit = 0;
	}
	if (uni <= upper_limit)
		return(1);
	else
		return(0);
}

emit_utf8_char(uni, outp)
	unsigned uni;
	u_char *outp;
{
	if (uni < 0x80) {
		*outp = uni;
		return(1);
	}
	if (uni < 0x800) {
		outp[0] = 0xC0 | (uni >> 6);
		outp[1] = 0x80 | (uni & 0x3F);
		return(2);
	}
	if (uni < 0x10000) {
		outp[0] = 0xE0 | (uni >> 12);
		outp[1] = 0x80 | ((uni >> 6) & 0x3F);
		outp[2] = 0x80 | (uni & 0x3F);
		return(3);
	}
	outp[0] = 0xF0 | (uni >> 18);
	outp[1] = 0x80 | ((uni >> 12) & 0x3F);
	outp[2] = 0x80 | ((uni >> 6) & 0x3F);
	outp[3] = 0x80 | (uni & 0x3F);
	return(4);
}
