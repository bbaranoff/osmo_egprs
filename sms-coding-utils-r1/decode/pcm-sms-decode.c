#include <sys/types.h>
#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>

extern int ascii_ext_mode, global_hexdump_mode;
extern u_char pdu[176];
extern unsigned pdu_length;

static char *infname;
static FILE *inf;
static unsigned start_recno;

static char *msgtype[4] = {"received", "received unread", "sent",
			   "stored unsent"};

static
process_cmdline(argc, argv)
	char **argv;
{
	int c;
	extern int optind;

	while ((c = getopt(argc, argv, "ehsu")) != EOF)
		switch (c) {
		case 'e':
			ascii_ext_mode = 1;
			continue;
		case 'h':
			global_hexdump_mode = 1;
			continue;
		case 's':
			start_recno = 1;
			continue;
		case 'u':
			ascii_ext_mode = 2;
			continue;
		default:
			fprintf(stderr, "%s: invalid option\n", argv[0]);
			exit(1);
		}
	if (argc != optind + 1) {
		fprintf(stderr, "usage: %s [options] pcm-sms-binfile\n",
			argv[0]);
		exit(1);
	}
	infname = argv[optind];
}

main(argc, argv)
	char **argv;
{
	u_char record[176];
	unsigned recno;

	process_cmdline(argc, argv);
	inf = fopen(infname, "r");
	if (!inf) {
		perror(infname);
		exit(1);
	}
	pdu_length = 176;
	for (recno = start_recno; fread(record, sizeof record, 1, inf);
	     recno++) {
		if (record[0] & 1) {
			printf("Record #%u is %s message:\n", recno,
				msgtype[(record[0] >> 1) & 3]);
			bcopy(record + 1, pdu, 175);
			process_pdu(0, 1);
			putchar('\n');
		} else
			printf("Record #%u is empty\n\n", recno);
	}
	exit(0);
}
