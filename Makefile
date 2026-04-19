SHELL := /usr/bin/env bash

.PHONY: test documentation

test:
	./run_tests.sh

documentation:
	cd docs && zola serve