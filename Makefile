APP       := Marky
VERSION   := 1.0.0
BUILD     := build
BUNDLE    := $(BUILD)/$(APP).app
BINARY    := $(BUNDLE)/Contents/MacOS/$(APP)
PREFIX    ?= /Applications

ARCH      ?= arm64
MIN_MACOS := 27.0
TARGET    := $(ARCH)-apple-macos$(MIN_MACOS)

CORE_SRC  := $(wildcard src/core/*.swift)
APP_SRC   := $(wildcard src/app/*.swift)
MATH_SRC  := $(wildcard vendor/iosMath/lib/*.m vendor/iosMath/render/*.m vendor/iosMath/render/internal/*.m)
SHIM_SRC  := $(wildcard src/shim/*.m)
VENDOR_OBJ := $(BUILD)/obj/md4c/md4c.o $(MATH_SRC:vendor/%.m=$(BUILD)/obj/%.o) $(SHIM_SRC:src/%.m=$(BUILD)/obj/%.o)
MATH_INC  := -Ivendor/iosMath -Ivendor/iosMath/lib -Ivendor/iosMath/lib/internal -Ivendor/iosMath/render \
             -Ivendor/iosMath/render/internal

# Size first: -Os / -Osize, whole-module and link-time optimisation, dead code stripped.
# `make SANITIZE=address BUILD=build-asan` (or thread) builds a checked copy for testing instead.
ifeq ($(SANITIZE),)
CFLAGS    := -target $(TARGET) -Os -flto -fvisibility=hidden -MMD -MP
SWIFTFLAGS := -target $(TARGET) -Osize -wmo -lto=llvm-full
STRIP     := strip -x
else ifeq ($(SANITIZE),thread)
CFLAGS    := -target $(TARGET) -O1 -g -fsanitize=thread -MMD -MP
SWIFTFLAGS := -target $(TARGET) -Onone -g -sanitize=thread
STRIP     := true
else
CFLAGS    := -target $(TARGET) -O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer -MMD -MP
SWIFTFLAGS := -target $(TARGET) -Onone -g -sanitize=address,undefined
STRIP     := true
endif
CFLAGS    += -Wall -Wextra
OBJCFLAGS := -fobjc-arc -fmodules -DNS_BLOCK_ASSERTIONS=1 $(MATH_INC)
SWIFTFLAGS += -I vendor -I src/shim $(addprefix -Xcc ,$(MATH_INC))
LIBS      := -framework AppKit -framework CoreText -framework QuartzCore

FONTS     := $(wildcard resources/fonts/*.otf resources/fonts/*.plist resources/fonts/*.txt)
ICON      := resources/$(APP).icns
RESOURCES := $(BUNDLE)/Contents/Info.plist $(FONTS:resources/fonts/%=$(BUNDLE)/Contents/Resources/fonts/%) \
             $(if $(wildcard $(ICON)),$(BUNDLE)/Contents/Resources/$(APP).icns)

.PHONY: all app run test selftest install uninstall snapshot icon clean

all: app

app: $(BUILD)/.signed

# Ad-hoc sign only when something in the bundle changed.
$(BUILD)/.signed: $(BINARY) $(RESOURCES)
	@codesign --force --sign - $(BUNDLE)
	@touch $@
	@echo "Built $(BUNDLE) ($$(du -sh $(BUNDLE) | cut -f1))"

$(BINARY): $(CORE_SRC) $(APP_SRC) $(VENDOR_OBJ) vendor/module.modulemap src/shim/module.modulemap
	@mkdir -p $(@D)
	swiftc $(SWIFTFLAGS) -module-name $(APP) $(CORE_SRC) $(APP_SRC) $(VENDOR_OBJ) $(LIBS) \
	    -Xlinker -dead_strip -o $@
	@$(STRIP) $@

$(BUNDLE)/Contents/Info.plist: resources/Info.plist Makefile
	@mkdir -p $(@D)
	@sed 's/__VERSION__/$(VERSION)/g' $< > $@

$(BUNDLE)/Contents/Resources/fonts/%: resources/fonts/%
	@mkdir -p $(@D)
	@cp $< $@

$(BUNDLE)/Contents/Resources/$(APP).icns: $(ICON)
	@mkdir -p $(@D)
	@cp $< $@

$(BUILD)/obj/md4c/md4c.o: vendor/md4c/md4c.c
	@mkdir -p $(@D)
	clang $(CFLAGS) -c $< -o $@

$(BUILD)/obj/%.o: vendor/%.m
	@mkdir -p $(@D)
	clang $(CFLAGS) $(OBJCFLAGS) -c $< -o $@

# Catches the typesetter's exceptions; -fobjc-arc-exceptions releases objects on the way out.
$(BUILD)/obj/shim/%.o: src/shim/%.m src/shim/%.h
	@mkdir -p $(@D)
	clang $(CFLAGS) $(OBJCFLAGS) -fobjc-arc-exceptions -c $< -o $@

# Unit tests for the core, built with AddressSanitizer and UBSan.
test: $(BUILD)/tests
	@$(BUILD)/tests

# The app's own end-to-end checks (open, reload, zoom, close), run off screen.
selftest: app
	@mkdir -p $(BUILD)/selftest
	@$(BINARY) --selftest $(BUILD)/selftest

$(BUILD)/tests: tests/main.swift $(CORE_SRC) vendor/md4c/md4c.c vendor/module.modulemap
	@mkdir -p $(BUILD)/test-obj
	clang -target $(TARGET) -O1 -g -fsanitize=address,undefined -c vendor/md4c/md4c.c -o $(BUILD)/test-obj/md4c.o
	swiftc -target $(TARGET) -Onone -g -sanitize=address,undefined -I vendor -module-name MarkyTests \
	    tests/main.swift $(CORE_SRC) $(BUILD)/test-obj/md4c.o -o $@

# Waits for a running copy to quit first: `open` fails while it is still exiting.
STOP      := pkill -x $(APP) && while pgrep -x $(APP) >/dev/null; do sleep 0.1; done; true

run: app
	@$(STOP)
	@open $(BUNDLE)

install: app
	@$(STOP)
	@rm -rf "$(PREFIX)/$(APP).app"
	@cp -R $(BUNDLE) "$(PREFIX)/"
	@echo "Installed to $(PREFIX)/$(APP).app"

uninstall:
	@$(STOP)
	@rm -rf "$(PREFIX)/$(APP).app"

# Renders docs/sample.md in light and dark mode for the README.
snapshot: app
	@$(BINARY) --snapshot docs docs/sample.md "" 860 1180
	@echo "Wrote docs/reader-light.png and docs/reader-dark.png"

icon: tools/icon.swift
	@rm -rf $(BUILD)/icon.iconset && mkdir -p $(BUILD)/icon.iconset
	swiftc -target $(TARGET) -O tools/icon.swift -o $(BUILD)/icon
	@$(BUILD)/icon $(BUILD)/icon.iconset docs/icon.png
	@iconutil -c icns $(BUILD)/icon.iconset -o $(ICON)
	@echo "Wrote $(ICON) and docs/icon.png"

clean:
	rm -rf $(BUILD)

-include $(VENDOR_OBJ:.o=.d)
