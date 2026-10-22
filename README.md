# Strata Server

Standalone automation for validating Strata with Qwen3.8-Flash-Next on the local ROCm server.

The repository controls only `192.168.0.2` and does not modify the `ai-server` repository. During
validation it stops the existing `llama-server`, starts Strata on port `8082`, records benchmark
results locally, and restores llama.cpp after failed validation or an explicit restore command.

## Configuration

Copy the example files before a real run:

```bash
cp inventory.ini.example inventory.ini
mkdir -p group_vars
cp group_vars/all.yml.example group_vars/all.yml
```

Adjust only protected local configuration when credentials or model settings differ.

## Commands

```bash
make plan INVENTORY=inventory.ini LIMIT=strata-server
make deploy INVENTORY=inventory.ini LIMIT=strata-server
make benchmark
make restore INVENTORY=inventory.ini LIMIT=strata-server
./scripts/bootstrap-runtime.sh status
./scripts/bootstrap-runtime.sh llama
./scripts/bootstrap-runtime.sh strata
```

The bootstrap command switches the remote service, creates an SSH tunnel on local port `18080`,
verifies the OpenAI-compatible API, and updates Pi's `~/.pi/agent/models.json`. It uses the
providers `gbrennon-strata` and `gbrennon-llama`. Run `/reload` and `/model` in an existing Pi
session after switching. The deployment installs `toggle-ai-runtime` on the server. Benchmark
reports are written to `results/` on this workstation and are ignored by git. Strata runs in
console/API mode with `--no-tui`; it does not open or require a web UI.
