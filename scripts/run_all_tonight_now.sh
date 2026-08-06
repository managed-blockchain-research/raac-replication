#!/usr/bin/env bash
# Runs the full planned sequence immediately (started manually 2026-07-30
# ~09:43 KST, NOT via `at`) because the original `at` job 38 (23:00 KST the
# previous night) aborted instantly on its own pre-flight check -- a
# leftover serve.py process from an earlier smoke test was still running
# and blocked it from starting at all. That leftover has since been killed
# and verified clean. Running now instead of waiting for tonight's 23:00
# slot, per explicit user decision (resources checked good: idle_cores~29,
# free_mem~218GB at start).
#
# Sequence (same as the planned chain_besu_then_nm_after_job38.sh, just
# starting from job 38's own script instead of waiting for an `at` firing):
#   1. run_raac_resubmission_fixes_tonight.sh (Besu: fragmentation-fix +
#      ML ablation, rule_based n=8)
#   2. run_raac_full_6arm.sh (Besu 6-arm rerun, n=8, RAAC_MAX_INFLIGHT=50)
#   3. run_raac_nm_full_6arm.sh (NM 6-arm rerun, n=8, RAAC_MAX_INFLIGHT=5)
set -uo pipefail
cd /home/yeochan.yoon/caliper-stress-test

WATCH_LOG="/home/yeochan.yoon/caliper-stress-test/run_all_tonight_now.log"
exec > >(tee -a "${WATCH_LOG}") 2>&1

wait_for_clean_processes() {
    for i in $(seq 1 12); do
        still_running=0
        for pat in "hyperledger.besu.Besu" "nethermind.dll" "serve\.py"; do
            if pgrep -f "${pat}" > /dev/null 2>&1; then
                still_running=1
            fi
        done
        if [ "${still_running}" -eq 0 ]; then
            return 0
        fi
        echo "[$(date '+%H:%M:%S')] leftover process(es) still present, waiting 30s (attempt ${i}/12)..."
        sleep 30
    done
    return 1
}

echo ""
echo "======================================================================"
echo "run_all_tonight_now started | $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "======================================================================"

# Clear any stale urgent-flag file from a previous night/test run so tonight's
# MONDAY_SUMMARY.md verdict isn't contaminated by old content.
rm -f /home/yeochan.yoon/caliper-stress-test/NEEDS_ATTENTION_URGENT.txt

echo ""
echo "=============================================="
echo "Phase 1/3: job 38's work -- fragmentation-fix + ML ablation (Besu)"
echo "=============================================="
bash scripts/run_raac_resubmission_fixes_tonight.sh
rc0=$?
echo "[$(date '+%H:%M:%S')] Phase 1 exit code: ${rc0}"

echo "[$(date '+%H:%M:%S')] Verifying no leftover pipeline processes..."
if ! wait_for_clean_processes; then
    echo "ABORT: leftover pipeline processes never cleared after Phase 1 -- refusing to start Phase 2."
    pgrep -af "hyperledger.besu.Besu|nethermind.dll|serve\.py"
    exit 1
fi

echo ""
echo "=============================================="
echo "Phase 2/3: Besu full 6-arm eval (n=8, RAAC_MAX_INFLIGHT=50)"
echo "=============================================="
N_REPS=8 bash scripts/run_raac_full_6arm.sh
rc1=$?
echo "[$(date '+%H:%M:%S')] Phase 2 exit code: ${rc1}"

echo "[$(date '+%H:%M:%S')] Verifying no leftover pipeline processes..."
if ! wait_for_clean_processes; then
    echo "ABORT: leftover pipeline processes never cleared after Phase 2 -- refusing to start Phase 3."
    pgrep -af "hyperledger.besu.Besu|nethermind.dll|serve\.py"
    exit 1
fi

echo ""
echo "=============================================="
echo "Phase 3/3: NM full 6-arm eval (n=8, RAAC_MAX_INFLIGHT=5 default)"
echo "=============================================="
N_REPS=8 bash scripts/run_raac_nm_full_6arm.sh
rc2=$?
echo "[$(date '+%H:%M:%S')] Phase 3 exit code: ${rc2}"

echo ""
echo "======================================================================"
echo "run_all_tonight_now COMPLETE | $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "  Fragmentation: $(cat /home/yeochan.yoon/caliper-stress-test/LATEST_FRAGMENTATION_FIX_RESULTS_DIR.txt 2>/dev/null)"
echo "  ML ablation:   $(cat /home/yeochan.yoon/caliper-stress-test/LATEST_ML_ABLATION_RESULTS_DIR.txt 2>/dev/null)"
echo "  Besu 6-arm:    $(cat /home/yeochan.yoon/caliper-stress-test/LATEST_FULL6ARM_RESULTS_DIR.txt 2>/dev/null)"
echo "  NM 6-arm:      $(cat /home/yeochan.yoon/caliper-stress-test/LATEST_NM_FULL6ARM_RESULTS_DIR.txt 2>/dev/null)"
echo "======================================================================"

echo ""
echo "=============================================="
echo "Generating MONDAY_SUMMARY.md (health-check cross-check of every run)"
echo "=============================================="
python3.11 scripts/generate_weekend_summary.py
echo "[$(date '+%H:%M:%S')] MONDAY_SUMMARY.md written -- read this first."
