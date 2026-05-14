SHELL := /usr/bin/env bash

.DEFAULT_GOAL := help

.PHONY: help test documentation version docs translate generate_version changelog-pregen plugin

help:
	@echo "Available targets:"
	@awk 'BEGIN {FS = ":.*## "} /^[a-zA-Z_-]+:.*## / {print $$1 "\t" $$2}' $(MAKEFILE_LIST) \
		| sort -k1,1 \
		| awk -F '\t' '{printf "  %-14s %s\n", $$1, $$2}'
test: ## Run test suite
	bash ./scripts/run_tests.sh

documentation: ## Serve docs site locally
	cd docs && zola serve
docs: documentation ## Alias for documentation
	
version: ## Compute next version
	uv run ~/.scripts/next_version.py

translate: ## Update translation files
	sh ./scripts/update-translation.sh bookloresync.koplugin

generate_version: ## Generate version file
	sh ./scripts/generate-version.sh

changelog-pregen: ## Pre-generate changelog (CHG_ARGS=--docs for docs changelog)
	@if echo "$(CHG_ARGS)" | grep -q -- '--docs'; then \
		current_branch=$$(git rev-parse --abbrev-ref HEAD 2>/dev/null); \
		if [ "$$current_branch" != "develop" ]; then \
			echo "ERROR: --docs can only be used on the 'develop' branch (current: $$current_branch)" >&2; \
			exit 1; \
		fi; \
	fi
	bash ./scripts/changelog-pregen.sh $(CHG_ARGS)

plugin: ## Build plugin archive (strips comments, matches CI pipeline)
	@echo "=== Copying plugin directory ==="
	@rm -rf /tmp/bookloresync-build
	@cp -a bookloresync.koplugin /tmp/bookloresync-build
	@echo "=== Generating version information ==="
	@bash scripts/generate-version.sh
	@echo "=== Compiling gettext translations ==="
	@find /tmp/bookloresync-build/locale -name "*.po" | while read po; do \
		mo="$${po%.po}.mo"; \
		echo "  Compiling $$po -> $$mo"; \
		msgfmt "$$po" -o "$$mo" 2>/dev/null || true; \
	done
	@echo "=== Stripping comments from Lua sources ==="
	@bash scripts/strip-lua-comments.sh --dir /tmp/bookloresync-build
	@echo "=== Creating plugin archive ==="
	@cd /tmp && zip -r "$(CURDIR)/bookloresync.koplugin.zip" bookloresync-build/ -x "*.git*" "*.zip" "bookloresync-build/logs/*" "bookloresync-build/hardcover.token" "*.po" "*.pot" "*.po~"
	@echo "=== Cleaning up ==="
	@rm -rf /tmp/bookloresync-build
	@echo "=== Done: bookloresync.koplugin.zip ==="
	@ls -lah bookloresync.koplugin.zip