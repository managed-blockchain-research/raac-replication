#!/usr/bin/env bash
# Allocator-threshold straddling sweep (2026-09-24 ETRI resubmission pass),
# Besu leg. Copy+diff-edit of run_gc_engine_swap_besu.sh's loop/health-check
# pattern (never rewrite from scratch, per project convention).
#
# Holds attack transaction COUNT/RATIO constant (the existing six-phase
# schedule, unchanged) and instead varies each attack transaction's OWN
# payload size across 96000/48000/24000/12000/6000/3000 bytes -- these are
# the "1x96KB / 2x48KB / 4x24KB / 8x12KB / 16x6KB / 32x3KB" shapes from the
# paper's framing (equal division of a 96000-byte total), bracketing G1's
# humongous-object threshold, plus one "mixed" condition (payload size drawn
# uniformly at random per attack tx from the full shape set -- from the
# allocator-threshold-sweep debate, 2026-09-24: tests whether the
# controller/GC response generalizes when shapes vary within a single
# burst, not just across separate isolated runs).
#
# Empirically measured (from the currently-running Besu Token Bucket
# baseline, gc_besu.log): G1 Heap Region Size = 2048K (2M), so the
# humongous-object threshold (region-size/2) is 1024K (1MB) -- well above
# any single shape in this sweep. Real "Humongous regions: N->M" GC events
# ARE observed during the fixed-96000-byte attack burst regardless (e.g.
# "GC(6) Humongous regions: 19->11"), so per-transaction size crossing 1MB
# is evidently not the whole mechanism (concurrent/aggregate allocation
# pressure from many near-simultaneous attack transactions, and/or
# allocation overhead beyond the raw calldata bytes during RLP/decode, are
# the more likely drivers) -- this sweep's own duty-cycle-vs-shape data is
# what should settle which shapes are actually "threshold-adjacent" for
# Besu; do not assume a specific pair without looking at that data first.
#
# n=3 baseline per condition; BESU_BUMP_SHAPES (space-separated subset of
# the 6 fixed byte values) reruns to n=5 for whichever shape(s) the data
# says are threshold-adjacent -- empty by default (this project's
# convention: report the honest n=3 sweep first, then decide bump targets
# from evidence, not from a guess. See run header comment above and the
# commit message for the state of that decision as of this commit.)
set -uo pipefail
cd /home/yeochan.yoon/caliper-stress-test-raac-r2-shapesweep-besu
export CALIPER_BASE_DIR="/home/yeochan.yoon/caliper-stress-test-raac-r2-shapesweep-besu"
export BENCHCONFIG_RAAC_OVERRIDE="benchconfig-raac-shapesweep.yaml"
source scripts/raac_arm_functions.sh
source scripts/resource_gate.sh

N_REPS_BASE=10
N_REPS_BUMP=10
BESU_BUMP_SHAPES="${BESU_BUMP_SHAPES:-}"
SHAPES="96000 48000 24000 12000 6000 3000"
POLICIES="static aggressive"

# 2026-09-24: n bumped 3->10 after live inspection showed aggressive/96000's
# n=3 was too noisy to read (439/705/715ms, health-check HEALTHY on all three
# -- genuine run-to-run variance in the adaptive controller's timing, not a
# bug) to draw a defensible shape-vs-duty-cycle curve from. RESUME_DIR lets
# this pick up the already-completed reps from the prior n=3 run (same
# RESULTS_DIR) instead of redoing them.
RESUME_DIR="${RESUME_DIR:-}"

if [ -n "${RESUME_DIR}" ]; then
    RESULTS_DIR="${RESUME_DIR}"
    RUN_ID="$(basename "${RESULTS_DIR}")"
else
    RUN_ID="$(date +%Y%m%d_%H%M%S)_raac_shapesweep_besu"
    RESULTS_DIR="/home/yeochan.yoon/caliper-stress-test-raac-r2-shapesweep-besu/results/raac_eval/${RUN_ID}"
fi
LOG_FILE="/home/yeochan.yoon/caliper-stress-test-raac-r2-shapesweep-besu/raac_shapesweep_besu_run.log"

mkdir -p "${RESULTS_DIR}"
exec > >(tee -a "${LOG_FILE}") 2>&1

echo ""
echo "======================================================================"
echo "RAAC allocator-threshold shape sweep, Besu | RUN_ID: ${RUN_ID}"
echo "  Shapes: ${SHAPES} (+mixed) | Policies: ${POLICIES} | n=${N_REPS_BASE} base, n=${N_REPS_BUMP} for [${BESU_BUMP_SHAPES}] | resume=${RESUME_DIR:-no}"
echo "======================================================================"

run_condition() {
    local policy="$1" label_suffix="$2" n="$3"
    local start=1
    # Resume support: skip reps that already exist (as a healthy, non-BAD
    # directory) for this exact label under RESULTS_DIR, so re-running with
    # a higher n tops up existing conditions instead of redoing them.
    while [ -d "${RESULTS_DIR}/${label_suffix}_besu_${start}" ] && [ "${start}" -le "${n}" ]; do
        start=$((start + 1))
    done
    if [ "${start}" -gt 1 ]; then
        echo "  (resume) ${label_suffix}: ${start}/${n} reps already present, continuing from ${start}"
    fi
    for i in $(seq "${start}" "${n}"); do
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
}

for policy in ${POLICIES}; do
    for shape in ${SHAPES}; do
        export RAAC_ATTACK_PAYLOAD_BYTES="${shape}"
        unset RAAC_ATTACK_SHAPE_MIX RAAC_ATTACK_SHAPE_SET 2>/dev/null || true
        n="${N_REPS_BASE}"
        for bump in ${BESU_BUMP_SHAPES}; do [ "${bump}" = "${shape}" ] && n="${N_REPS_BUMP}"; done
        run_condition "${policy}" "${policy}_shape${shape}" "${n}"
    done
done

export RAAC_ATTACK_SHAPE_MIX=1
export RAAC_ATTACK_SHAPE_SET="96000,48000,24000,12000,6000,3000"
unset RAAC_ATTACK_PAYLOAD_BYTES 2>/dev/null || true
for policy in ${POLICIES}; do
    run_condition "${policy}" "${policy}_mixed" "${N_REPS_BASE}"
done
unset RAAC_ATTACK_SHAPE_MIX RAAC_ATTACK_SHAPE_SET

echo ""
echo "Shape sweep (Besu) COMPLETE — results in ${RESULTS_DIR}"
echo "${RESULTS_DIR}" > /home/yeochan.yoon/caliper-stress-test-raac-r2-shapesweep-besu/LATEST_SHAPESWEEP_BESU_RESULTS_DIR.txt
echo "Done."
