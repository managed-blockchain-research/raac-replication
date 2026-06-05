# RAAC: Runtime-Aware Adaptive Admission Control

Replication package for **"Runtime-Aware Adaptive Admission Control (RAAC) for Managed Blockchain Clients"**.

## Structure
- `configs/` — Caliper benchmark configurations
- `benchmarks/` — Workload JavaScript files
- `scripts/` — Experiment run and analysis scripts
- `results/` — GC event and latency summary CSVs
- `figures/` — Figure generation script (`draw_figures.py`)
- `src/` — Smart contract source (StateBloater.sol)

## Quick Start
1. Deploy `src/StateBloater.sol` via `deploy_contract.py`
2. Run: `scripts/run_raac_eval.sh`
3. Analyze: `scripts/parse_raac_results.py`
4. Figures: `figures/draw_figures.py`
