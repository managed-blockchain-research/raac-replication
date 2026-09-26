#!/usr/bin/env bash
# Collateral-damage Pareto frontier (2026-09-24 ETRI resubmission pass),
# Besu case study. Copy+diff-edit of run_gc_engine_swap_besu.sh's
# loop/health-check pattern.
#
# FRAMING (from the scope debate, 2026-09-24 -- do not drop this when
# writing up results): this is a Besu-specific case study explaining the
# ALREADY-ESTABLISHED cross-runtime inversion (native pool-bounding
# dominates on Besu -- see "Cross-Runtime GC Duty-Cycle Reduction"), not a
# second cross-runtime comparison and not the paper's general answer to the
# editor's "no real comparison study" complaint. It intentionally covers
# only Besu; do not extend to Nethermind without re-running the scope
# debate (both prior debate participants independently rejected n=1 as
# indefensible and agreed the time budget doesn't support adding NM here).
#
# 7 policies x 3 attack intensities (0%, 25%, 75% -- NOT 100%: that
# condition already exists as the paper's main six/seven-policy result at
# this same 4GB heap, reuse it as the fourth frontier point rather than
# re-running it) x n=3.
set -uo pipefail
# 2026-09-25: BASE_DIR overridable (PARETO_BASE_DIR) so a second, fully
# isolated execution directory on a different node can run the tail of the
# policy list in parallel with the primary node's run, without sharing any
# Besu data-path / results-dir / log-file with it -- avoids the untested
# risk of two hosts writing concurrently into the same NFS-shared tree.
# Defaults to the original single-instance path when unset.
BASE_DIR="${PARETO_BASE_DIR:-/home/yeochan.yoon/caliper-stress-test-raac-r2-pareto-besu}"
cd "${BASE_DIR}"
export CALIPER_BASE_DIR="${BASE_DIR}"
source scripts/raac_arm_functions.sh
source scripts/resource_gate.sh

N_REPS="${N_REPS:-3}"
# POLICIES/INTENSITIES overridable so the still-unstarted policies at a
# given intensity can be split across two nodes once a node frees up
# mid-sweep -- avoids redoing already-done policy/intensity cells and
# roughly halves remaining wall-clock time (see BASE_DIR note above: pair
# with PARETO_BASE_DIR so the split instance doesn't share a directory).
POLICIES="${POLICIES:-static native_evict heap_only dagor token_bucket moderate aggressive}"
INTENSITIES="${INTENSITIES:-0 25 75}"
# 2026-09-26: RESUME_DIR + skip-existing-good-reps logic (mirroring
# run_shapesweep_besu.sh's run_condition()), added after a bootstrap-CI
# audit found 10 (policy,intensity) cells with INCOMPLETE-round reps --
# this script had no retry-on-anomaly logic, unlike its shape-sweep
# siblings (octo:debate 2026-09-26 verdict: backfill degraded cells to a
# clean n=5 rather than caveat around the bad data). INCOMPLETE-flagged
# reps were manually renamed to a "*_BAD_incomplete" suffix beforehand so
# they don't count toward the existing-good-reps check below and get
# silently replaced. Does NOT apply to native_evict's HIGH_FAIL flags --
# those are the paper's own genuine collateral-damage finding (RAAC's
# admission layer disabled rejects benign traffic even at 0% attack,
# consistent with the main eval's already-published 8-9% figure), not a
# data-quality problem, and were deliberately left unrenamed/kept.
RESUME_DIR="${RESUME_DIR:-}"

if [ -n "${RESUME_DIR}" ]; then
    RESULTS_DIR="${RESUME_DIR}"
    RUN_ID="$(basename "${RESULTS_DIR}")"
else
    RUN_ID="$(date +%Y%m%d_%H%M%S)_raac_pareto_besu"
    RESULTS_DIR="${BASE_DIR}/results/raac_eval/${RUN_ID}"
fi
LOG_FILE="${BASE_DIR}/raac_pareto_besu_run.log"

mkdir -p "${RESULTS_DIR}"
exec > >(tee -a "${LOG_FILE}") 2>&1

echo ""
echo "======================================================================"
echo "RAAC Pareto frontier (Besu case study) | RUN_ID: ${RUN_ID}"
echo "  Policies: ${POLICIES}"
echo "  Intensities: ${INTENSITIES} pct (attackRatio) | n=${N_REPS} | resume=${RESUME_DIR:-no}"
echo "======================================================================"

for pct in ${INTENSITIES}; do
    export BENCHCONFIG_RAAC_OVERRIDE="benchconfig-raac-intensity${pct}.yaml"
    for policy in ${POLICIES}; do
        label_suffix="${policy}_pct${pct}"
        start=1
        while [ -d "${RESULTS_DIR}/${label_suffix}_besu_${start}" ] && [ "${start}" -le "${N_REPS}" ]; do
            start=$((start + 1))
        done
        if [ "${start}" -gt 1 ]; then
            echo "  (resume) ${label_suffix}: ${start}/${N_REPS} good reps already present, continuing from ${start}"
        fi
        for i in $(seq "${start}" "${N_REPS}"); do
            wait_for_resource_headroom
            run_config "${policy}" "${i}"
            rc=$?
            src_dir="${RESULTS_DIR}/${policy}_besu_${i}"
            dst_dir="${RESULTS_DIR}/${label_suffix}_besu_${i}"
            [ -d "${src_dir}" ] && mv "${src_dir}" "${dst_dir}"
            if [ $rc -ne 0 ]; then
                echo "  WARNING: ${label_suffix}_besu_${i} failed (rc=${rc})"
            else
                health_output=$(python3.11 scripts/check_run_health.py "${dst_dir}" 2>&1) || \
                    echo "  WARNING: ${label_suffix}_besu_${i} anomalous: ${health_output}"
            fi
            sleep 15
        done
    done
done
unset BENCHCONFIG_RAAC_OVERRIDE

echo ""
echo "Pareto frontier (Besu case study) COMPLETE — results in ${RESULTS_DIR}"
echo "Remember: the 100%-intensity point for this frontier is the EXISTING"
echo "main-eval seven-policy result at 4GB heap, not re-run here."
echo "${RESULTS_DIR}" > "${BASE_DIR}/LATEST_PARETO_BESU_RESULTS_DIR.txt"
echo "Done."
