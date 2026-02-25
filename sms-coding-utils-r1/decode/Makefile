PROGS=	pcm-sms-decode sms-pdu-decode
LIB=	../libcoding/libcoding.a
OBJS0=	pcm-sms-decode.o pdu-common.o ${LIB}
OBJS1=	pdu-common.o sms-pdu-decode.o ${LIB}

include ../config.defs

all:	${PROGS}

pcm-sms-decode:	${OBJS0}
	${CC} ${CFLAGS} -o $@ ${OBJS0}

sms-pdu-decode:	${OBJS1}
	${CC} ${CFLAGS} -o $@ ${OBJS1}

install:
	mkdir -p ${DESTDIR}${bindir}
	install -c ${PROGS} ${DESTDIR}${bindir}

clean:
	rm -f ${PROGS} *.o *errs *.out
