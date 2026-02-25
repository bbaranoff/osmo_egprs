/*
 * This module implements functions for various settings that come before
 * msg or msg-udh lines.
 */

#include <sys/types.h>
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

void
set_sc_addr(argc, argv)
	char **argv;
{
	int rc;

	if (!include_sca) {
		fprintf(stderr, ERR_PREFIX
			"sc-addr is not allowed in bare TPDU mode\n",
			input_lineno);
		exit(1);
	}
	rc = encode_phone_number_arg(argv[1], sc_addr, 0);
	if (rc < 0) {
		fprintf(stderr, ERR_PREFIX "invalid SC-address argument\n",
			input_lineno);
		exit(1);
	}
}

void
set_user_addr(argc, argv)
	char **argv;
{
	int rc;
	char *err_desc;

	if (!strncmp(argv[1], "alpha:", 6)) {
		rc = encode_alpha_addr(argv[1] + 6, user_addr);
		err_desc = "alpha address";
	} else {
		rc = encode_phone_number_arg(argv[1], user_addr, 1);
		err_desc = "phone number";
	}
	if (rc < 0) {
		fprintf(stderr, ERR_PREFIX "invalid %s argument\n",
			input_lineno, err_desc);
		exit(1);
	}
}

void
set_mr_byte(argc, argv)
	char **argv;
{
	char *endp;

	if (!dir_mo) {
		fprintf(stderr, ERR_PREFIX "mr is not allowed in MT mode\n",
			input_lineno);
		exit(1);
	}
	mr_byte = strtoul(argv[1], &endp, 0);
	if (*endp) {
		fprintf(stderr, ERR_PREFIX "invalid byte value argument\n",
			input_lineno);
		exit(1);
	}
}

void
set_pid_byte(argc, argv)
	char **argv;
{
	char *endp;

	pid_byte = strtoul(argv[1], &endp, 0);
	if (*endp) {
		fprintf(stderr, ERR_PREFIX "invalid byte value argument\n",
			input_lineno);
		exit(1);
	}
}

void
set_dcs(argc, argv)
	char **argv;
{
	char *endp;

	dcs_byte = strtoul(argv[1], &endp, 0);
	if (*endp) {
		fprintf(stderr, ERR_PREFIX "invalid byte value argument\n",
			input_lineno);
		exit(1);
	}
	if (!strcmp(argv[2], "septet"))
		is_septet = 1;
	else if (!strcmp(argv[2], "octet"))
		is_septet = 0;
	else {
		fprintf(stderr, ERR_PREFIX "invalid septet/octet mode kw\n",
			input_lineno);
		exit(1);
	}
}

void
set_scts(argc, argv)
	char **argv;
{
	int rc;

	if (dir_mo) {
		fprintf(stderr, ERR_PREFIX "sc-ts is not allowed in MO mode\n",
			input_lineno);
		exit(1);
	}
	rc = encode_gsm_sms_abstime(argv[1], scts_buf);
	if (rc < 0) {
		fprintf(stderr, ERR_PREFIX "invalid timestamp argument\n",
			input_lineno);
		exit(1);
	}
	scts_is_set = 1;
}

void
set_vp_abs(argc, argv)
	char **argv;
{
	int rc;

	if (!dir_mo) {
		fprintf(stderr, ERR_PREFIX "vp-abs is not allowed in MT mode\n",
			input_lineno);
		exit(1);
	}
	rc = encode_gsm_sms_abstime(argv[1], vp_buf);
	if (rc < 0) {
		fprintf(stderr, ERR_PREFIX "invalid timestamp argument\n",
			input_lineno);
		exit(1);
	}
	vp_format = 0x18;
}

void
set_vp_rel(argc, argv)
	char **argv;
{
	char *endp;

	if (!dir_mo) {
		fprintf(stderr, ERR_PREFIX "vp-rel is not allowed in MT mode\n",
			input_lineno);
		exit(1);
	}
	vp_buf[0] = strtoul(argv[1], &endp, 0);
	if (*endp) {
		fprintf(stderr, ERR_PREFIX "invalid byte value argument\n",
			input_lineno);
		exit(1);
	}
	vp_format = 0x10;
}

void
set_flag_rp()
{
	flag_rp = 1;
}

void
set_flag_sr()
{
	flag_sr = 1;
}

void
set_flag_lp()
{
	if (dir_mo) {
		fprintf(stderr, ERR_PREFIX "lp is not allowed in MO mode\n",
			input_lineno);
		exit(1);
	}
	flag_lp = 1;
}

void
set_flag_mms()
{
	if (dir_mo) {
		fprintf(stderr, ERR_PREFIX "mms is not allowed in MO mode\n",
			input_lineno);
		exit(1);
	}
	flag_mms = 1;
}

void
set_flag_rd()
{
	if (!dir_mo) {
		fprintf(stderr, ERR_PREFIX "rd is not allowed in MT mode\n",
			input_lineno);
		exit(1);
	}
	flag_rd = 1;
}
