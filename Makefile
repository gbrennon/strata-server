SHELL := /usr/bin/env bash

INVENTORY ?= inventory.ini
LIMIT ?=
MODEL ?= iq3_s
SSH_TARGET ?=
REMOTE_PORT ?= 8082

.PHONY: plan deploy verify benchmark restore test require-target

require-target:
	@test -n "$(INVENTORY)" || (echo 'INVENTORY is required' >&2; exit 2)
	@test -n "$(LIMIT)" || (echo 'LIMIT is required' >&2; exit 2)

plan: require-target
	INVENTORY="$(INVENTORY)" LIMIT="$(LIMIT)" MODEL="$(MODEL)" ./scripts/deploy.sh --check

deploy: require-target
	INVENTORY="$(INVENTORY)" LIMIT="$(LIMIT)" MODEL="$(MODEL)" ./scripts/deploy.sh

verify:
	REMOTE_TARGET="$(SSH_TARGET)" STRATA_PORT="$(REMOTE_PORT)" MODEL="$(MODEL)" \
	  ./scripts/verify.sh

benchmark:
	./scripts/benchmark.py --base-url http://127.0.0.1:8082 --model "$(MODEL)" \
	  --ssh-target "$(SSH_TARGET)" --remote-port "$(REMOTE_PORT)"

restore: require-target
	INVENTORY="$(INVENTORY)" LIMIT="$(LIMIT)" ./scripts/restore.sh

test:
	for test_file in tests/test_*.sh; do bash "$$test_file"; done
