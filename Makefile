SHELL := /usr/bin/env bash
SCRIPTS := bin/usbless-dualboot $(wildcard lib/*.sh) $(wildcard examples/reference-omarchy/*.sh) $(wildcard tests/*.sh)

.PHONY: help lint test probe plan clean

help:
	@echo "make lint    - bash -n every script"
	@echo "make test    - run the smoke test (requires probe to work on this host)"
	@echo "make probe   - run 'probe' on this host"
	@echo "make plan    - show the plan for a Windows ISO (set ISO=...)"
	@echo "make clean   - remove transient files"

lint:
	@bash -n $(SCRIPTS) && echo "lint OK"

test: lint
	@bash tests/smoke.sh

probe:
	@./bin/usbless-dualboot probe

plan:
	@test -n "$(ISO)" || { echo "usage: make plan ISO=/path/to/Win11.iso"; exit 1; }
	@./bin/usbless-dualboot plan --iso "$(ISO)"

clean:
	@rm -f *.log
