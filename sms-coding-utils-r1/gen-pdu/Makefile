PROG=	sms-gen-tpdu
OBJS=	auto_scts.o input.o main.o message.o settings.o
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
