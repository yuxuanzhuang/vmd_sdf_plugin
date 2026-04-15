CXX := clang++
CXXFLAGS := -std=c++17 -O2 -fPIC -Wall -Wextra -I"/Applications/VMD 1.9.4a57-arm64-Rev12.app/Contents/vmd/plugins/include"
LDFLAGS := -bundle

SRC := src/sdfplugin.cpp
OUT := molfile/sdfplugin.so

.PHONY: all clean

all: $(OUT)

$(OUT): $(SRC)
	mkdir -p "$(dir $(OUT))"
	$(CXX) $(CXXFLAGS) $(LDFLAGS) -o "$(OUT)" "$(SRC)"

clean:
	rm -f "$(OUT)"
