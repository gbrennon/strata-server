# Operations

This guide describes the service interruption and recovery behavior for Strata validation.

## Target

The deployment target is `gbrennon-local-ai@192.168.0.2`. The repository does not modify the
existing `ai-server` checkout.

## Plan

A plan validates Ansible without changing services:

```bash
make plan INVENTORY=inventory.ini LIMIT=strata-server
```

## Deploy

Deployment captures llama.cpp state, installs Strata, stops `llama-server`, and starts Strata on
port `8082`:

```bash
make deploy INVENTORY=inventory.ini LIMIT=strata-server MODEL=iq3_s
```

The existing gateway is not changed. Validation uses the direct local Strata endpoint through an
SSH tunnel.

## Recovery

Restore Strata's saved prior state with:

```bash
make restore INVENTORY=inventory.ini LIMIT=strata-server
```

If llama.cpp was active before deployment, recovery starts `llama-server` and verifies port 8080.
If deployment validation fails, the deploy script attempts the same recovery automatically.

## Direct verification

Use the target's SSH address and port 8082 for a direct check:

```bash
ssh gbrennon-local-ai@192.168.0.2 \
  'curl --fail http://127.0.0.1:8082/health'
```
