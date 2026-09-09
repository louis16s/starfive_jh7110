SHELL := /bin/bash

BOARD ?= visionfive2
BUILD_TYPE ?= release

.PHONY: check profile verify-sources host-check fetch kernel uboot opensbi image

check:
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

image:
	@echo "image build is scheduled for Phase 5; run 'make BOARD=$(BOARD) check' for Phase 2 validation" >&2
	@exit 2
