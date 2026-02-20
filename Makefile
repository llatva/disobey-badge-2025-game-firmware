.PHONY: all submodules micro_init build_firmware clean_frozen_py rebuild_mpy_cross bump_version release
SHELL := /bin/bash

# Detect Python command
PYTHON := $(shell command -v python3 2>/dev/null || command -v python 2>/dev/null)
ifeq ($(PYTHON),)
$(error Python is not installed. Please install Python 3)
endif

# Docker CLI defaults (no Docker Desktop required)
DOCKER ?= docker
DOCKER_IMAGE ?= disobey-badge-firmware:cli
DOCKERFILE_CLI ?= Dockerfile.rootless

# Default value for FW_TYPE
FW_TYPE ?= normal
# Check that FW_TYPE is either normal or minimal
ifneq ($(FW_TYPE),normal)
ifneq ($(FW_TYPE),minimal)
$(error FW_TYPE must be either 'normal' or 'minimal')
endif
endif

all: build_firmware

help:
	@echo "Available make targets:"
	@echo "  build_firmware            Build firmware (FW_TYPE=normal|minimal)"
	@echo "  build_and_deploy          Build firmware and flash to device"
	@echo "  deploy                    Flash firmware to device (PORT optional)"
	@echo "  repl_with_firmware_dir    Start REPL with firmware directory mounted"
	@echo "  dev_exec                  Execute command with firmware mounted (CMD=...)"
	@echo "  docker_cli_build          Build CLI-only Docker image (no Docker Desktop)"
	@echo "  docker_cli_repl           Connect to badge via CLI-only container"
	@echo "  convert_image             Convert image to MicroPython format"
	@echo "  clear_hw_test_status      Remove .hw_tested_in_build from badge"
	@echo "  micro_init                Initialize MicroPython build environment"
	@echo "  submodules                Init git submodules"
	@echo "  rebuild_mpy_cross          Rebuild mpy-cross"
	@echo "  clean_frozen_py            Clean frozen mpy output"
	@echo "  clean                      Clean ESP32 build output"
	@echo "  bump_version               Bump version (BUMP_TYPE=patch|minor|major)"
	@echo "  release                    Release build (requires BUMP_TYPE)"

build_firmware: dist/firmware_$(FW_TYPE).bin

build_and_deploy: build_firmware deploy

# init own submopdules before micropython init
submodules:
	git submodule update --init
	pushd micropython/ports/esp32 && \
	git submodule update --init 'user-cmodules/ucrypto' &&\
	popd
	pushd micropython && \
	git submodule update --init --depth 1 && \
	popd


set_environ.sh:
	@cp set_environ.example set_environ.sh

micro_init: micro_init.stamp
	@echo "micro_init has been completed!"

micro_init.stamp: submodules set_environ.sh
	FW_TYPE=$(FW_TYPE) source ./set_environ.sh && \
	pushd micropython && \
	ci_esp32_idf_setup && \
	ci_esp32_build_common && \
	popd
	touch micro_init.stamp

dist/firmware_$(FW_TYPE).bin: micro_init
	@echo "Building firmware type: $(FW_TYPE)"
	git rev-parse --short HEAD > frozen_fs/BUILD
	PYTHONPATH=libs/freezefs $(PYTHON) -m freezefs ./frozen_fs frozen_firmware/modules/frozen_fs.py --target "/readonly_fs"  --compress
	FW_TYPE=$(FW_TYPE) source ./set_environ.sh && \
	pushd micropython && \
	ci_esp32_idf_setup && \
	ci_esp32_build_common && \
	make ${MAKEOPTS} -C ports/esp32 && \
	popd && \
	cp micropython/ports/esp32/build-$$BOARD-$$BOARD_VARIANT/firmware.bin dist/firmware_$(FW_TYPE).bin

deploy: 
	FW_TYPE=$(FW_TYPE) source ./set_environ.sh
	@if [ -z "$$PORT" ]; then \
		esptool --chip esp32s3 -b 460800 --before=default-reset --after=hard-reset write-flash --flash-size detect 0x0 dist/firmware_$(FW_TYPE).bin; \
	else \
		esptool --chip esp32s3 -p $$PORT -b 460800 --before=default-reset --after=hard-reset write-flash --flash-size detect 0x0 dist/firmware_$(FW_TYPE).bin; \
	fi

repl_with_firmware_dir:
	@echo "Starting REPL with firmware directory mounted..."
	FW_TYPE=$(FW_TYPE) source ./set_environ.sh
	@if [ -z "$$PORT" ]; then \
		$(PYTHON) micropython/tools/mpremote/mpremote.py baud 460800 u0 mount -l firmware; \
	else \
		$(PYTHON) micropython/tools/mpremote/mpremote.py baud 460800 connect $$PORT mount -l firmware; \
	fi

