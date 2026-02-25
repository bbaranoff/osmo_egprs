/*
 * This library module implements the function that distills the complex
 * set of possible SMS DCS octet values to just one of 4 possibilities:
 * 7-bit text (7), 8-bit data octets (8), UCS-2 text (16) or compressed
 * data (9).
 *
 * The decoding is based on the 3GPP TS 23.038 V11.0.0 spec;
 * reserved encodings are treated as 7-bit text as the spec instructs.
 */

sms_dcs_classify(dcs)
{
	if (!(dcs & 0x80)) {
		if (dcs & 0x20)
			return(9);
		switch (dcs & 0xC) {
		case 0:
			return(7);
		case 4:
			return(8);
		case 8:
			return(16);
		default:
			/* reserved, treating as 7-bit per the spec */
			return(7);
		}
	}
	switch (dcs & 0xF0) {
	case 0x80:
	case 0x90:
	case 0xA0:
	case 0xB0:
		/* reserved, treating as 7-bit per the spec */
		return(7);
	case 0xC0:
	case 0xD0:
		return(7);
	case 0xE0:
		return(16);
	case 0xF0:
		if (dcs & 4)
			return(8);
		else
			return(7);
	}
}
