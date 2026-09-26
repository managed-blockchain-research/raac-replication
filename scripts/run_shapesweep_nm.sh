#!/usr/bin/env bash
# Allocator-threshold straddling sweep (2026-09-24 ETRI resubmission pass),
# Nethermind leg. Mirrors run_shapesweep_besu.sh; see that file's header for
# the full design rationale (shape list, mixed condition, n policy).
#
# .NET's LOH threshold is 85,000 bytes (well-documented, not something this
# project measured itself the way Besu's G1 region size was). Of this
# sweep's six shapes (96000/48000/24000/12000/6000/3000), only 96000 sits
# above 85000 and 48000 sits below it -- those are the two conditions that
# actually flank the threshold, so they are the ones bumped to n=5 by
# default here (unlike the Besu leg, where the threshold-adjacent shape(s)
# are left for the real data to identify).
set -uo pipefail
cd /home/yeochan.yoon/caliper-stress-test-raac-r2-shapesweep-nm
export CALIPER_BASE_DIR="/home/yeochan.yoon/caliper-stress-test-raac-r2-shapesweep-nm"
export BENCHCONFIG_RAAC_OVERRIDE="benchconfig-raac-shapesweep.yaml"
source scripts/raac_nm_arm_functions.sh
source scripts/resource_gate.sh

N_REPS_BASE=10
N_REPS_BUMP=10
NM_BUMP_SHAPES="${NM_BUMP_SHAPES:-96000 48000}"
SHAPES="96000 48000 24000 12000 6000 3000"
POLICIES="static aggressive"

# 2026-09-24: n bumped 3->10, see run_shapesweep_besu.sh header for why.
# RESUME_DIR lets this pick up the already-completed reps from the prior
# n=3/n=5 run (same RESULTS_DIR) instead of redoing them.
RESUME_DIR="${RESUME_DIR:-}"

if [ -n "${RESUME_DIR}" ]; then
    RESULTS_DIR="${RESUME_DIR}"
    RUN_ID="$(basename "${RESULTS_DIR}")"
else
    RUN_ID="$(date +%Y%m%d_%H%M%S)_raac_shapesweep_nm"
    RESULTS_DIR="/home/yeochan.yoon/caliper-stress-test-raac-r2-shapesweep-nm/results/raac_eval/${RUN_ID}"
fi
LOG_FILE="/home/yeochan.yoon/caliper-stress-test-raac-r2-shapesweep-nm/raac_shapesweep_nm_run.log"

mkdir -p "${RESULTS_DIR}"
exec > >(tee -a "${LOG_FILE}") 2>&1

echo ""
echo "======================================================================"
echo "RAAC allocator-threshold shape sweep, Nethermind | RUN_ID: ${RUN_ID}"
echo "  Shapes: ${SHAPES} (+mixed) | Policies: ${POLICIES} | n=${N_REPS_BASE} base, n=${N_REPS_BUMP} for [${NM_BUMP_SHAPES}] (LOH=85000B straddle) | resume=${RESUME_DIR:-no}"
echo "======================================================================"

run_condition() {
    local policy="$1" label_suffix="$2" n="$3"
    local start=1
    while [ -d "${RESULTS_DIR}/${label_suffix}_nm_${start}" ] && [ "${start}" -le "${n}" ]; do
        start=$((start + 1))
    done
    if [ "${start}" -gt 1 ]; then
        echo "  (resume) ${label_suffix}: ${start}/${n} reps already present, continuing from ${start}"
    fi
    for i in $(seq "${start}" "${n}"); do
        wait_for_resource_headroom
        run_config_nm "${policy}" "${i}"
        rc=$?
        src_dir="${RESULTS_DIR}/${policy}_nm_${i}"
        dst_dir="${RESULTS_DIR}/${label_suffix}_nm_${i}"
        [ -d "${src_dir}" ] && mv "${src_dir}" "${dst_dir}"
        if [ $rc -ne 0 ]; then
            echo "  WARNING: ${label_suffix}_nm_${i} failed (rc=${rc})"
        else
            health_output=$(python3.11 scripts/check_run_health.py "${dst_dir}" 2>&1) || \
                echo "  WARNING: ${label_suffix}_nm_${i} anomalous: ${health_output}"
        fi
        sleep 15
    done
}

for policy in ${POLICIES}; do
    for shape in ${SHAPES}; do
        export RAAC_ATTACK_PAYLOAD_BYTES="${shape}"
        unset RAAC_ATTACK_SHAPE_MIX RAAC_ATTACK_SHAPE_SET 2>/dev/null || true
        n="${N_REPS_BASE}"
        for bump in ${NM_BUMP_SHAPES}; do [ "${bump}" = "${shape}" ] && n="${N_REPS_BUMP}"; done
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
echo "Shape sweep (Nethermind) COMPLETE — results in ${RESULTS_DIR}"
echo "${RESULTS_DIR}" > /home/yeochan.yoon/caliper-stress-test-raac-r2-shapesweep-nm/LATEST_SHAPESWEEP_NM_RESULTS_DIR.txt
echo "Done."
