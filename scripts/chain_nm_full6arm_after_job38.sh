#!/usr/bin/env bash
# Waits for tonight's job 38 (run_raac_resubmission_fixes_tonight.sh --
# Besu-only: fragmentation-fix + ML ablation) to fully finish, then runs the
# corrected NM full 6-arm eval (n=8), now using the fixed harness:
#   - mixedAttackLOHRaacBurst.js: per-worker concurrency semaphore
#     (RAAC_MAX_INFLIGHT, default 5) bounding in-flight AI-POST+sendRequests
#     chains, instead of unbounded fire-and-forget concurrency.
#   - networkconfig_nethermind_caliper.json: txWallClockTimeout 20 -> 8.
# Both fixes were validated via 3 single-rep smoke tests (aggressive,
# moderate, heap_only) on 2026-07-29 -- all three, which previously died at
# 0% completion in the original n=8 run, completed the full 6-round
# workload with the fixed harness. This run determines whether that holds
# at proper n=8 statistical power across all 6 arms.
#
# Job 38 and this NM run share ports 8545/8546/8000 -- never run
# concurrently (AGENTS.md item 7) -- hence waiting for completion rather
# than a fixed clock time.
set -uo pipefail
cd /home/yeochan.yoon/caliper-stress-test

WATCH_LOG="/home/yeochan.yoon/caliper-stress-test/chain_nm_full6arm_after_job38.log"
exec > >(tee -a "${WATCH_LOG}") 2>&1

JOB38_LOG="/home/yeochan.yoon/caliper-stress-test/raac_resubmission_fixes_tonight.log"

echo ""
echo "======================================================================"
echo "chain_nm_full6arm_after_job38 started | $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "Waiting for job 38 (${JOB38_LOG}) to report completion..."
echo "======================================================================"

while ! grep -q "Both phases complete\." "${JOB38_LOG}" 2>/dev/null; do
    echo "[$(date '+%H:%M:%S')] job 38 still running, waiting 300s..."
    sleep 300
done

echo "[$(date '+%H:%M:%S')] job 38 reported completion."

echo "[$(date '+%H:%M:%S')] Verifying no leftover pipeline processes..."
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
    echo "[$(date '+%H:%M:%S')] leftover process(es) still present, waiting 30s (attempt ${i}/12)..."
    sleep 30
done

if pgrep -f "hyperledger.besu.Besu|nethermind.dll|serve\.py" > /dev/null 2>&1; then
    echo "ABORT: leftover pipeline processes never cleared after job 38 -- refusing to start NM run."
    pgrep -af "hyperledger.besu.Besu|nethermind.dll|serve\.py"
    exit 1
fi

echo "[$(date '+%H:%M:%S')] Clean. Starting NM full 6-arm eval (n=8, fixed harness)."
N_REPS=8 bash scripts/run_raac_nm_full_6arm.sh
rc=$?
echo "[$(date '+%H:%M:%S')] NM full 6-arm eval exit code: ${rc}"

echo ""
echo "======================================================================"
echo "chain_nm_full6arm_after_job38 COMPLETE | $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "  Results dir: $(cat /home/yeochan.yoon/caliper-stress-test/LATEST_NM_FULL6ARM_RESULTS_DIR.txt 2>/dev/null)"
echo "======================================================================"
