/*
 * This module implements input handling for sms-gen-tpdu.
 */

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include "error.h"

extern char input_line[];
extern int input_lineno;

extern void set_sc_addr();
extern void set_user_addr();
extern void set_mr_byte();
extern void set_pid_byte();
extern void set_dcs();
extern void set_scts();
extern void set_vp_abs();
extern void set_vp_rel();
extern void set_flag_rp();
extern void set_flag_sr();
extern void set_flag_lp();
extern void set_flag_mms();
extern void set_flag_rd();
extern void cmd_msg_plain();
extern void cmd_msg_udh();

static struct cmdtab {
	char *cmd;
	int minargs;
	int maxargs;
	void (*func)();
} cmdtab[] = {
	{"sc-addr", 1, 1, set_sc_addr},
	{"user-addr", 1, 1, set_user_addr},
	{"mr", 1, 1, set_mr_byte},
	{"pid", 1, 1, set_pid_byte},
	{"dcs", 2, 2, set_dcs},
	{"sc-ts", 1, 1, set_scts},
	{"vp-abs", 1, 1, set_vp_abs},
	{"vp-rel", 1, 1, set_vp_rel},
	{"rp", 0, 0, set_flag_rp},
	{"sr", 0, 0, set_flag_sr},
	{"lp", 0, 0, set_flag_lp},
	{"mms", 0, 0, set_flag_mms},
	{"rd", 0, 0, set_flag_rd},
	{"msg", 1, 1, cmd_msg_plain},
	{"msg-udh", 1, 1, cmd_msg_udh},
	/* table search terminator */
	{0, 0, 0, 0}
};

void
process_input_line()
{
	char *argv[10];
	char *cp, **ap;
	struct cmdtab *tp;

	cp = index(input_line, '\n');
	if (!cp) {
		fprintf(stderr, ERR_PREFIX "missing newline\n", input_lineno);
		exit(1);
	}
	for (cp = input_line; isspace(*cp); cp++)
		;
	if (*cp == '\0' || *cp == '#')
		return;
	argv[0] = cp;
	while (*cp && !isspace(*cp))
		cp++;
	if (*cp)
		*cp++ = '\0';
	for (tp = cmdtab; tp->cmd; tp++)
		if (!strcmp(tp->cmd, argv[0]))
			break;
	if (!tp->func) {
		fprintf(stderr, ERR_PREFIX "invalid command \"%s\"\n",
			input_lineno, argv[0]);
		exit(1);
	}
	for (ap = argv + 1; ; ) {
		while (isspace(*cp))
			cp++;
		if (!*cp || *cp == '#')
			break;
		if (ap - argv - 1 >= tp->maxargs) {
			fprintf(stderr, ERR_PREFIX "too many arguments\n",
				input_lineno);
			exit(1);
		}
		if (*cp == '"') {
			*ap++ = ++cp;
			for (;;) {
				if (!*cp) {
unterm_qstring:				fprintf(stderr, ERR_PREFIX
						"unterminated quoted string\n",
						input_lineno);
					exit(1);
				}
				if (*cp == '"')
					break;
				if (*cp++ == '\\') {
					if (!*cp)
						goto unterm_qstring;
					cp++;
				}
			}
			*cp++ = '\0';
		} else {
			*ap++ = cp;
			while (*cp && !isspace(*cp))
				cp++;
			if (*cp)
				*cp++ = '\0';
		}
	}
	if (ap - argv - 1 < tp->minargs) {
		fprintf(stderr, ERR_PREFIX "too few arguments\n", input_lineno);
		exit(1);
	}
	*ap = 0;
	tp->func(ap - argv, argv);
}
