/*
 * This C file is the main module for sms-gen-tpdu utility.
 */

#include <sys/types.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

int dir_mo, include_sca;
u_char sc_addr[12], user_addr[12];
u_char mr_byte, pid_byte, dcs_byte;
u_char scts_buf[7];
u_char vp_format, vp_buf[7];
int is_septet, scts_is_set;
int flag_rp, flag_sr, flag_lp, flag_mms, flag_rd;

char input_line[512];
int input_lineno;

static void
init_defaults()
{
	sc_addr[0] = 0;
	user_addr[0] = 0;
	user_addr[1] = 0x80;
	mr_byte = 0xFF;
	pid_byte = 0;
	dcs_byte = 0;
	is_septet = 1;
}

main(argc, argv)
	char **argv;
{
	if (argc != 2) {
usage:		fprintf(stderr, "usage: %s mo|mt|sc-mo|sc-mt\n", argv[0]);
		exit(1);
	}
	if (!strcmp(argv[1], "mo")) {
		dir_mo = 1;
		include_sca = 0;
	} else if (!strcmp(argv[1], "mt")) {
		dir_mo = 0;
		include_sca = 0;
	} else if (!strcmp(argv[1], "sc-mo")) {
		dir_mo = 1;
		include_sca = 1;
	} else if (!strcmp(argv[1], "sc-mt")) {
		dir_mo = 0;
		include_sca = 1;
	} else
		goto usage;
	init_defaults();
	for (input_lineno = 1; fgets(input_line, sizeof input_line, stdin);
	     input_lineno++)
		process_input_line();
	exit(0);
}
