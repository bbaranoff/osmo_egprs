PROGDIR=decode enc-text gen-pdu scripts
LIBDIR=	libcoding
SUBDIR=	${PROGDIR} ${LIBDIR}
DESTDIR=

all:	${SUBDIR}

decode:		libcoding
enc-text:	libcoding
gen-pdu:	libcoding

${SUBDIR}: FRC config.defs
	cd $@; ${MAKE} ${MFLAGS}

config.defs:
	@echo 'You must run ./configure before make'
	@false

clean: FRC
	rm -f a.out core errs
	for i in ${SUBDIR}; do (cd $$i; ${MAKE} ${MFLAGS} clean); done

install: FRC
	for i in ${PROGDIR}; do (cd $$i; ${MAKE} ${MFLAGS} \
		DESTDIR=${DESTDIR} install); done

FRC:
