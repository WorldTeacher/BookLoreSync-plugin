SHELL := /usr/bin/env bash

.PHONY: test documentation version

test:
	./run_tests.sh

documentation:
	cd docs && zola serve

version:
	uv run ~/.scripts/next_version.py