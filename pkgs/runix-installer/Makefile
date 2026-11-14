CXX ?= c++
PKG_CONFIG ?= pkg-config
PREFIX ?= /usr/local

NCURSES_CFLAGS := $(shell $(PKG_CONFIG) --cflags ncursesw 2>/dev/null)
NCURSES_LIBS := $(shell $(PKG_CONFIG) --libs ncursesw 2>/dev/null || echo -lncursesw)

CXXFLAGS ?= -O2 -g
CXXFLAGS += -std=c++20 -Wall -Wextra -Wno-missing-field-initializers -DNCURSES_WIDECHAR=1 $(NCURSES_CFLAGS)
LDLIBS += $(NCURSES_LIBS) -pthread

CORE := src/json.cpp src/util.cpp src/nixlog.cpp src/config.cpp src/process.cpp \
	src/system.cpp src/install.cpp src/report.cpp src/app.cpp src/ui.cpp
CORE_OBJECTS := $(CORE:.cpp=.o)

all: runix-installer

runix-installer: $(CORE_OBJECTS) src/main.o
	$(CXX) $(CXXFLAGS) $(LDFLAGS) -o $@ $^ $(LDLIBS)

runix-installer-tests: $(CORE_OBJECTS) tests/tests.o
	$(CXX) $(CXXFLAGS) $(LDFLAGS) -o $@ $^ $(LDLIBS)

%.o: %.cpp $(wildcard src/*.hpp)
	$(CXX) $(CXXFLAGS) -c -o $@ $<

check: runix-installer-tests
	./runix-installer-tests

install: runix-installer
	install -Dm755 runix-installer $(DESTDIR)$(PREFIX)/bin/runix-installer

clean:
	rm -f src/*.o tests/*.o runix-installer runix-installer-tests

.PHONY: all check install clean
