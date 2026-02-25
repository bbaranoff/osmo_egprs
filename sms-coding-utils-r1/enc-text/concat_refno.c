/*
 * This module contains the messy code for automatic generation and
 * increment of concat SMS reference numbers.
 */

#include <sys/types.h>
#include <sys/param.h>
#include <sys/file.h>
#include <sys/time.h>
#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

static int
initial_seed()
{
	struct timeval tv;
	u_char refno, *cp, *endp;

	gettimeofday(&tv, 0);
	cp = (u_char *) &tv;
	endp = cp + sizeof(struct timeval);
	refno = 0;
	while (cp < endp)
		refno ^= *cp++;
	return refno;
}

get_concsms_refno_from_host_fs()
{
	char *homedir, statefile[MAXPATHLEN];
	int fd, cc;
	char buf[6];
	u_char refno;

	homedir = getenv("HOME");
	if (!homedir) {
		fprintf(stderr,
		"error: no HOME= defined, needed for concat SMS refno\n");
		exit(1);
	}
	sprintf(statefile, "%s/.concat_sms_refno", homedir);
	fd = open(statefile, O_RDWR|O_CREAT, 0666);
	if (fd < 0) {
		perror(statefile);
		exit(1);
	}
	cc = read(fd, buf, 5);
	if (cc == 5 && buf[0] == '0' && buf[1] == 'x' && isxdigit(buf[2]) &&
	    isxdigit(buf[3]) && buf[4] == '\n')
		refno = strtoul(buf, 0, 16) + 1;
	else
		refno = initial_seed();
	sprintf(buf, "0x%02X\n", refno);
	lseek(fd, 0, SEEK_SET);
	write(fd, buf, 5);
	close(fd);
	return refno;
}
