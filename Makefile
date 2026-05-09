SHELL := /usr/bin/env bash

.DEFAULT_GOAL := help

.PHONY: help test documentation version docs translate generate_version changelog-pregen

help:
	@echo "Available targets:"
	@awk 'BEGIN {FS = ":.*## "} /^[a-zA-Z_-]+:.*## / {print $$1 "\t" $$2}' $(MAKEFILE_LIST) \
		| sort -k1,1 \
		| awk -F '\t' '{printf "  %-14s %s\n", $$1, $$2}'
test: ## Run test suite
	./run_tests.sh

documentation: ## Serve docs site locally
	cd docs && zola serve

version: ## Compute next version
	uv run ~/.scripts/next_version.py

translate: ## Update translation files
	sh ./scripts/update-translation.sh bookloresync.koplugin

generate_version: ## Generate version file
	sh ./scripts/generate-version.sh

changelog-pregen: ## Pre-generate next changelog file
	bash ./scripts/changelog-pregen.sh
