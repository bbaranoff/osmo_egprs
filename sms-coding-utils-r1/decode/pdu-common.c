#include <sys/types.h>
#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

int ascii_ext_mode, global_hexdump_mode;

u_char pdu[176];
unsigned pdu_length;

static u_char first_octet;
static unsigned pdu_ptr;
static int dcs_distilled;

static
handle_sca()
{
	unsigned sca_len;
	char digits[21];

	sca_len = pdu[0];
	pdu_ptr = 1;
	if (!sca_len)
		return(0);
	if (sca_len < 2 || sca_len > 11) {
		printf("Decode-Error: invalid SCA length\n");
		return(-1);
	}
	if (pdu_ptr + sca_len > pdu_length) {
		printf("Decode-Error: SCA goes past PDU end\n");
		return(-1);
	}
	pdu_ptr += sca_len;
	decode_address_digits(pdu + 2, digits, sc_addr_ndigits(pdu));
	printf("SCA: %s%s (type 0x%02X)\n", pdu[1] == 0x91 ? "+" : "", digits,
		pdu[1]);
	return(0);
}

static
handle_first_octet()
{
	if (pdu_ptr >= pdu_length) {
		printf("Decode-Error: end of PDU before FO\n");
		return(-1);
	}
	first_octet = pdu[pdu_ptr++];
	printf("First-Octet: 0x%02X\n", first_octet);
	return(0);
}

static
handle_mr()
{
	if (pdu_ptr >= pdu_length) {
		printf("Decode-Error: end of PDU before MR\n");
		return(-1);
	}
	printf("MR: 0x%02X\n", pdu[pdu_ptr++]);
	return(0);
}

static
handle_user_addr(direction)
	char *direction;
{
	unsigned addr_field_len, alpha_nsep;
	char digits[21];
	u_char alpha_gsm7[11];

	if (pdu_ptr >= pdu_length) {
		printf("Decode-Error: end of PDU before %s address\n",
			direction);
		return(-1);
	}
	if (pdu[pdu_ptr] > 20) {
		printf("Decode-Error: %s address > 20 digits\n", direction);
		return(-1);
	}
	addr_field_len = ((pdu[pdu_ptr] + 1) >> 1) + 2;
	if (pdu_ptr + addr_field_len > pdu_length) {
		printf("Decode-Error: %s address goes past PDU end\n",
			direction);
		return(-1);
	}
	if (!pdu[pdu_ptr])
		printf("%s: empty-addr (type 0x%02X)\n", direction,
			pdu[pdu_ptr+1]);
	else if ((pdu[pdu_ptr+1] & 0x70) == 0x50 &&
		 alpha_addr_valid(pdu[pdu_ptr], &alpha_nsep)) {
		gsm7_unpack(pdu + pdu_ptr + 2, alpha_gsm7, alpha_nsep);
		printf("%s: ", direction);
		print_gsm7_string_to_file(alpha_gsm7, alpha_nsep, stdout);
		printf(" (type 0x%02X)\n", pdu[pdu_ptr+1]);
	} else {
		decode_address_digits(pdu + pdu_ptr + 2, digits, pdu[pdu_ptr]);
		printf("%s: %s%s (type 0x%02X)\n", direction,
			pdu[pdu_ptr+1] == 0x91 ? "+" : "", digits,
			pdu[pdu_ptr+1]);
	}
	pdu_ptr += addr_field_len;
	return(0);
}

static
handle_pid()
{
	if (pdu_ptr >= pdu_length) {
		printf("Decode-Error: end of PDU before PID\n");
		return(-1);
	}
	printf("PID: 0x%02X\n", pdu[pdu_ptr++]);
	return(0);
}

static
handle_dcs()
{
	u_char dcs;
	char *strtype;

	if (pdu_ptr >= pdu_length) {
		printf("Decode-Error: end of PDU before DCS\n");
		return(-1);
	}
	dcs = pdu[pdu_ptr++];
	dcs_distilled = sms_dcs_classify(dcs);
	switch (dcs_distilled) {
	case 7:
		strtype = "7-bit";
		break;
	case 8:
		strtype = "raw octets";
		break;
	case 9:
		strtype = "compressed";
		break;
	case 16:
		strtype = "UCS-2";
		break;
	}
	printf("DCS: 0x%02X (%s)\n", dcs, strtype);
	return(0);
}

static
handle_scts()
{
	char str[21];

	if (pdu_ptr + 7 > pdu_length) {
		printf("Decode-Error: end of PDU before SCTS\n");
		return(-1);
	}
	gsm_timestamp_decode(pdu + pdu_ptr, str);
	printf("SC-Timestamp: %s\n", str);
	pdu_ptr += 7;
	return(0);
}

static
handle_vp_abs()
{
	char str[21];

	if (pdu_ptr + 7 > pdu_length) {
		printf("Decode-Error: end of PDU before VP-abs\n");
		return(-1);
	}
	gsm_timestamp_decode(pdu + pdu_ptr, str);
	printf("VP-Absolute: %s\n", str);
	pdu_ptr += 7;
	return(0);
}

static
handle_vp_rel()
{
	unsigned vprel, hours, min;

	if (pdu_ptr >= pdu_length) {
		printf("Decode-Error: end of PDU before VP-rel\n");
		return(-1);
	}
	vprel = pdu[pdu_ptr++];
	if (vprel <= 143) {
		min = (vprel + 1) * 5;
		goto hhmm;
	} else if (vprel <= 167) {
		min = (vprel - 143) * 30 + 12 * 60;
		goto hhmm;
	} else if (vprel <= 196) {
		printf("VP-Relative: %u days\n", vprel - 166);
		return(0);
	} else {
		printf("VP-Relative: %u weeks\n", vprel - 192);
		return(0);
	}

hhmm:	hours = min / 60;
	min %= 60;
	printf("VP-Relative:");
	if (hours)
		printf(" %u hour%s", hours, hours != 1 ? "s" : "");
	if (min)
		printf(" %u min", min);
	putchar('\n');
	return(0);
}

