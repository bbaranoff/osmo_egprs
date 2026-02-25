PROG=	sms-encode-text
OBJS=	concat_refno.o gsm7.o main.o ucs2.o
LIBS=	../libcoding/libcoding.a

include ../config.defs

all:	${PROG}

${PROG}:	${OBJS} ${LIBS}
	${CC} ${CFLAGS} -o $@ ${OBJS} ${LIBS}

install:	${PROG}
	mkdir -p ${DESTDIR}${bindir}
	install -c ${PROG} ${DESTDIR}${bindir}

clean:
	rm -f *.o *.out *errs ${PROG}
