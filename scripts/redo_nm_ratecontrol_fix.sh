#!/usr/bin/env bash
# Re-runs heap_only_nm/moderate_nm/aggressive_nm (all 8 reps each, 24 total)
# in-place inside the existing 20260722_195217_raac_nm_full6arm results dir,
# now that BOTH known bugs are fixed:
#   1. AI-service fd exhaustion (ulimit 1024->65536, raac_nm_arm_functions.sh)
#   2. Caliper fixed-rate controller runaway under high rejection rates
#      (self-pacing added to benchmarks/mixedAttackLOHRaacBurst.js — see
#      raac_nm_round3_stall_bug memory, 2026-07-23 Phase 4 fix)
#
# static_nm/native_evict_nm/dagor_nm are NOT touched — already valid (near-
# 100% accept rate at the AI layer, so the rate-control bug barely applied;
# any earlier fd contamination for these was already patched by job27).
#
# job27 (the earlier ulimit-only patch watcher) was deliberately killed
# mid-queue once this rate-control bug was found, since its remaining/already
# -done work on heap_only/moderate/aggressive would have been invalid either
# way (patched with only half the fix). This script supersedes it.
set -uo pipefail
cd /home/yeochan.yoon/caliper-stress-test

WATCH_LOG="/home/yeochan.yoon/caliper-stress-test/redo_nm_ratecontrol_fix.log"
exec > >(tee -a "${WATCH_LOG}") 2>&1

echo ""
echo "======================================================================"
echo "redo_nm_ratecontrol_fix started | $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "======================================================================"

echo "Verifying no leftover pipeline processes..."
for i in $(seq 1 12); do
    still_running=0
    for pat in "hyperledger.besu.Besu" "nethermind.dll" "serve\.py"; do
        if pgrep -f "${pat}" > /dev/null 2>&1; then
            still_running=1
        fi
    done
    if [ "${still_running}" -eq 0 ]; then
        break
    fi
    echo "[$(date '+%H:%M:%S')] Leftover process(es) still exiting, waiting 10s (attempt ${i}/12)..."
    sleep 10
done
if pgrep -f "hyperledger.besu.Besu\|nethermind.dll\|serve\.py" > /dev/null 2>&1; then
    echo "[$(date '+%H:%M:%S')] ABORT: pipeline processes still present after 2min grace — refusing to start."
    pgrep -af "hyperledger.besu.Besu\|nethermind.dll\|serve\.py"
    exit 1
fi

export RESULTS_DIR="/home/yeochan.yoon/caliper-stress-test/results/raac_eval/20260722_195217_raac_nm_full6arm"
export RUN_ID="$(date +%Y%m%d_%H%M%S)_ratecontrol_fix"
source scripts/raac_nm_arm_functions.sh
source scripts/resource_gate.sh

echo "[$(date '+%H:%M:%S')] Re-running heap_only/moderate/aggressive (24 combos) with both fixes applied..."
for cfg in heap_only moderate aggressive; do
    for rep in 1 2 3 4 5 6 7 8; do
        wait_for_resource_headroom
        run_config_nm "${cfg}" "${rep}"
        rc=$?
        if [ $rc -ne 0 ]; then
            echo "  WARNING: ${cfg}_nm_${rep} failed (infra failure) — auto-retrying once"
            sleep 10
            run_config_nm "${cfg}" "${rep}" || echo "  WARNING: ${cfg}_nm_${rep} failed again, leaving prior data in place"
        fi
        sleep 15
    done
done

echo ""
echo "[$(date '+%H:%M:%S')] Regenerating bootstrap-CI report..."
python3.11 scripts/bootstrap_ci_report.py --results-dir "${RESULTS_DIR}" --baseline static_nm \
    --resamples 10000 --out "${RESULTS_DIR}/bootstrap_ci_report.md" \
    --out-json "${RESULTS_DIR}/bootstrap_ci_report.json"

echo ""
echo "======================================================================"
echo "redo_nm_ratecontrol_fix finished | $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "======================================================================"
