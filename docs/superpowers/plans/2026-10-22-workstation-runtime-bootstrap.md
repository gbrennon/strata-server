# Workstation Runtime Bootstrap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add one workstation command that switches the remote runtime, manages
its SSH tunnel, and updates Pi's active custom provider.

**Architecture:** `scripts/bootstrap-runtime.sh` orchestrates the workstation
workflow. It invokes the installed remote `toggle-ai-runtime` command, owns one
local tunnel on port `18080`, verifies the tunneled API, and atomically updates
Pi's `models.json`.

**Tech Stack:** Bash, OpenSSH, curl, Python 3, Pi `models.json`, and systemd.

## Global Constraints

- Use provider names `gbrennon-strata` and `gbrennon-llama` exactly.
- Default to `gbrennon-local-ai@192.168.0.2`.
- Default to local tunnel port `18080`.
- Default to `~/.pi/agent/models.json`.
- Use `openai-completions` and API key `local`.
- Preserve unrelated Pi configuration.
- Create a timestamped backup before changing Pi configuration.
- Verify health, models, and chat before changing Pi configuration.
- Run tests and runtime commands sequentially.

---

## Task 1: Define the command contract with failing tests

**Files:**

- Create: `tests/test_bootstrap_runtime.sh`
- Test: `tests/test_bootstrap_runtime.sh`

**Interfaces:**

- Consumes: `scripts/bootstrap-runtime.sh strata|llama|status`.
- Produces: fake SSH, curl, and tunnel contracts for implementation.

- [ ] **Step 1: Write the failing test.**

Create fake commands in a temporary directory. Test that `strata` sends
`sudo toggle-ai-runtime strata`, forwards local `18080` to remote `8082`, reads
model ID `qwen3.8-flash-next-iq3_s`, and writes `gbrennon-strata`. Test the
inverse mapping for `llama`. Preserve an unrelated provider, create a backup,
and verify an API failure leaves the original JSON unchanged.

- [ ] **Step 2: Run the focused test.**

```bash
bash tests/test_bootstrap_runtime.sh
```

Expected: failure because `scripts/bootstrap-runtime.sh` does not exist.

- [ ] **Step 3: Commit the failing test.**

```bash
git add tests/test_bootstrap_runtime.sh
git commit -m "test: define workstation runtime bootstrap"
```

---

## Task 2: Implement remote switching and tunnel lifecycle

**Files:**

- Create: `scripts/bootstrap-runtime.sh`
- Test: `tests/test_bootstrap_runtime.sh`
- [ ] **Step 1: Add runtime configuration.**

Use these defaults and allow environment overrides:

```bash
ssh_target="${SSH_TARGET:-gbrennon-local-ai@192.168.0.2}"
models_file="${PI_MODELS_FILE:-$HOME/.pi/agent/models.json}"
state_dir="${STATE_DIR:-$HOME/.local/state/strata-server-toggle}"
local_api_port="${LOCAL_API_PORT:-18080}"
ssh_bin="${SSH_BIN:-ssh}"
curl_bin="${CURL_BIN:-curl}"
```

Map Strata to remote port `8082` and `gbrennon-strata`. Map llama.cpp to
remote port `8080` and `gbrennon-llama`.

- [ ] **Step 2: Add tunnel cleanup and creation.**

Store the tunnel PID in `${state_dir}/tunnel.pid`. Stop only the tracked
process before starting a replacement. Create the tunnel with:

```bash
ssh -fNT -o ExitOnForwardFailure=yes \
  -L "${local_api_port}:127.0.0.1:${remote_port}" "$ssh_target"
```

Wait for the local health endpoint before proceeding.

- [ ] **Step 3: Add remote switching and API checks.**

Invoke:

```bash
ssh "$ssh_target" "sudo toggle-ai-runtime ${runtime}"
```

Require successful responses from `/health`, `/v1/models`, and
`/v1/chat/completions`. Use the model ID from `/v1/models` in a short chat
request with `max_tokens` set to `8`. Do not edit Pi configuration before all
checks succeed.

- [ ] **Step 4: Run the focused test and commit.**

