CC = arm-linux-gnueabihf-gcc
CFLAGS = -Os -s -Wall -Wextra \
         -ffunction-sections -fdata-sections \
         -Wl,--gc-sections -flto
LDFLAGS = --sysroot=/home/ywz/void/rootfs
LDLIBS = -lncursesw
TARGET = systemsettings
PREFIX ?= /opt/bin

all: $(TARGET)

$(TARGET): systemsettings.c
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $< $(LDLIBS)

clean:
	rm -f $(TARGET)

install: $(TARGET)
	install -Dm755 $(TARGET) $(DESTDIR)$(PREFIX)/$(TARGET)

.PHONY: all clean install
