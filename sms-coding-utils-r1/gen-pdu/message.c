/*
 * This module implements TPDU encoding of actual messages, after all
 * settings have been captured.
 */

#include <sys/types.h>
#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include "error.h"

extern int dir_mo, include_sca;
extern u_char sc_addr[12], user_addr[12];
extern u_char mr_byte, pid_byte, dcs_byte;
extern u_char scts_buf[7];
extern u_char vp_format, vp_buf[7];
extern int is_septet, scts_is_set;
extern int flag_rp, flag_sr, flag_lp, flag_mms, flag_rd;

extern int input_lineno;

static void
emit_first_octet(udhi)
{
	u_char fo;

	if (dir_mo) {
		fo = flag_rd ? 5 : 1;
		fo |= vp_format;
	} else {
		fo = flag_mms ? 0 : 4;
		if (flag_lp)
			fo |= 0x08;
	}
	if (flag_sr)
		fo |= 0x20;
	if (udhi)
		fo |= 0x40;
	if (flag_rp)
		fo |= 0x80;
	printf("%02X", fo);
}

static void
make_pdu(udl, ud_buf, ud_octets, udhi)
	u_char *ud_buf;
	unsigned udl, ud_octets;
{
	if (include_sca)
		emit_hex_out(sc_addr, sc_addr[0] + 1, stdout);
	emit_first_octet(udhi);
	if (dir_mo)
		printf("%02X", mr_byte);
	emit_hex_out(user_addr, ((user_addr[0] + 1) >> 1) + 2, stdout);
	printf("%02X", pid_byte);
	printf("%02X", dcs_byte);
	if (!dir_mo) {
		if (!scts_is_set)
			set_auto_scts();
		emit_hex_out(scts_buf, 7, stdout);
	} else if (vp_format == 0x10)
		printf("%02X", vp_buf[0]);
	else if (vp_format)
		emit_hex_out(vp_buf, 7, stdout);
	printf("%02X", udl);
	emit_hex_out(ud_buf, ud_octets, stdout);
	putchar('\n');
}

static void
cmd_msg_common(arg, udhi)
	char *arg;
{
	u_char input[160], ud7[160], octbuf[140];
	unsigned input_len, udhl, udhl1, udh_chars, plain_chars;
	unsigned udl, udl_octets;

	for (input_len = 0; ; input_len++) {
		while (isspace(*arg))
			arg++;
		if (!*arg)
			break;
		if (!isxdigit(arg[0]) || !isxdigit(arg[1])) {
			fprintf(stderr, ERR_PREFIX "invalid hex string\n",
				input_lineno);
			exit(1);
		}
		if (input_len >= 160) {
toolong:		fprintf(stderr, ERR_PREFIX "hex string is too long\n",
				input_lineno);
			exit(1);
		}
		input[input_len] = (decode_hex_digit(arg[0]) << 4) |
				    decode_hex_digit(arg[1]);
		arg += 2;
	}
	if (!is_septet && input_len > 140)
		goto toolong;
	if (udhi) {
		if (!input_len) {
			fprintf(stderr, ERR_PREFIX
				"empty message is invalid with UDHI\n",
				input_lineno);
			exit(1);
		}
		udhl = input[0];
		udhl1 = udhl + 1;
		if (udhl1 > input_len) {
			fprintf(stderr, ERR_PREFIX "UDHL exceeds UD length\n",
				input_lineno);
			exit(1);
		}
	}
	if (!is_septet) {
		make_pdu(input_len, input, input_len, udhi);
		return;
	}
	if (udhi)
		udh_chars = (udhl1 * 8 + 6) / 7;
	else {
		udhl1 = 0;
		udh_chars = 0;
	}
	plain_chars = input_len - udhl1;
	if (check_high_bit(input + udhl1, plain_chars) < 0) {
		fprintf(stderr, ERR_PREFIX "high bit set in GSM7 data\n",
			input_lineno);
		exit(1);
	}
	udl = udh_chars + plain_chars;
	if (udl > 160) {
		fprintf(stderr, ERR_PREFIX
			"message exceeds 160 septets after UDH\n",
			input_lineno);
		exit(1);
	}
	udl_octets = (udl * 7 + 7) / 8;
	bzero(ud7, 160);
	bcopy(input + udhl1, ud7 + udh_chars, plain_chars);
	gsm7_pack(ud7, octbuf, udl_octets);
	if (udhi)
		bcopy(input, octbuf, udhl1);
	make_pdu(udl, octbuf, udl_octets, udhi);
}

void
cmd_msg_plain(argc, argv)
	char **argv;
{
	cmd_msg_common(argv[1], 0);
}

void
cmd_msg_udh(argc, argv)
	char **argv;
{
	cmd_msg_common(argv[1], 1);
}
