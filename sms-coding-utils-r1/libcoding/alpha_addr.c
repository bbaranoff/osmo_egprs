/*
 * This library module contains some bits that help working with
 * alphabetic addresses.
 */

#include <sys/types.h>

u_char alpha_septets_to_digits[12] = {0, 2, 4, 6, 7, 9, 11, 13, 14, 16, 18, 20};

alpha_addr_valid(ndigits, sepp)
	unsigned ndigits, *sepp;
{
	unsigned n;

	for (n = 1; n <= 11; n++)
		if (alpha_septets_to_digits[n] == ndigits) {
			*sepp = n;
			return(1);
		}
	return(0);
}
