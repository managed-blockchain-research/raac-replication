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

## ETRI Journal resubmission experiments

Four additional experiments were added for the ETRI Journal resubmission,
each with its own run script (all source `scripts/raac_arm_functions.sh` /
`raac_nm_arm_functions.sh` for the shared admission-policy/runtime-monitoring
logic, `scripts/resource_gate.sh` for load-aware scheduling, and are checked
per-repetition by `scripts/check_run_health.py`; all use
`scripts/bootstrap_ci_report.py` for percentile-bootstrap analysis):

- **Token Bucket baseline** — `scripts/run_token_bucket_arm_besu.sh` /
  `run_token_bucket_arm_nm.sh`. A content-blind rate-limiting policy
  (capacity 150 tokens, refill 100 tokens/s) added as a second external
  baseline alongside Dagor.
- **GC-engine swap** — `scripts/run_gc_engine_swap_besu.sh`. Repeats the
  Static and Native Evict policies on Besu with `-XX:+UseZGC` in place of
  `-XX:+UseG1GC`, flags-only, to isolate whether the Besu/Nethermind
  platform inversion is collector-specific.
- **Allocator-threshold shape sweep** — `scripts/run_shapesweep_besu.sh` /
  `run_shapesweep_nm.sh`, using `benchmarks/mixedAttackLOHRaacBurstShapeSweep.js`
  and `configs/benchconfig-raac-shapesweep.yaml`. Varies each attack
  transaction's own calldata size across six values (96,000 down to
  3,000 bytes) plus a within-burst random-shape-mix condition.
- **Collateral-damage Pareto frontier** — `scripts/run_pareto_besu.sh`,
  using `configs/benchconfig-raac-intensity{0,25,75}.yaml`. Repeats all
  seven admission policies at 0%/25%/75% attack ratio on Besu at a fixed
  4 GB heap. Supports resume-based backfill via the `RESUME_DIR`,
  `POLICIES`, `INTENSITIES`, `N_REPS`, and `PARETO_BASE_DIR` environment
  variables, so a partial or degraded run can be topped up without
  redoing already-good repetitions.
- **Figure generation** — `figures/plot_shape_sweep.py` and
  `figures/plot_pareto.py` (matplotlib) produce the two-panel figures used
  in the resubmission's shape-sweep and Pareto-frontier sections.
