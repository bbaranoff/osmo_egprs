/*
 * This is the main module for sms-encode-text utility.
 */

#include <sys/types.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>
#include "defs.h"

int utf8_input, ucs2_mode, allow_escape;
int concat_enable, concat_refno_set;
char msgtext[MAX_MSG_CHARS*3+2];
u_char concat_refno;

process_cmdline(argc, argv)
	char **argv;
{
	int c;
	extern int optind;
	extern char *optarg;

	while ((c = getopt(argc, argv, "cC:euU")) != EOF) {
		switch (c) {
		case 'c':
			concat_enable = 1;
			continue;
		case 'C':
			concat_enable = 1;
			concat_refno = strtoul(optarg, 0, 0);
			concat_refno_set = 1;
			continue;
		case 'e':
			allow_escape = 1;
			continue;
		case 'u':
			utf8_input = 1;
			continue;
		case 'U':
			ucs2_mode = 1;
			continue;
		default:
			/* error msg already printed */
			exit(1);
		}
	}
	if (argc > optind + 1) {
		fprintf(stderr, "usage: %s [options] [message]\n", argv[0]);
		exit(1);
	}
	if (argc < optind + 1)
		return(0);
	if (strlen(argv[optind]) > MAX_MSG_CHARS*3) {
		fprintf(stderr, "error: message argument is too long\n");
		exit(1);
	}
	strcpy(msgtext, argv[optind]);
	return(1);
}

read_msgtext_from_stdin()
{
	unsigned pos, remain;
	int cc;

	pos = 0;
	remain = sizeof(msgtext);
	for (;;) {
		if (!remain) {
			fprintf(stderr,
				"error: message on stdin is too long\n");
			exit(1);
		}
		cc = read(0, msgtext + pos, remain);
		if (cc < 0) {
			fprintf(stderr, "error reading message from stdin\n");
			exit(1);
		}
		if (cc == 0)
			break;
		pos += cc;
		remain -= cc;
	}
	msgtext[pos] = '\0';
}

trim_trailing_newlines()
{
	char *cp;

	cp = index(msgtext, '\0');
	while (cp > msgtext && cp[-1] == '\n')
		cp--;
	*cp = '\0';
}

main(argc, argv)
	char **argv;
{
	if (!process_cmdline(argc, argv))
		read_msgtext_from_stdin();
	trim_trailing_newlines();
	if (ucs2_mode)
		ucs2_mode_main();
	else
		gsm7_mode_main();
}
