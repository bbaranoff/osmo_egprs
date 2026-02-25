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
static int keep_raw_pdu, pdu_has_sca = 1;

static char input_line[1024];

static
process_cmdline(argc, argv)
	char **argv;
{
	int c;
	extern int optind;

	while ((c = getopt(argc, argv, "ehnpu")) != EOF)
		switch (c) {
		case 'e':
			ascii_ext_mode = 1;
			continue;
		case 'h':
			global_hexdump_mode = 1;
			continue;
		case 'n':
			pdu_has_sca = 0;
			continue;
		case 'p':
			keep_raw_pdu = 1;
			continue;
		case 'u':
			ascii_ext_mode = 2;
			continue;
		default:
			fprintf(stderr, "%s: invalid option\n", argv[0]);
			exit(1);
		}
	if (argc > optind)
		infname = argv[optind];
}

static
swallow_empty_line()
{
	int c;

	c = getc(inf);
	if (c != '\n')
		ungetc(c, inf);
}

main(argc, argv)
	char **argv;
{
	char *nl;
	int lineno, cc;

	process_cmdline(argc, argv);
	if (infname) {
		inf = fopen(infname, "r");
		if (!inf) {
			perror(infname);
			exit(1);
		}
	} else {
		inf = stdin;
		infname = "stdin";
	}
	for (lineno = 1; fgets(input_line, sizeof input_line, inf); lineno++) {
		nl = index(input_line, '\n');
		if (!nl) {
			fprintf(stderr, "%s line %d: no newline\n",
				infname, lineno);
			exit(1);
		}
		*nl = '\0';
		cc = decode_hex_line(input_line, pdu, sizeof pdu);
		if (cc <= 0) {
			puts(input_line);
			continue;
		}
		pdu_length = cc;
		if (keep_raw_pdu)
			printf("%s\n\n", input_line);
		process_pdu(1, pdu_has_sca);
		putchar('\n');
		swallow_empty_line();
	}
	exit(0);
}
