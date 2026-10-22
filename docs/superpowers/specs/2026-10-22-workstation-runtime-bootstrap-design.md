# Workstation Runtime Bootstrap

This design defines one workstation command for switching the remote AI runtime and Pi's
local model configuration.

## Goals

- Switch between the remote `llama-server` and Strata services over SSH.
- Start one SSH tunnel for the selected service.
- Verify the selected service through its OpenAI-compatible API.
- Update Pi's global model configuration only after verification succeeds.
- Use the provider names `gbrennon-llama` and `gbrennon-strata`.
- Preserve a backup before changing Pi configuration.

## User Interface

The command will be installed in the repository as `scripts/bootstrap-runtime.sh`:

```bash
./scripts/bootstrap-runtime.sh strata
./scripts/bootstrap-runtime.sh llama
./scripts/bootstrap-runtime.sh status
```

The script will use these environment variables:

- `SSH_TARGET`, defaulting to `gbrennon-local-ai@192.168.0.2`.
- `PI_MODELS_FILE`, defaulting to `~/.pi/agent/models.json`.
- `LOCAL_API_PORT`, defaulting to `18080`.
- `SSH_BIN`, defaulting to `ssh`.
- `CURL_BIN`, defaulting to `curl`.

The command will require the remote toggle command to be installed as `toggle-ai-runtime`.

## Runtime Switching

For `strata`, the script will invoke `sudo toggle-ai-runtime strata` remotely. It will
then forward local port `18080` to remote port `8082`.

For `llama`, the script will invoke `sudo toggle-ai-runtime llama` remotely. It will
then forward local port `18080` to remote port `8080`.

Before creating a tunnel, the script will stop and remove the tunnel created by an earlier
invocation. It will track the tunnel process in a runtime-specific PID file under the user's
state directory.

The script will not change Pi's configuration until the selected tunnel responds
successfully to `/health`, `/v1/models`, and `/v1/chat/completions`.

## Pi Configuration

The script will read the selected model ID from the local tunnel's `/v1/models` response.
It will update `PI_MODELS_FILE` atomically while preserving unrelated providers and settings.

The active provider will contain:

- `gbrennon-strata` for Strata.
- `gbrennon-llama` for llama.cpp.
- `baseUrl: http://127.0.0.1:18080/v1`.
- `api: openai-completions`.
- A local placeholder API key.
- The model ID returned by `/v1/models`.

The inactive custom provider will be removed so Pi presents only the selected runtime.
Existing configuration will be copied to a timestamped backup before replacement.

An already-running Pi session will require `/reload` and `/model` to select the updated model.

## Failure Handling

- Invalid runtime names will fail without changing services, tunnels, or Pi configuration.
- SSH or remote service failures will stop the operation before configuration changes.
- Tunnel failures will stop the operation before configuration changes.
- API failures will terminate the new tunnel and leave the previous Pi configuration intact.
- Configuration write failures will leave the backup available and report the original file path.
- `status` will report the selected remote service state, tunnel state, local API health,
  and active Pi provider.

## Testing

- Shell syntax checks will cover the new script.
- Tests will use fake SSH, curl, and process commands to verify both runtime paths.
- Tests will verify that failed health checks do not replace Pi configuration.
- Tests will verify atomic configuration updates and backup creation.
- The existing shell test suite and Ansible syntax check will run after implementation.
