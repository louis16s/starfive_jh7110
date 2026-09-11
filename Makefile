SHELL := /bin/bash

BOARD ?= visionfive2
BUILD_TYPE ?= release

.PHONY: check profile verify-sources host-check fetch kernel uboot opensbi gpu-package rootfs install-kernel image compress manifest

check:
	bash tests/test-kernel-merge.sh
	python3 tests/test-boot-config.py
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
	./scripts/fetch-sources.sh starfive_linux_6_12 $(if $(filter visionfive2,$(BOARD)),starfive_uboot,uboot_upstream) starfive_opensbi

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
