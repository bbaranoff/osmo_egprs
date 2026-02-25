/*
 * This module implements automatic generation of SC-Timestamp
 * based on the current time.
 */

#include <sys/types.h>
#include <stdio.h>
#include <time.h>

extern u_char scts_buf[7];
extern int scts_is_set;

void
set_auto_scts()
{
	time_t unixtime;
	struct tm *tm;
	char timestr[32];

	time(&unixtime);
	tm = localtime(&unixtime);
	sprintf(timestr, "%02d/%02d/%02d,%02d:%02d:%02d%+03d",
		tm->tm_year % 100, tm->tm_mon + 1, tm->tm_mday,
		tm->tm_hour, tm->tm_min, tm->tm_sec, tm->tm_gmtoff / (15*60));
	encode_gsm_sms_abstime(timestr, scts_buf);
	scts_is_set = 1;
}
