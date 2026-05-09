SHELL := /usr/bin/env bash

.DEFAULT_GOAL := help

.PHONY: help test documentation version docs translate generate_version

help: ## Show available commands
	@echo "Available commands:"
	@awk 'BEGIN {FS = ":.*## "} /^[a-zA-Z_-]+:.*## / {printf "  %-14s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

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
