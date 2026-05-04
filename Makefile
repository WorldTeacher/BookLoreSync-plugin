SHELL := /usr/bin/env bash

.DEFAULT_GOAL := help

.PHONY: help test documentation version

help: ## Show available commands
	@echo "Available commands:"
	@awk 'BEGIN {FS = ":.*## "} /^[a-zA-Z_-]+:.*## / {printf "  %-14s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

test: ## Run test suite
	./run_tests.sh

documentation: ## Serve docs site locally
	cd docs && zola serve

version: ## Compute next version
	uv run ~/.scripts/next_version.py
