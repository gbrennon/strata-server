SHELL := /usr/bin/env bash

INVENTORY ?= inventory.ini
LIMIT ?=
MODEL ?= iq3_s

.PHONY: plan deploy verify benchmark restore test

require-target:
	@test -n "$(INVENTORY)" || (echo 'INVENTORY is required' >&2; exit 2)
	@test -n "$(LIMIT)" || (echo 'LIMIT is required' >&2; exit 2)

plan: require-target
	INVENTORY="$(INVENTORY)" LIMIT="$(LIMIT)" MODEL="$(MODEL)" ./scripts/deploy.sh --check

deploy: require-target
	INVENTORY="$(INVENTORY)" LIMIT="$(LIMIT)" MODEL="$(MODEL)" ./scripts/deploy.sh

verify:
	./scripts/verify.sh

benchmark:
	./scripts/benchmark.py --base-url http://127.0.0.1:8082 --model "$(MODEL)"

restore:
	INVENTORY="$(INVENTORY)" LIMIT="$(LIMIT)" ./scripts/restore.sh

test:
	for test_file in tests/test_*.sh; do bash "$$test_file"; done
