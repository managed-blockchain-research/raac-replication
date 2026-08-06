#!/usr/bin/env bash
# Empirical fragmentation-evasion test on Nethermind (NM leg). Chosen over
# Besu because a Besu smoke test showed its post-GC-occupancy pressure
# signal stays under its activation threshold even under heavy GC churn
# (G1GC reclaims too effectively), so there's no sustained "elevated
# threshold" window to test evasion against. NM's RSS-based pressure signal
# is confirmed via the backlog-momentum finding to elevate substantially and
# persist for minutes after an attack burst -- a much better candidate.
#
# Runs a single "aggressive" repetition, with the rep counter set to N_REPS
# so raac_nm_arm_functions.sh's fragmentation fuzz-loop hook fires (only
# triggers on the LAST aggressive rep). We do NOT need to re-run the full
# n=8 six-arm NM comparison for this -- GC-duty-cycle/round-completion
# numbers for "aggressive" already exist in
# results/raac_eval/20260725_132441_raac_nm_full6arm/aggressive_nm_*/. This
# script only needs one correctly-timed fragmentation_fast.json /
# fragmentation_slowdrip.json.
#
# IMPORTANT: never run concurrently with anything touching Besu (shared
# ports 8545/8546/8000) -- see AGENTS.md item 7.
set -uo pipefail
cd /home/yeochan.yoon/caliper-stress-test
source scripts/raac_nm_arm_functions.sh
source scripts/resource_gate.sh

N_REPS="${N_REPS:-8}"   # must match the value the hook checks against
RUN_ID="$(date +%Y%m%d_%H%M%S)_raac_nm_fragmentation_fix"
RESULTS_DIR="/home/yeochan.yoon/caliper-stress-test/results/raac_eval/${RUN_ID}"
LOG_FILE="/home/yeochan.yoon/caliper-stress-test/raac_nm_fragmentation_fix_run.log"

mkdir -p "${RESULTS_DIR}"
exec > >(tee -a "${LOG_FILE}") 2>&1

echo ""
echo "======================================================================"
echo "RAAC NM fragmentation-evasion fix | 1 rep (aggressive, rep=${N_REPS}) | RUN_ID: ${RUN_ID}"
echo "  Fuzz-loop fires once caliper reports attack-burst-2 has started,"
echo "  while caliper's own attack traffic is still running -- not after"
echo "  cooldown, and not at a fixed offset (round durations stretch under"
echo "  host contention)."
echo "======================================================================"

wait_for_resource_headroom
run_config_nm "aggressive" "${N_REPS}"
rc=$?
if [ $rc -ne 0 ]; then
    echo "  WARNING: aggressive_nm_${N_REPS} failed (infra failure) — auto-retrying once"
    sleep 10
    run_config_nm "aggressive" "${N_REPS}" || echo "  WARNING: failed again"
fi

echo ""
echo "======================================================================"
echo "COMPLETE — results in ${RESULTS_DIR}/aggressive_nm_${N_REPS}/"
echo "  fragmentation_fast.json / fragmentation_slowdrip.json"
echo "======================================================================"

echo "${RESULTS_DIR}" > /home/yeochan.yoon/caliper-stress-test/LATEST_NM_FRAGMENTATION_FIX_RESULTS_DIR.txt

echo ""
echo "Cleaning up temp/log clutter..."
rm -f /tmp/serve_ai_nm_full6arm.log
: > /home/yeochan.yoon/caliper-stress-test/caliper.log 2>/dev/null || true
find /home/yeochan.yoon/caliper-stress-test -maxdepth 1 -name "data_n_*" -type d -exec rm -rf {} + 2>/dev/null || true
echo "Cleanup done."
