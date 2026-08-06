#!/usr/bin/env bash
# Empirical fragmentation-evasion test with corrected timing (JSS/JPDC
# "analytical, not empirical" critique fix). Runs a single "aggressive"
# repetition, with the rep counter set to N_REPS so raac_arm_functions.sh's
# fragmentation fuzz-loop hook fires (it only triggers on the LAST
# aggressive rep) -- but now mid-steady-state-stress instead of after
# cool-down (see the hook's updated comment in raac_arm_functions.sh for
# why the old timing produced an uninformative gc_pressure_before=0.0 for
# every fragment in every previously-captured run).
#
# We do NOT need to re-run the full n=8 six-arm comparison for this --
# GC-duty-cycle/round-completion numbers for "aggressive" already exist in
# results/raac_eval/20260726_100704_raac_full6arm/aggressive_besu_*/. This
# script only needs one correctly-timed fragmentation_fast.json /
# fragmentation_slowdrip.json.
set -uo pipefail
cd /home/yeochan.yoon/caliper-stress-test
source scripts/raac_arm_functions.sh
source scripts/resource_gate.sh

N_REPS="${N_REPS:-8}"   # must match the value the hook checks against
RUN_ID="$(date +%Y%m%d_%H%M%S)_raac_fragmentation_fix"
RESULTS_DIR="/home/yeochan.yoon/caliper-stress-test/results/raac_eval/${RUN_ID}"
LOG_FILE="/home/yeochan.yoon/caliper-stress-test/raac_fragmentation_fix_run.log"

mkdir -p "${RESULTS_DIR}"
exec > >(tee -a "${LOG_FILE}") 2>&1

echo ""
echo "======================================================================"
echo "RAAC fragmentation-evasion fix | 1 rep (aggressive, rep=${N_REPS}) | RUN_ID: ${RUN_ID}"
echo "  Fuzz-loop now fires ~30s into steady-state-stress (t=390s), while"
echo "  caliper's own attack traffic is still running -- not after cooldown."
echo "======================================================================"

label="aggressive_besu_${N_REPS}"
run_dir="${RESULTS_DIR}/${label}"
attempt=1; max_attempts=3
while true; do
    wait_for_resource_headroom
    run_config "aggressive" "${N_REPS}"
    rc=$?
    if [ $rc -ne 0 ]; then
        health_reason="infra_failure(rc=${rc})"; health_bad=1
    else
        # Only check calm-round health here (see check_run_health.py) --
        # this run's whole POINT is the fragmentation fuzz-loop firing during
        # attack-burst-2, so attack-round fail/slowness is expected, not a bug.
        health_output=$(python3.11 scripts/check_run_health.py "${run_dir}" 2>&1)
        if [ $? -eq 0 ]; then
            health_bad=0
        else
            health_reason="${health_output}"; health_bad=1
        fi
    fi
    if [ "${health_bad}" -eq 0 ]; then
        break
    fi
    if [ "${attempt}" -ge "${max_attempts}" ]; then
        echo "  WARNING: ${label} still anomalous after ${max_attempts} attempts: ${health_reason}"
        { echo "${label} (attempt ${attempt}/${max_attempts}):"; echo "${health_reason}"; echo; } >> "${RESULTS_DIR}/ANOMALOUS_RUNS.txt"
        {
            echo "Fragmentation-fix phase: ${label} anomalous after ${max_attempts} attempts at $(date '+%Y-%m-%d %H:%M:%S')"
            echo "Results dir: ${RESULTS_DIR} -- needs diagnosis before trusting fragmentation_fast.json/fragmentation_slowdrip.json."
        } >> /home/yeochan.yoon/caliper-stress-test/NEEDS_ATTENTION_URGENT.txt
        break
    fi
    echo "  WARNING: ${label} anomalous (attempt ${attempt}/${max_attempts}): ${health_reason} -- retrying"
    [ -d "${run_dir}" ] && mv "${run_dir}" "${run_dir}_BAD_attempt${attempt}_$(date +%H%M%S)"
    sleep 20
    attempt=$((attempt + 1))
done

echo ""
echo "======================================================================"
echo "COMPLETE — results in ${RESULTS_DIR}/aggressive_besu_${N_REPS}/"
echo "  fragmentation_fast.json / fragmentation_slowdrip.json"
echo "======================================================================"

echo "${RESULTS_DIR}" > /home/yeochan.yoon/caliper-stress-test/LATEST_FRAGMENTATION_FIX_RESULTS_DIR.txt

echo ""
echo "Cleaning up temp/log clutter..."
rm -f /tmp/serve_ai_full6arm.log
: > /home/yeochan.yoon/caliper-stress-test/caliper.log 2>/dev/null || true
find /home/yeochan.yoon/caliper-stress-test -maxdepth 1 -name "data_n_*" -type d -exec rm -rf {} + 2>/dev/null || true
echo "Cleanup done."
