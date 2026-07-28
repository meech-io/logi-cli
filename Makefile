PREFIX ?= /usr/local
SOURCES := $(wildcard Sources/logi/*.swift)

logi: $(SOURCES)
	swiftc -O -o logi $(SOURCES) -framework IOKit -framework CoreFoundation

install: logi
	install -d $(PREFIX)/bin
	install -m 755 logi $(PREFIX)/bin/logi

clean:
	rm -f logi

.PHONY: install clean
