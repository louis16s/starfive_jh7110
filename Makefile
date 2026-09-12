SHELL := /bin/bash

BOARD ?= visionfive2
BUILD_TYPE ?= release

# The board profile is the single source of truth for which U-Boot tree is
# built.  Reading it here as well as in build-uboot.sh keeps `make fetch` from
# silently downloading a tree that the build then refuses to use.
UBOOT_SOURCE := $(shell bash -c 'source "board/$(BOARD)/profile.conf" >/dev/null 2>&1; printf %s "$$UBOOT_SOURCE"')

.PHONY: check profile verify-sources host-check fetch kernel uboot opensbi gpu-package rootfs install-kernel image compress manifest

# Two of the tests import the Python the image ships, and a stock CPython writes
# bytecode beside the source it imports.  The overlay is what the image is built
# from, so the whole suite runs without writing any; macOS hides this by keeping
# bytecode in a per-user cache, which is why it only shows up on the machine
# that builds the image.  tests/test-shipped-python.py is what catches a tree
# that carries bytecode anyway.
check: export PYTHONDONTWRITEBYTECODE = 1

check:
	bash tests/test-hostname.sh
	bash tests/test-account.sh
	bash tests/test-diagnostics.sh
	bash tests/test-greeter.sh
	bash tests/test-kernel-merge.sh
	bash tests/test-prepare.sh
	python3 tests/test-oobe-backend.py
	python3 tests/test-oobe-wizard.py
	python3 tests/test-gpu-runtime.py
	python3 tests/test-build-reproducibility.py
	python3 tests/test-boot-config.py
	python3 tests/test-board-info.py
	python3 tests/test-release-assets.py
	python3 tests/test-shipped-python.py
	./scripts/validate-profile.sh "$(BOARD)"
	./scripts/host-check.sh
	./scripts/verify-source-lock.sh

profile:
	./scripts/validate-profile.sh "$(BOARD)"

verify-sources:
	./scripts/verify-source-lock.sh

host-check:
	./scripts/host-check.sh

fetch:
	@test -n "$(UBOOT_SOURCE)" \
	    || { echo "unknown or incomplete board profile: $(BOARD)" >&2; exit 1; }
	./scripts/fetch-sources.sh starfive_linux_6_12 "$(UBOOT_SOURCE)" starfive_opensbi

kernel:
	./scripts/build-kernel.sh "$(BOARD)"

uboot:
	./scripts/build-uboot.sh "$(BOARD)"

opensbi:
	./scripts/build-opensbi.sh "$(BOARD)"

gpu-package:
	./scripts/build-gpu-package.sh "$(BOARD)"

rootfs:
	./scripts/build-rootfs.sh "$(BOARD)"

install-kernel:
	./scripts/install-kernel-into-rootfs.sh "$(BOARD)"

image:
	./scripts/build-image.sh "$(BOARD)"

compress:
	./scripts/compress-image.sh "$(BOARD)"

manifest:
	./scripts/generate-manifest.sh "$(BOARD)"
