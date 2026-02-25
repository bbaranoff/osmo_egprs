/*
 * The function implemented in this module encodes a GSM SMS absolute timestamp
 * from ASCII representation into PDU octets.
 */

#include <sys/types.h>
#include <ctype.h>

encode_gsm_sms_abstime(str, bin)
	char *str;
	u_char *bin;
{
	u_char digits[14];

	if (!isdigit(str[0]) || !isdigit(str[1]))
		return(-1);
	digits[0] = str[0] - '0';
	digits[1] = str[1] - '0';
	if (str[2] != '/')
		return(-1);
	if (!isdigit(str[3]) || !isdigit(str[4]))
		return(-1);
	digits[2] = str[3] - '0';
	digits[3] = str[4] - '0';
	if (str[5] != '/')
		return(-1);
	if (!isdigit(str[6]) || !isdigit(str[7]))
		return(-1);
	digits[4] = str[6] - '0';
	digits[5] = str[7] - '0';
	if (str[8] != ',')
		return(-1);
	if (!isdigit(str[9]) || !isdigit(str[10]))
		return(-1);
	digits[6] = str[9] - '0';
	digits[7] = str[10] - '0';
	if (str[11] != ':')
		return(-1);
	if (!isdigit(str[12]) || !isdigit(str[13]))
		return(-1);
	digits[8] = str[12] - '0';
	digits[9] = str[13] - '0';
	if (str[14] != ':')
		return(-1);
	if (!isdigit(str[15]) || !isdigit(str[16]))
		return(-1);
	digits[10] = str[15] - '0';
	digits[11] = str[16] - '0';
	if (str[17] != '+' && str[17] != '-')
		return(-1);
	if (!isdigit(str[18]) || !isdigit(str[19]))
		return(-1);
	digits[12] = str[18] - '0';
	digits[13] = str[19] - '0';
	if (str[20])
		return(-1);
	if (str[17] == '-')
		digits[12] |= 8;
	pack_digit_bytes(digits, bin, 7);
	return(0);
}
