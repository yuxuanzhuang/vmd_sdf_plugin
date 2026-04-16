CXX ?= c++
CPPFLAGS ?=
CXXFLAGS ?= -std=c++17 -O2 -fPIC -Wall -Wextra

VMD_INCLUDE_DIR ?= include
SRC := src/sdfplugin.cpp
PACKAGE_VERSION ?= dev

UNAME_S := $(shell uname -s)
UNAME_M := $(shell uname -m)

ifeq ($(OS),Windows_NT)
OS_NAME := windows
PLUGIN_EXT := dll
ARCHIVE_EXT := zip
CPPFLAGS += -DVMDPLUGIN_EXPORTS
SHARED_LDFLAGS ?= -shared -static-libgcc -static-libstdc++
else ifneq (,$(filter MINGW% MSYS% CYGWIN%,$(UNAME_S)))
OS_NAME := windows
PLUGIN_EXT := dll
ARCHIVE_EXT := zip
CPPFLAGS += -DVMDPLUGIN_EXPORTS
SHARED_LDFLAGS ?= -shared -static-libgcc -static-libstdc++
else ifeq ($(UNAME_S),Darwin)
OS_NAME := darwin
PLUGIN_EXT := so
ARCHIVE_EXT := tar.gz
SHARED_LDFLAGS ?= -bundle -undefined dynamic_lookup
else ifeq ($(UNAME_S),Linux)
OS_NAME := linux
PLUGIN_EXT := so
ARCHIVE_EXT := tar.gz
SHARED_LDFLAGS ?= -shared
else
$(error Unsupported platform '$(UNAME_S)'; set SHARED_LDFLAGS explicitly)
endif

OUT := molfile/sdfplugin.$(PLUGIN_EXT)

.PHONY: all clean package print-package-file

all: $(OUT)

$(OUT): $(SRC) $(VMD_INCLUDE_DIR)/molfile_plugin.h $(VMD_INCLUDE_DIR)/vmdplugin.h
	mkdir -p "$(dir $(OUT))"
	$(CXX) $(CPPFLAGS) -I"$(VMD_INCLUDE_DIR)" $(CXXFLAGS) $(SHARED_LDFLAGS) -o "$(OUT)" "$(SRC)"

package: $(OUT)
	./scripts/package_release.sh "$(PACKAGE_VERSION)"

print-package-file:
	@printf '%s\n' "dist/vmd-sdf-plugin-$(PACKAGE_VERSION)-$(OS_NAME)-$(UNAME_M).$(ARCHIVE_EXT)"

clean:
	rm -f molfile/sdfplugin.so molfile/sdfplugin.dll
	rm -rf dist
