OBJS=	alpha_addr.o alpha_addr_enc.o check_high_bit.o decode_helpers.o \
	grokdcs.o gsm7_decode.o gsm7_decode_qstring.o gsm7_decode_tables.o \
	gsm7_encode.o gsm7_encode2.o gsm7_encode_table.o gsm7_pack.o \
	gsm7_unpack.o gsmtime_dec.o gsmtime_enc.o hexdecode.o hexdigits.o \
	hexdump.o hexout.o number_decode.o number_encode.o scaddr.o \
	ucs2_bigend.o ucs2_decode.o utf8_decode.o utf8_decode2.o
LIB=	libcoding.a

include ../config.defs

all:	${LIB}

${LIB}:	${OBJS}
	ar rcu $@ ${OBJS}
	ranlib $@

clean:
	rm -f *.[oa] errs
