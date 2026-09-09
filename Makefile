SHELL := /bin/bash

BOARD ?= visionfive2
BUILD_TYPE ?= release

.PHONY: check profile verify-sources host-check image

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

image:
	@echo "image build is scheduled for Phase 5; run 'make BOARD=$(BOARD) check' for Phase 2 validation" >&2
	@exit 2
