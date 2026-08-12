# Fragmentation-evasion raw data (raac.tex Section 5.6, Table 8, Figure 10)

Source: `RUN_ID 20260812_170934_raac_fragmentation_fix`, label
`aggressive_besu_8`, produced by `scripts/run_raac_fragmentation_fix.sh`
(which fires `scripts/fragmentation_fuzz.py` via the hook in
`scripts/raac_arm_functions.sh`, `--k-values
1,2,3,4,5,6,8,10,12,16,20,24,32,48,64,96 --drip-delay 0` for
`fragmentation_fast.json`, and `--k-values 5 --drip-delay 35` for
`fragmentation_slowdrip.json`).

## Why this is the retained (not the first) attempt

This run's per-run health check (`scripts/check_run_health.py`) flagged an
early-round anomaly (`calm-1` transaction fail rate 20.8%, consistent with
transient host CPU contention from unrelated jobs on a shared research
server) and the orchestrating script archived it as
`..._BAD_attempt1_172700` before retrying. That anomaly occurred during
`calm-1`, well before the fragmentation fuzz-loop fires (~20s into
`attack-burst-2`, after `gc_pressure` is confirmed at its sustained-attack
value), and does not affect the validity of the fragmentation-evasion
measurement itself -- confirmed by inspecting each fragment's recorded
`gc_pressure_before` value directly (see below). It is kept here, rather
than the auto-retried "clean" attempt, because that later attempt happened
to run the fuzz-loop while `gc_pressure` was still 0.0 (attack pressure had
not yet built up when the loop fired), which makes every fragment count
trivially "accepted" and is uninformative for the evasion-threshold
question this table answers.

## What each file is

- `fragmentation_fast.json`: the volume-fragmentation sweep (k = 1 through
  96, no delay between fragments). Table 8 reports k = 1 (gas-cost baseline
  only), 12, 16, 20, 24 (all rejected under confirmed `gc_pressure = 1.0`),
  and 32 (admitted, the measured 2.67x / 167% gas increase). Figure 10 plots
  every fragment's `anomaly_score` against its payload size across the full
  k sweep.
- `fragmentation_slowdrip.json`: the pacing-evasion test (k = 5, 35s between
  fragments -- chosen to exceed the 30-second rolling window over which
  Besu's pressure signal is computed, Section 5.3.1). 4 of 5 fragments were
  admitted despite scoring as attack-shaped, because `gc_pressure` had
  partially decayed between submissions.

Each fragment record includes `anomaly_score`, `gc_pressure_before`,
`ai_action` (accept/reject), and (for admitted fragments) the real on-chain
`gas_used` -- the exact fields the paper's numbers are computed from.
