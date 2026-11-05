SHELL := /usr/bin/env bash
SCRIPTS := $(wildcard bin/*) $(wildcard lib/*.sh) $(wildcard examples/reference-omarchy/*.sh) $(wildcard tests/*.sh) $(wildcard tests/fixtures/*)

.PHONY: help lint shellcheck test test-ui ui probe plan clean

help:
	@echo "make lint        - bash -n every script"
	@echo "make shellcheck  - advisory ShellCheck pass (if installed)"
	@echo "make test        - smoke and isolated regression checks (no root or disk writes)"
	@echo "make ui          - build the native Qt Quick app"
	@echo "make test-ui     - compile and test the real interface offscreen"
	@echo "make probe       - run 'probe' on this host"
	@echo "make plan        - show the plan for a Windows ISO (set ISO=...)"
	@echo "make clean       - remove transient files"

lint:
	@for script in $(SCRIPTS); do bash -n "$$script" || exit; done
	@echo "lint OK"

shellcheck:
	@command -v shellcheck >/dev/null || { echo "shellcheck not installed"; exit 0; }
	@shellcheck $(SCRIPTS) || true

test: lint
	@bash tests/smoke.sh
	@bash tests/regression.sh
	@bash tests/carrier.sh
	@bash tests/ui-helper.sh

ui:
	@./bin/build-ui

test-ui:
	@./bin/test-ui

probe:
	@./bin/usbless-dualboot probe

plan:
	@test -n "$(ISO)" || { echo "usage: make plan ISO=/path/to/Win11.iso"; exit 1; }
	@./bin/usbless-dualboot plan --iso "$(ISO)"

clean:
	@rm -f *.log
