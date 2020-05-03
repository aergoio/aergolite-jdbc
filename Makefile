
include Makefile.common

RESOURCE_DIR = src/main/resources

.phony: all package native native-all deploy

all: jni-header package

deploy: 
	mvn package deploy -DperformRelease=true

MVN:=mvn
SRC:=src/main/java
SQLITE_OUT:=$(TARGET)/$(sqlite)-$(OS_NAME)-$(OS_ARCH)
SQLITE_UNPACKED:=$(TARGET)/sqlite-unpack.log

ifndef SQLITE_SOURCE
$(error set SQLITE_SOURCE variable)
endif

ifneq ($(OS_NAME),Windows)
FPICFLAGS := CFLAGS=-fPIC
endif


CCFLAGS:= -I$(SQLITE_OUT) -I$(SQLITE_SOURCE) -I$(binn_inc) -I$(libuv_inc) -I$(libsecp_inc) $(CCFLAGS)

LINKFLAGS:= $(binn_fpath) $(libuv_fpath) $(libsecp_fpath) $(LINKFLAGS)


libuv:
	git clone --depth=1 https://github.com/libuv/libuv

binn:
	git clone --depth=1 https://github.com/liteserver/binn

secp256k1-vrf:
	git clone --depth=1 https://github.com/aergoio/secp256k1-vrf


$(libuv_fpath): libuv
ifeq ($(OS_NAME),Mac)
	mkdir -p libuv/.libs/
	cp mac/libuv.a libuv/.libs/
else
	cd libuv && ./autogen.sh
	cd libuv && ./configure --host=$(HOST) --disable-shared $(FPICFLAGS)
	cd libuv && make
endif

$(binn_fpath): binn
	cd binn && make static $(FPICFLAGS)

$(libsecp_fpath): secp256k1-vrf
	cd secp256k1-vrf && ./autogen.sh
	cd secp256k1-vrf && ./configure --host=$(HOST) --disable-shared $(FPICFLAGS)
	cd secp256k1-vrf && make


$(SQLITE_UNPACKED):
	@mkdir -p $(@D)
	touch $@

$(TARGET)/common-lib/org/sqlite/%.class: src/main/java/org/sqlite/%.java
	@mkdir -p $(@D)
	$(JAVAC) -source 1.6 -target 1.6 -sourcepath $(SRC) -d $(TARGET)/common-lib $<

jni-header: $(TARGET)/common-lib/NativeDB.h

$(TARGET)/common-lib/NativeDB.h: src/main/java/org/sqlite/core/NativeDB.java
	@mkdir -p $(TARGET)/common-lib
	$(JAVAC) -d $(TARGET)/common-lib -sourcepath $(SRC) -h $(TARGET)/common-lib src/main/java/org/sqlite/core/NativeDB.java
	mv target/common-lib/org_sqlite_core_NativeDB.h target/common-lib/NativeDB.h

test:
	mvn test

clean: clean-native clean-java clean-tests


$(SQLITE_OUT)/sqlite3.o : $(SQLITE_UNPACKED) binn libuv secp256k1-vrf
	@mkdir -p $(@D)
	perl -p -e "s/sqlite3_api;/sqlite3_api = 0;/g" \
	    $(SQLITE_SOURCE)/sqlite3ext.h > $(SQLITE_OUT)/sqlite3ext.h
