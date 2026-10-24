SHELL := /bin/bash

SCRIPTS := install.sh uninstall.sh verify.sh \
           bin/nvidia-compute shell/aliases.sh \
           helper/nvidia-compute-helper

.PHONY: test check install uninstall

test:
	@for f in $(SCRIPTS); do \
		echo "bash -n $$f"; \
		bash -n "$$f"; \
	done
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck -x $(SCRIPTS); \
	else \
		echo "shellcheck not installed; skipping"; \
	fi

check:
	./install.sh --check

install:
	sudo ./install.sh

uninstall:
	sudo ./uninstall.sh
