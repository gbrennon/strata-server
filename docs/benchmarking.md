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

## Performance tuning on Strix Halo

The target is a Ryzen AI Max+ 395 (`gfx1151`) with a BIOS Variable Graphics Memory
split of 96 GiB VRAM carve-out and ~32 GiB system RAM. Strata's gfx1151 engine treats
the integrated GPU as unified memory and sizes `--expert-cache auto` from system RAM,
not from the free carve-out VRAM. With only ~27 GiB available RAM, the ~53 GiB of
Qwen3.8-Flash-Next IQ3_S experts cannot stay resident and spill to the SATA-class SSD
(~0.45 GB/s), which collapses decode throughput and drives the service into swap.

The deploy pins the experts into the free carve-out VRAM and bounds the KV cache:

- `strata_expert_cache_slots: 24576` forces the full IQ3_S expert profile
  (~46.84 GiB) into VRAM, eliminating on-demand SSD reads during decode.
- `strata_context: 32k` bounds the KV cache so it fits alongside the experts.
- `strata_kv: int8` keeps the conversation cache compact.
- `strata_engine_settings: [prefill=16384]` sizes the prefill chunk.

Measured decode (200-word prompt, 300 tokens): ~33 tok/s with the starving auto
config, ~42 tok/s after pinning the experts into VRAM.

To reach the maintainer reference (IQ3_S ~59.7 tok/s at 8K, ~42.8 tok/s at 128K) the
BIOS carve-out must be reduced to the minimum so the full ~128 GiB becomes system RAM.
Strata then keeps every expert resident in the unified pool. The large dedicated
carve-out is the wrong shape for Strata's expert-offload engine on this APU.

## Interpretation

Token counts are taken from server usage metadata when available. Otherwise the report marks them
as estimated. Compare runs using the same model, prompt, maximum output, and runtime settings.
A single run is an operational measurement, not a controlled laboratory benchmark.
