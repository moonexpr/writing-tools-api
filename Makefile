# writing-tools-api — surface macOS text tools from Objective-C.
#
#   make            build ./wtsurface (Obj-C + Apple Intelligence Swift shim)
#   make pure       build ./wtsurface-pure (Obj-C only: proofread + summarize)
#   make clean
#
# Apple Intelligence (the `ai` subcommand) needs the FoundationModels shim, so
# the default target links Swift. The `pure` target has no Swift dependency.

SDK        := $(shell xcrun --show-sdk-path)
ARCH       := $(shell uname -m)
TARGET     := $(ARCH)-apple-macos26.0
FRAMEWORKS := -framework Foundation -framework AppKit

.PHONY: all pure clean
all: wtsurface

# 1) Swift shim -> object file + generated Obj-C bridging header.
wtkit-Swift.h AIShim.o: AIShim.swift
	swiftc -c $< -module-name wtkit -parse-as-library \
	    -emit-objc-header -emit-objc-header-path wtkit-Swift.h \
	    -sdk "$(SDK)" -target "$(TARGET)" -o AIShim.o

# 2) Obj-C tool, compiled against the generated header.
wtsurface.o: wtsurface.m wtkit-Swift.h
	clang -c $< -o $@ -fobjc-arc -fmodules -DWT_HAVE_AI \
	    -isysroot "$(SDK)" -target "$(TARGET)" -I.

# 3) Link with swiftc so the Swift runtime + FoundationModels resolve.
wtsurface: AIShim.o wtsurface.o
	swiftc $^ -o $@ -sdk "$(SDK)" -target "$(TARGET)" \
	    $(FRAMEWORKS) -framework FoundationModels

# Pure Obj-C build — no Apple Intelligence, no Swift toolchain needed.
pure: wtsurface.m
	clang -fobjc-arc -fmodules $(FRAMEWORKS) $< -o wtsurface-pure -isysroot "$(SDK)"

clean:
	rm -f wtsurface wtsurface-pure *.o wtkit-Swift.h
