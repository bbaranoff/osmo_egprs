/*
 * This library module implements encoding of alphanumeric From addresses
 * that are allowed in SMS-DELIVER TPDUs.
 */

#include <sys/types.h>

extern u_char alpha_septets_to_digits[12];

encode_alpha_addr(arg, bin)
	char *arg;
	u_char *bin;
{
	u_char gsm7[11];
	int rc;

	rc = qstring_arg_to_gsm7(arg, gsm7, 11);
	if (rc < 0)
		return(rc);
	bin[0] = alpha_septets_to_digits[rc];
	bin[1] = 0x50;
	gsm7_pack(gsm7, bin + 2, (bin[0] + 1) >> 1);
	return(0);
}