dev_exec:
	@echo "Executing command with firmware directory mounted..."
	@if [ -z "$(CMD)" ]; then \
		echo "Error: No command specified"; \
		echo "Usage: make dev_exec CMD='<command>'"; \
		echo "Example: make dev_exec CMD='load_app(\"badge.option_screen\", \"OptionScreen\", with_espnow=True, with_sta=True)'"; \
		exit 1; \
	fi
	FW_TYPE=$(FW_TYPE) source ./set_environ.sh
	@if [ -z "$$PORT" ]; then \
		$(PYTHON) micropython/tools/mpremote/mpremote.py baud 460800 u0 mount -l firmware exec '$(CMD)'; \
	else \
		$(PYTHON) micropython/tools/mpremote/mpremote.py baud 460800 connect $$PORT mount -l firmware exec '$(CMD)'; \
	fi

# CLI-only Docker workflow (Linux)
docker_cli_build:
	@echo "Building CLI-only Docker image (no Docker Desktop required)..."
	@$(DOCKER) build -f $(DOCKERFILE_CLI) -t $(DOCKER_IMAGE) .

docker_cli_repl:
	@echo "Starting REPL inside CLI-only Docker container..."
	@if [ -z "$$PORT" ]; then \
		if [ -e /dev/ttyUSB0 ]; then DEVICE=/dev/ttyUSB0; \
		elif [ -e /dev/ttyACM0 ]; then DEVICE=/dev/ttyACM0; \
		else echo "Error: PORT not set and no /dev/ttyUSB0 or /dev/ttyACM0 found"; exit 1; \
		fi; \
	else DEVICE=$$PORT; fi; \
	$(DOCKER) run --rm -it \
		--device=$$DEVICE \
		--group-add dialout \
		-v "$(PWD):/workspace" \
		-w /workspace \
		$(DOCKER_IMAGE) \
		make repl_with_firmware_dir

         
clean_frozen_py:
	rm -rf ports/esp32/build-ESP32_GENERIC_S3-DEVKITW2/frozen_mpy

rebuild_mpy_cross:
	pushd micropython/mpy-cross && \
	make clean && \
	make && \
	popd

clean: 
	rm -fr micropython/ports/esp32/build-ESP32_GENERIC_S3-DEVKITW2

# Version bumping (BUMP_TYPE can be: major, minor, patch)
BUMP_TYPE ?=
bump_version:
	@if [ -z "$(BUMP_TYPE)" ]; then \
		echo "Error: BUMP_TYPE not specified"; \
		echo ""; \
		echo "Usage: make bump_version BUMP_TYPE=<level>"; \
		echo ""; \
		echo "Bump levels:"; \
		echo "  patch  - Bug fixes (e.g., v0.0.1 → v0.0.2)"; \
		echo "  minor  - New features (e.g., v0.1.0 → v0.2.0)"; \
		echo "  major  - Breaking changes (e.g., v1.0.0 → v2.0.0)"; \
		echo ""; \
		echo "Examples:"; \
		echo "  make bump_version BUMP_TYPE=patch"; \
		echo "  make bump_version BUMP_TYPE=minor"; \
		echo "  make bump_version BUMP_TYPE=major"; \
		echo ""; \
		exit 1; \
	fi
	@echo "Bumping $(BUMP_TYPE) version..."
	@./scripts/bump_version.sh $(BUMP_TYPE)
	@NEW_VERSION=$$(cat frozen_fs/VERSION) && \
	echo "Committing version $$NEW_VERSION..." && \
	git add frozen_fs/VERSION && \
	git commit -m "Release $$NEW_VERSION" && \
	echo "Creating tag: $$NEW_VERSION" && \
	git tag -a "$$NEW_VERSION" -m "Release $$NEW_VERSION" && \
	echo "✅ Version bumped and tagged: $$NEW_VERSION"

# Release process: bump version, commit, tag, and build firmware
# Usage: make release BUMP_TYPE=<level>
# Note: Tags are LOCAL until you push. Use 'git push origin main --tags' to publish.
release: bump_version
	@echo "=== Starting Release Build ==="
	@NEW_VERSION=$$(cat frozen_fs/VERSION) && \
	echo "Building firmware for $$NEW_VERSION..." && \
	$(MAKE) clean && \
	$(MAKE) build_firmware FW_TYPE=normal && \
	echo "" && \
	echo "=== Release Complete ===" && \
	echo "Version: $$NEW_VERSION" && \
	echo "Artifacts:" && \
	ls -lh dist/ && \
	echo "" && \
	echo "To publish this release to GitHub:" && \
	echo "  git push origin main --tags" && \
	echo "" && \
	echo "To undo this release (if testing):" && \
	echo "  git tag -d $$NEW_VERSION" && \
	echo "  git reset --hard HEAD~1"

clear_hw_test_status:
	@echo "Removing .hw_tested_in_build from badge..."
	@if [ -z "$$PORT" ]; then \
		$(PYTHON) micropython/tools/mpremote/mpremote.py baud 460800 u0 rm :/.hw_tested_in_build; \
	else \
		$(PYTHON) micropython/tools/mpremote/mpremote.py baud 460800 connect $$PORT rm :/.hw_tested_in_build; \
	fi

