# Benchmarking

This guide records Strata measurements on the workstation without changing `ai-server`.

## Command

Run the benchmark after Strata passes verification:

```bash
make benchmark MODEL=iq3_s SSH_TARGET=gbrennon-local-ai@192.168.0.2
```

The command opens an SSH tunnel to the remote loopback API, performs one warm-up request, then
measures one streamed completion.

## Measurements

Each report records:

- Model identifier and endpoint.
- UTC start time.
- Time to first token.
- Total request duration.
- Prompt tokens per second.
- Generated tokens per second.
- ROCm, memory, and Strata service information.
- The exact prompt and measurement limitations.

Reports are written to `results/strata-YYYYMMDD-HHMMSS.md`. The directory is ignored by git and
remains on this workstation for comparison.

## Interpretation

Token counts are taken from server usage metadata when available. Otherwise the report marks them
as estimated. Compare runs using the same model, prompt, maximum output, and runtime settings.
A single run is an operational measurement, not a controlled laboratory benchmark.
