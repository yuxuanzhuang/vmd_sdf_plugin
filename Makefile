CXX ?= c++
CPPFLAGS ?=
CXXFLAGS ?= -std=c++17 -O2 -fPIC -Wall -Wextra

VMD_INCLUDE_DIR ?= include
SRC := src/sdfplugin.cpp
OUT := molfile/sdfplugin.so
PACKAGE_VERSION ?= dev

UNAME_S := $(shell uname -s)
UNAME_M := $(shell uname -m)
OS_NAME := $(shell printf '%s' "$(UNAME_S)" | tr '[:upper:]' '[:lower:]')

ifeq ($(UNAME_S),Darwin)
SHARED_LDFLAGS ?= -bundle -undefined dynamic_lookup
else ifeq ($(UNAME_S),Linux)
SHARED_LDFLAGS ?= -shared
else
$(error Unsupported platform '$(UNAME_S)'; set SHARED_LDFLAGS explicitly)
endif

.PHONY: all clean package print-package-file

all: $(OUT)

$(OUT): $(SRC) $(VMD_INCLUDE_DIR)/molfile_plugin.h $(VMD_INCLUDE_DIR)/vmdplugin.h
	mkdir -p "$(dir $(OUT))"
	$(CXX) $(CPPFLAGS) -I"$(VMD_INCLUDE_DIR)" $(CXXFLAGS) $(SHARED_LDFLAGS) -o "$(OUT)" "$(SRC)"

package: $(OUT)
	./scripts/package_release.sh "$(PACKAGE_VERSION)"

print-package-file:
	@printf '%s\n' "dist/vmd-sdf-plugin-$(PACKAGE_VERSION)-$(OS_NAME)-$(UNAME_M).tar.gz"

clean:
	rm -f "$(OUT)"
	rm -rf dist
