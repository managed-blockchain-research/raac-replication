#!/usr/bin/env bash
# Waits for tonight's job 38 (run_raac_resubmission_fixes_tonight.sh --
# Besu-only: fragmentation-fix + ML ablation) to fully finish, then runs:
#   1. Besu full 6-arm eval (n=8) -- rerun with the platform-tuned
#      concurrency cap (RAAC_MAX_INFLIGHT=50, set in raac_arm_functions.sh)
#      for methodological consistency with the NM rerun below (both
#      platforms now collected under the same, documented, understood
#      harness version instead of Besu on the old unbounded-concurrency
#      workload module and NM on a newly-capped one).
#   2. NM full 6-arm eval (n=8) -- with the fixes validated via 4 smoke
#      tests on 2026-07-29 (concurrency semaphore RAAC_MAX_INFLIGHT=5,
#      default in mixedAttackLOHRaacBurst.js since NM's own per-tx latency
#      is much lower than Besu's under normal conditions; txWallClockTimeout
#      20->8 in networkconfig_nethermind_caliper.json).
#
# Order chosen deliberately (Besu before NM, not NM first): job 38 is
# Besu-only, so running the Besu rerun immediately after avoids an extra
# platform switch (still only one switch total: Besu -> NM at the end).
#
# All three phases share ports 8545/8546/8000 -- never run concurrently
# (AGENTS.md item 7) -- hence waiting for completion rather than a fixed
# clock time, and re-verifying no leftover processes between phases.
set -uo pipefail
cd /home/yeochan.yoon/caliper-stress-test

WATCH_LOG="/home/yeochan.yoon/caliper-stress-test/chain_besu_then_nm_after_job38.log"
exec > >(tee -a "${WATCH_LOG}") 2>&1

JOB38_LOG="/home/yeochan.yoon/caliper-stress-test/raac_resubmission_fixes_tonight.log"

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
echo "chain_besu_then_nm_after_job38 started | $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "Waiting for job 38 (${JOB38_LOG}) to report completion..."
echo "======================================================================"

while ! grep -q "Both phases complete\." "${JOB38_LOG}" 2>/dev/null; do
    echo "[$(date '+%H:%M:%S')] job 38 still running, waiting 300s..."
    sleep 300
done
echo "[$(date '+%H:%M:%S')] job 38 reported completion."

echo "[$(date '+%H:%M:%S')] Verifying no leftover pipeline processes..."
if ! wait_for_clean_processes; then
    echo "ABORT: leftover pipeline processes never cleared after job 38 -- refusing to start Besu rerun."
    pgrep -af "hyperledger.besu.Besu|nethermind.dll|serve\.py"
    exit 1
fi

echo ""
echo "=============================================="
echo "Phase 1/2: Besu full 6-arm eval (n=8, RAAC_MAX_INFLIGHT=50)"
echo "=============================================="
N_REPS=8 bash scripts/run_raac_full_6arm.sh
rc1=$?
echo "[$(date '+%H:%M:%S')] Besu full 6-arm eval exit code: ${rc1}"

echo "[$(date '+%H:%M:%S')] Verifying no leftover pipeline processes before switching to NM..."
if ! wait_for_clean_processes; then
    echo "ABORT: leftover pipeline processes never cleared after Besu rerun -- refusing to start NM rerun."
    pgrep -af "hyperledger.besu.Besu|nethermind.dll|serve\.py"
    exit 1
fi

echo ""
echo "=============================================="
echo "Phase 2/2: NM full 6-arm eval (n=8, RAAC_MAX_INFLIGHT=5 default)"
echo "=============================================="
N_REPS=8 bash scripts/run_raac_nm_full_6arm.sh
rc2=$?
echo "[$(date '+%H:%M:%S')] NM full 6-arm eval exit code: ${rc2}"

echo ""
echo "======================================================================"
echo "chain_besu_then_nm_after_job38 COMPLETE | $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "  Besu results dir: $(cat /home/yeochan.yoon/caliper-stress-test/LATEST_FULL6ARM_RESULTS_DIR.txt 2>/dev/null)"
echo "  NM results dir:   $(cat /home/yeochan.yoon/caliper-stress-test/LATEST_NM_FULL6ARM_RESULTS_DIR.txt 2>/dev/null)"
echo "======================================================================"
