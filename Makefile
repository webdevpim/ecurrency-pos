
DST_BASE=/usr/local
DST_BIN=${DST_BASE}/bin
DST_LIB=${DST_BASE}/lib
DST_ETC=${DST_BASE}/etc

INSTALL=cp -r

all:
	@echo 'Did you mean "make test" or "make install"?'

install::
	mkdir -p ${DST_LIB} && ${INSTALL} lib/* ${DST_LIB}
	mkdir -p ${DST_BIN} && ${INSTALL} bin/* ${DST_BIN}
	#mkdir -p ${DST_ETC} && ${INSTALL} -n etc/* ${DST_ETC} || true
	@echo "Install done"

PM_FILES := $(shell find lib -type f -name '*.pm')

check_syntax:: bin/* ${PM_FILES}
${PM_FILES} bin/*::
	@CONFIG_DIR=etc perl -I lib -c $@

test:: check_syntax test/*.t
test/*.t::
	@echo $@
	@CONFIG_DIR=etc LOG_NULL=1 perl -I lib $@

.PHONY: test check_syntax