# insert a code for loading extension functions
	perl -p -e "s/^opendb_out:/  if(!db->mallocFailed && rc==SQLITE_OK){ rc = RegisterExtensionFunctions(db); }\nopendb_out:/;" \
	    $(SQLITE_SOURCE)/sqlite3.c > $(SQLITE_OUT)/sqlite3.c
	cat src/main/ext/*.c >> $(SQLITE_OUT)/sqlite3.c
	$(CC) -o $@ -c $(CCFLAGS) \
	    -DSQLITE_ENABLE_LOAD_EXTENSION=1 \
	    -DSQLITE_HAVE_ISNAN \
	    -DSQLITE_HAVE_USLEEP \
	    -DHAVE_USLEEP=1 \
	    -DSQLITE_ENABLE_COLUMN_METADATA \
	    -DSQLITE_CORE \
	    -DSQLITE_ENABLE_FTS3 \
	    -DSQLITE_ENABLE_FTS3_PARENTHESIS \
	    -DSQLITE_ENABLE_FTS5 \
	    -DSQLITE_ENABLE_JSON1 \
	    -DSQLITE_ENABLE_RTREE \
	    -DSQLITE_ENABLE_STAT2 \
	    -DSQLITE_THREADSAFE=1 \
	    -DSQLITE_DEFAULT_MEMSTATUS=0 \
	    -DSQLITE_DEFAULT_FILE_PERMISSIONS=0666 \
	    -DSQLITE_MAX_VARIABLE_NUMBER=250000 \
	    -DSQLITE_MAX_MMAP_SIZE=1099511627776 \
	    $(SQLITE_FLAGS) \
	    $(SQLITE_OUT)/sqlite3.c

$(SQLITE_OUT)/$(LIBNAME): jni-header $(SQLITE_OUT)/sqlite3.o $(SRC)/org/sqlite/core/NativeDB.c $(binn_fpath) $(libuv_fpath) $(libsecp_fpath)
	@mkdir -p $(@D)
	$(CC) $(CCFLAGS) -I $(TARGET)/common-lib -c -o $(SQLITE_OUT)/NativeDB.o $(SRC)/org/sqlite/core/NativeDB.c
	$(CC) $(CCFLAGS) -o $@ $(SQLITE_OUT)/*.o $(LINKFLAGS)
# Workaround for strip Protocol error when using VirtualBox on Mac
	cp $@ /tmp/$(@F)
	$(STRIP) /tmp/$(@F)
	cp /tmp/$(@F) $@

NATIVE_DIR=src/main/resources/org/sqlite/native/$(OS_NAME)/$(OS_ARCH)
NATIVE_TARGET_DIR:=$(TARGET)/classes/org/sqlite/native/$(OS_NAME)/$(OS_ARCH)
NATIVE_DLL:=$(NATIVE_DIR)/$(LIBNAME)

# For cross-compilation, install docker. See also https://github.com/dockcross/dockcross
# Disabled linux-armv6 build because of this issue; https://github.com/dockcross/dockcross/issues/190
native-all: native win32 win64 mac64 linux32 linux64 linux-arm linux-armv7 linux-arm64 linux-android-arm linux-ppc64

native: $(NATIVE_DLL)

$(NATIVE_DLL): $(SQLITE_OUT)/$(LIBNAME)
	@mkdir -p $(@D)
	cp $< $@
	@mkdir -p $(NATIVE_TARGET_DIR)
	cp $< $(NATIVE_TARGET_DIR)/$(LIBNAME)
	#cp $< libsqlitejdbc.jnilib

DOCKER_RUN_OPTS=--rm

win32: $(SQLITE_UNPACKED) jni-header
	./docker/dockcross-windows-x86 -a $(DOCKER_RUN_OPTS) bash -c 'make clean-native native HOST=i686-w64-mingw32.static OS_NAME=Windows OS_ARCH=x86 SQLITE_SOURCE="$(SQLITE_SOURCE)"'

win64: $(SQLITE_UNPACKED) jni-header
	./docker/dockcross-windows-x64 -a $(DOCKER_RUN_OPTS) bash -c 'make clean-native native HOST=x86_64-w64-mingw32.static OS_NAME=Windows OS_ARCH=x86_64 SQLITE_SOURCE="$(SQLITE_SOURCE)"'

linux32: $(SQLITE_UNPACKED) jni-header
	docker run $(DOCKER_RUN_OPTS) -ti -v $$PWD:/work xerial/centos5-linux-x86 bash -c 'make clean-native native OS_NAME=Linux OS_ARCH=x86 SQLITE_SOURCE="$(SQLITE_SOURCE)"'

linux64: $(SQLITE_UNPACKED) jni-header
	docker run $(DOCKER_RUN_OPTS) -ti -v $$PWD:/work xerial/centos5-linux-x86_64 bash -c 'make clean-native native OS_NAME=Linux OS_ARCH=x86_64 SQLITE_SOURCE="$(SQLITE_SOURCE)"'

alpine-linux64: $(SQLITE_UNPACKED) jni-header
	docker run $(DOCKER_RUN_OPTS) -ti -v $$PWD:/work xerial/alpine-linux-x86_64 bash -c 'make clean-native native OS_NAME=Linux OS_ARCH=x86_64 SQLITE_SOURCE="$(SQLITE_SOURCE)"'

linux-arm: $(SQLITE_UNPACKED) jni-header
	./docker/dockcross-armv5 -a $(DOCKER_RUN_OPTS) bash -c 'make clean-native native HOST=/usr/xcc/armv5-unknown-linux-gnueabi/bin/armv5-unknown-linux-gnueabi OS_NAME=Linux OS_ARCH=arm SQLITE_SOURCE="$(SQLITE_SOURCE)"'

linux-armv6: $(SQLITE_UNPACKED) jni-header
	./docker/dockcross-armv6 -a $(DOCKER_RUN_OPTS) bash -c 'make clean-native native HOST=arm-linux-gnueabihf OS_NAME=Linux OS_ARCH=armv6 SQLITE_SOURCE="$(SQLITE_SOURCE)"'

linux-armv7: $(SQLITE_UNPACKED) jni-header
	./docker/dockcross-armv7 -a $(DOCKER_RUN_OPTS) bash -c 'make clean-native native HOST=armv7-unknown-linux-gnueabi OS_NAME=Linux OS_ARCH=armv7 SQLITE_SOURCE="$(SQLITE_SOURCE)"'

linux-arm64: $(SQLITE_UNPACKED) jni-header
	./docker/dockcross-arm64 -a $(DOCKER_RUN_OPTS) bash -c 'make clean-native native HOST=aarch64-unknown-linux-gnueabi OS_NAME=Linux OS_ARCH=aarch64 SQLITE_SOURCE="$(SQLITE_SOURCE)"'

linux-android-arm: $(SQLITE_UNPACKED) jni-header
	./docker/dockcross-android-arm -a $(DOCKER_RUN_OPTS) bash -c 'export PATH=/usr/arm-linux-androideabi/bin:$$PATH && make clean-native native HOST=arm-linux-androideabi OS_NAME=Linux OS_ARCH=android-arm SQLITE_SOURCE="$(SQLITE_SOURCE)"'

linux-ppc64: $(SQLITE_UNPACKED) jni-header
	./docker/dockcross-ppc64 -a $(DOCKER_RUN_OPTS) bash -c 'make clean-native native HOST=powerpc64le-linux-gnu OS_NAME=Linux OS_ARCH=ppc64 SQLITE_SOURCE="$(SQLITE_SOURCE)"'

mac64: $(SQLITE_UNPACKED) jni-header
	docker run -it $(DOCKER_RUN_OPTS) -v $$PWD:/workdir -e CROSS_TRIPLE=x86_64-apple-darwin multiarch/crossbuild make clean-native native HOST=x86_64-apple-darwin OS_NAME=Mac OS_ARCH=x86_64 SQLITE_SOURCE="$(SQLITE_SOURCE)"

# deprecated
mac32: $(SQLITE_UNPACKED) jni-header
	docker run -it $(DOCKER_RUN_OPTS) -v $$PWD:/workdir -e CROSS_TRIPLE=i386-apple-darwin multiarch/crossbuild make clean-native native HOST=i386-apple-darwin OS_NAME=Mac OS_ARCH=x86 SQLITE_SOURCE="$(SQLITE_SOURCE)"

sparcv9:
	$(MAKE) native OS_NAME=SunOS OS_ARCH=sparcv9 SQLITE_SOURCE="$(SQLITE_SOURCE)"

package: native-all
	rm -rf target/dependency-maven-plugin-markers
	$(MVN) package

clean-native:
	rm -rf $(SQLITE_OUT)
	#rm -f $(binn_fpath)
	#rm -f $(libuv_fpath)
	#rm -f $(libsecp_fpath)
	-cd binn && make clean
	-cd libuv && make clean
	-cd secp256k1-vrf && make clean

clean-java:
	rm -rf $(TARGET)/*classes
	rm -rf $(TARGET)/common-lib/*
	rm -rf $(TARGET)/sqlite-jdbc-*jar

clean-tests:
	rm -rf $(TARGET)/{surefire*,testdb.jar*}

docker-linux64:
	docker build -f docker/Dockerfile.linux_x86_64 -t xerial/centos5-linux-x86_64 .

docker-linux32:
	docker build -f docker/Dockerfile.linux_x86 -t xerial/centos5-linux-x86 .

docker-alpine-linux64:
	docker build -f docker/Dockerfile.alpine-linux_x86_64 -t xerial/alpine-linux-x86_64 .