# Image conversion to MicroPython format
# Usage: make convert_image SOURCE_IMAGE=path/to/image.png TARGET_PY=path/to/output.py [WIDTH=320] [HEIGHT=170] [DITHER=Burke] [FORMAT=RGB565_I]
convert_image:
	@if [ -z "$(SOURCE_IMAGE)" ]; then \
		echo "Error: SOURCE_IMAGE not specified"; \
		echo ""; \
		echo "Usage: make convert_image SOURCE_IMAGE=<path> TARGET_PY=<path> [WIDTH=320] [HEIGHT=170] [DITHER=Burke] [FORMAT=RGB565_I]"; \
		echo ""; \
		echo "Parameters:"; \
		echo "  SOURCE_IMAGE - Path to source image (PNG, JPG, BMP, etc.)"; \
		echo "  TARGET_PY    - Path to output Python file"; \
		echo "  WIDTH        - Target width in pixels (default: 320)"; \
		echo "  HEIGHT       - Target height in pixels (default: 170)"; \
		echo "  DITHER       - Dithering algorithm: Atkinson, Burke, Sierra, FS, None (default: Burke)"; \
		echo "  FORMAT       - Color format: RGB565_I (default), RGB565, or GS8"; \
		echo ""; \
		echo "Examples:"; \
		echo "  make convert_image SOURCE_IMAGE=boot.png TARGET_PY=frozen_firmware/modules/images/boot.py"; \
		echo "  make convert_image SOURCE_IMAGE=boot.png TARGET_PY=frozen_firmware/modules/images/boot.py DITHER=Atkinson"; \
		echo "  make convert_image SOURCE_IMAGE=logo.jpg TARGET_PY=firmware/logo.py WIDTH=128 HEIGHT=64"; \
		echo "  make convert_image SOURCE_IMAGE=icon.png TARGET_PY=firmware/icon.py FORMAT=RGB565"; \
		echo ""; \
		echo "See docs/image_conversion.md for detailed information."; \
		exit 1; \
	fi
	@if [ -z "$(TARGET_PY)" ]; then \
		echo "Error: TARGET_PY not specified"; \
		echo "Usage: make convert_image SOURCE_IMAGE=<path> TARGET_PY=<path>"; \
		exit 1; \
	fi
	@if [ ! -f "$(SOURCE_IMAGE)" ]; then \
		echo "Error: Source image '$(SOURCE_IMAGE)' not found"; \
		exit 1; \
	fi
	@echo "Converting image: $(SOURCE_IMAGE) → $(TARGET_PY)"
	@WIDTH=$${WIDTH:-320}; \
	HEIGHT=$${HEIGHT:-170}; \
	DITHER=$${DITHER:-Burke}; \
	FORMAT=$${FORMAT:-RGB565_I}; \
	TEMP_PPM=$$(mktemp --suffix=.ppm); \
	echo "  Dimensions: $${WIDTH}x$${HEIGHT}"; \
	echo "  Format: $${FORMAT}"; \
	echo "  Dithering: $${DITHER}"; \
	if command -v convert >/dev/null 2>&1; then \
		echo "  Converting to PPM format..."; \
		convert "$(SOURCE_IMAGE)" -resize "$${WIDTH}x$${HEIGHT}!" "$$TEMP_PPM" || { echo "Error: ImageMagick conversion failed"; rm -f "$$TEMP_PPM"; exit 1; }; \
	else \
		echo "Error: ImageMagick 'convert' command not found"; \
		echo "Please install ImageMagick: apt-get install imagemagick"; \
		exit 1; \
	fi; \
	echo "  Converting to MicroPython format..."; \
	if [ "$$FORMAT" = "RGB565_I" ]; then \
		$(PYTHON) libs/micropython-micro-gui/utils/img_cvt.py \
			"$$TEMP_PPM" \
			"$(TARGET_PY)" \
			--rgb565 \
			--invert-rgb565 \
			--dither "$$DITHER" || { echo "Error: img_cvt.py conversion failed"; rm -f "$$TEMP_PPM"; exit 1; }; \
	elif [ "$$FORMAT" = "RGB565" ]; then \
		$(PYTHON) libs/micropython-micro-gui/utils/img_cvt.py \
			"$$TEMP_PPM" \
			"$(TARGET_PY)" \
			--rgb565 \
			--dither "$$DITHER" || { echo "Error: img_cvt.py conversion failed"; rm -f "$$TEMP_PPM"; exit 1; }; \
	else \
		$(PYTHON) libs/micropython-micro-gui/utils/img_cvt.py \
			"$$TEMP_PPM" \
			"$(TARGET_PY)" \
			--dither "$$DITHER" || { echo "Error: img_cvt.py conversion failed"; rm -f "$$TEMP_PPM"; exit 1; }; \
	fi; \
	rm -f "$$TEMP_PPM"; \
	echo "✅ Image converted successfully: $(TARGET_PY)"