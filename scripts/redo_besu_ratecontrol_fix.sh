#!/usr/bin/env bash
# Besu counterpart of redo_nm_ratecontrol_fix.sh — re-runs heap_only_besu/
# moderate_besu/aggressive_besu (8 reps each) plus dagor_besu (8 reps, out of
# caution: 2/8 reps failed round5 in the original run and dagor's reject path
# goes through the same submitTransaction() code, so it could be rate-control-
# bug-driven too) in-place inside the existing 20260722_060445_raac_full6arm
# results dir. Both fixes are in place by the time this runs:
#   1. AI-service fd exhaustion (ulimit 1024->65536, raac_arm_functions.sh)
#   2. Caliper fixed-rate controller runaway under high rejection
#      (benchmarks/mixedAttackLOHRaacBurst.js self-paces on total attempts now)
#
# static_besu/native_evict_besu are NOT touched — near-100% accept at the AI
# layer, unaffected by the rate-control bug; static_besu_3's earlier fd
# contamination was already patched separately (verify before assuming done).
set -uo pipefail
cd /home/yeochan.yoon/caliper-stress-test

WATCH_LOG="/home/yeochan.yoon/caliper-stress-test/redo_besu_ratecontrol_fix.log"
exec > >(tee -a "${WATCH_LOG}") 2>&1

echo ""
echo "======================================================================"
echo "redo_besu_ratecontrol_fix started | $(date '+%Y-%m-%d %H:%M:%S %Z')"
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

export RESULTS_DIR="/home/yeochan.yoon/caliper-stress-test/results/raac_eval/20260722_060445_raac_full6arm"
export RUN_ID="$(date +%Y%m%d_%H%M%S)_ratecontrol_fix_besu"
source scripts/raac_arm_functions.sh
source scripts/resource_gate.sh

echo "[$(date '+%H:%M:%S')] Re-running heap_only/moderate/aggressive/dagor (32 combos) with both fixes applied..."
for cfg in heap_only moderate aggressive dagor; do
    for rep in 1 2 3 4 5 6 7 8; do
        wait_for_resource_headroom
        run_config "${cfg}" "${rep}"
        rc=$?
        if [ $rc -ne 0 ]; then
            echo "  WARNING: ${cfg}_besu_${rep} failed (infra failure) — auto-retrying once"
            sleep 10
            run_config "${cfg}" "${rep}" || echo "  WARNING: ${cfg}_besu_${rep} failed again, leaving prior data in place"
        fi
        sleep 15
    done
done

echo ""
echo "[$(date '+%H:%M:%S')] Regenerating bootstrap-CI report..."
python3.11 scripts/bootstrap_ci_report.py --results-dir "${RESULTS_DIR}" --baseline static_besu \
    --resamples 10000 --out "${RESULTS_DIR}/bootstrap_ci_report.md" \
    --out-json "${RESULTS_DIR}/bootstrap_ci_report.json"

echo ""
echo "======================================================================"
echo "redo_besu_ratecontrol_fix finished | $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "======================================================================"