```bash
bash tests/test_bootstrap_runtime.sh
git add scripts/bootstrap-runtime.sh tests/test_bootstrap_runtime.sh
git commit -m "feat: bootstrap remote runtime from workstation"
```

Expected: both runtime mappings, tunnel cleanup, API checks, and failure
handling pass before the commit.

---

## Task 3: Add atomic Pi configuration updates

**Files:**

- Modify: `scripts/bootstrap-runtime.sh`
- Test: `tests/test_bootstrap_runtime.sh`

**Interfaces:**

- Consumes: verified provider name and model ID from Task 2.
- Produces: valid Pi configuration with one active custom provider.

- [ ] **Step 1: Extend configuration assertions.**

Assert that an unrelated provider remains unchanged, the selected provider has
base URL `http://127.0.0.1:18080/v1`, API `openai-completions`, key `local`,
and the discovered model ID. Assert that the legacy `evo-x2-llama` and
`local-llama-cpp` providers are absent and a backup contains the original JSON.

- [ ] **Step 2: Add the embedded Python transformation.**

Pass the provider, model ID, target path, and backup path through environment
variables. Parse the existing JSON, copy it to the backup, remove only
`evo-x2-llama` and `local-llama-cpp`, add or replace the selected provider, write a
mode-`0600` temporary file beside the target, and replace the target with
`os.replace`. Preserve unrelated keys and fail on invalid JSON.

- [ ] **Step 3: Run the focused test.**

```bash
bash tests/test_bootstrap_runtime.sh
```

Expected: configuration, backup, preservation, and failure tests pass.

- [ ] **Step 4: Commit the update.**

```bash
git add scripts/bootstrap-runtime.sh tests/test_bootstrap_runtime.sh
git commit -m "feat: update active Pi runtime provider"
```

---

## Task 4: Add status output and documentation

**Files:**

- Modify: `scripts/bootstrap-runtime.sh`
- Modify: `README.md`
- Modify: `docs/operations.md`
- Test: `tests/test_documented_commands.sh`

**Interfaces:**

- Consumes: tunnel state, local API state, and Pi configuration.
- Produces: status output and documented workstation commands.

- [ ] **Step 1: Test status behavior.**

Assert that `status` reports the remote target, tracked tunnel state, local API
availability, and active provider without changing `models.json`.

- [ ] **Step 2: Implement status output.**

Read the tracked PID, query local health when the tunnel exists, and report the
custom provider found in `models.json`. Do not invoke a remote switch.

- [ ] **Step 3: Document the commands.**

Add this usage to the README and operations guide:

```bash
./scripts/bootstrap-runtime.sh strata
./scripts/bootstrap-runtime.sh llama
./scripts/bootstrap-runtime.sh status
```

Document that an existing Pi session may need `/reload` and `/model`.

- [ ] **Step 4: Run focused tests and commit.**

```bash
bash tests/test_bootstrap_runtime.sh
bash tests/test_documented_commands.sh
git add scripts/bootstrap-runtime.sh README.md docs/operations.md \
  tests/test_bootstrap_runtime.sh
git commit -m "docs: describe workstation runtime bootstrap"
```

Expected: both tests pass before the commit.

---

## Task 5: Run the complete verification gate

**Files:**

- Verify all changed files.

- [ ] **Step 1: Run repository tests.**

```bash
make test
```

Expected: every `tests/test_*.sh` script succeeds.

- [ ] **Step 2: Check shell syntax.**

```bash
bash -n scripts/*.sh
```

Expected: exit status `0`.

- [ ] **Step 3: Check Ansible syntax.**

```bash
ansible-playbook --syntax-check -i inventory.ini.example site.yml
```

Expected: `playbook: site.yml` and exit status `0`.

- [ ] **Step 4: Check formatting and generated files.**

```bash
git diff --check
awk 'length($0)>100 {print FILENAME ":" FNR ":" length($0)}' \
  scripts/bootstrap-runtime.sh README.md docs/operations.md
```

Expected: no output from either command. No runtime state, tunnel PID, backup,
or Pi configuration file may be staged.
