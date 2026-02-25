/*
 * This module contains elementary functions for working with hex digits.
 */

decode_hex_digit(c)
{
	if (c >= '0' && c <= '9')
		return(c - '0');
	if (c >= 'A' && c <= 'F')
		return(c - 'A' + 10);
	if (c >= 'a' && c <= 'f')
		return(c - 'a' + 10);
	return(-1);
}

encode_hex_digit(d)
	unsigned d;
{
	if (d <= 9)
		return(d + '0');
	else
		return(d - 10 + 'A');
}
