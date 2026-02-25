/*
 * This library module contains the code that figures out how many digits
 * are there in a PDU-encoded Service Centre address.
 */

#include <sys/types.h>

sc_addr_ndigits(sca)
	u_char *sca;
{
	unsigned nb, nd;

	nb = sca[0];
	nd = (nb - 1) * 2;
	if ((sca[nb] & 0xF0) == 0xF0)
		nd--;
	return nd;
}