static
handle_vp_enh()
{
	if (pdu_ptr + 7 > pdu_length) {
		printf("Decode-Error: end of PDU before VP-enh\n");
		return(-1);
	}
	printf("VP-Enhanced: %02X %02X %02X %02X %02X %02X %02X\n",
		pdu[pdu_ptr], pdu[pdu_ptr+1], pdu[pdu_ptr+2], pdu[pdu_ptr+3],
		pdu[pdu_ptr+4], pdu[pdu_ptr+5], pdu[pdu_ptr+6]);
	pdu_ptr += 7;
	return(0);
}

static
handle_vp()
{
	int rc;

	switch (first_octet & 0x18) {
	case 0x00:
		rc = 0;
		break;
	case 0x08:
		rc = handle_vp_enh();
		break;
	case 0x10:
		rc = handle_vp_rel();
		break;
	case 0x18:
		rc = handle_vp_abs();
		break;
	}
	return(rc);
}

process_pdu(require_exact_length, expect_sca)
{
	unsigned udl, udl_octets;
	unsigned udhl, udh_octets, udh_chars, ud_chars;
	u_char ud7[160], decode_buf[481];
	int do_hexdump;
	unsigned decoded_len;

	if (expect_sca) {
		if (handle_sca() < 0)
			return(-1);
	} else
		pdu_ptr = 0;
	if (handle_first_octet() < 0)
		return(-1);
	if (first_octet & 2) {
		printf("Decode-Error: MTI not supported\n");
		return(-1);
	}
	if (first_octet & 1) {
		if (handle_mr() < 0)
			return(-1);
	}
	if (handle_user_addr(first_octet & 1 ? "To" : "From") < 0)
		return(-1);
	if (handle_pid() < 0)
		return(-1);
	if (handle_dcs() < 0)
		return(-1);
	if (first_octet & 1) {
		if (handle_vp() < 0)
			return(-1);
	} else {
		if (handle_scts() < 0)
			return(-1);
	}
	if (pdu_ptr >= pdu_length) {
		printf("Decode-Error: end of PDU before UDL\n");
		return(-1);
	}
	udl = pdu[pdu_ptr++];
	if (dcs_distilled == 7) {
		if (udl > 160) {
			printf("Decode-Error: UDL %u > 160\n", udl);
			return(-1);
		}
		udl_octets = (udl * 7 + 7) / 8;
	} else {
		if (udl > 140) {
			printf("Decode-Error: UDL %u > 140\n", udl);
			return(-1);
		}
		udl_octets = udl;
	}
	if (require_exact_length && pdu_length - pdu_ptr != udl_octets) {
		printf("Decode-Error: UD length in PDU %u != expected %u\n",
			pdu_length - pdu_ptr, udl_octets);
		return(-1);
	}
	if (first_octet & 0x40) {
		if (!udl) {
			printf("Decode-Error: UDHI set with UDL=0\n");
			return(-1);
		}
		udhl = pdu[pdu_ptr];
		udh_octets = udhl + 1;
		if (udh_octets > udl_octets) {
			printf("Decode-Error: UDHL exceeds UDL\n");
			return(-1);
		}
		printf("UDH-Length: %u\n", udhl);
		if (dcs_distilled == 7)
			udh_chars = (udh_octets * 8 + 6) / 7;
		else
			udh_chars = udh_octets;
	} else {
		udhl = 0;
		udh_octets = 0;
		udh_chars = 0;
	}
	if (udh_chars >= udl) {
		ud_chars = 0;
		printf("Length: 0\n");
	} else {
		ud_chars = udl - udh_chars;
		if (dcs_distilled == 7)
			gsm7_unpack(pdu + pdu_ptr, ud7, udl);
		if (global_hexdump_mode)
			do_hexdump = 1;
		else switch (dcs_distilled) {
		case 7:
			do_hexdump = 0;
			break;
		case 8:
		case 9:
			do_hexdump = 1;
			break;
		case 16:
			if (ud_chars & 1)
				do_hexdump = 1;
			else
				do_hexdump = 0;
			break;
		}
		if (do_hexdump)
			printf("Length: %u (raw)\n", ud_chars);
		else {
			switch (dcs_distilled) {
			case 7:
				gsm7_to_ascii_or_ext(ud7 + udh_chars, ud_chars,
						     decode_buf, &decoded_len,
						     ascii_ext_mode, 1);
				break;
			case 16:
				ucs2_to_ascii_or_ext(pdu + pdu_ptr + udh_chars,
						     ud_chars,
						     decode_buf, &decoded_len,
						     ascii_ext_mode, 1);
				break;
			}
			printf("Length: %u", ud_chars);
			if (decoded_len != ud_chars)
				printf("->%u", decoded_len);
			putchar('\n');
		}
	}

	if (udhl) {
		printf("\nUDH:\n");
		msg_bits_hexdump(pdu + pdu_ptr + 1, udhl);
	}
	if (!ud_chars)
		return(0);
	putchar('\n');
	if (do_hexdump) {
		if (dcs_distilled == 7)
			msg_bits_hexdump(ud7 + udh_chars, ud_chars);
		else
			msg_bits_hexdump(pdu + pdu_ptr + udh_chars, ud_chars);
	} else
		puts(decode_buf);
	return(0);
}
