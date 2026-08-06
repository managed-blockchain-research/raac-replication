#!/usr/bin/env bash
# Watches for the currently-running Besu full6arm phase (part of
# run_raac_both_full6arm_tonight.sh, RUN_ID 20260722_060445_raac_full6arm)
# to finish, then immediately launches a FRESH NM-only full6arm re-run using
# the fixed ai_service/serve.py (adaptive RSS re-baseline — see
# raac_nm_round3_stall_bug memory / RSS_STABLE_* in serve.py).
#
# The original NM run (20260721_180622_raac_nm_full6arm) is invalid: the
# moderate/aggressive policies stalled at round 3/5 in every rep because the
# old RSS-delta baseline was locked once at startup and never adapted, so
# pressure pinned at 1.000 (max rejection) forever after the first attack
# burst. That data is NOT touched/overwritten by this script — this produces
# a brand-new timestamped results dir.
#
# User explicitly approved skipping the "heavy experiments only at 23:00
# KST" policy for this one rerun (2026-07-22, while on vacation/PTO) since
# per-run resource gating (scripts/resource_gate.sh) already protects
# against daytime contention at a finer grain.
set -uo pipefail
cd /home/yeochan.yoon/caliper-stress-test

WATCH_LOG="/home/yeochan.yoon/caliper-stress-test/watch_besu_then_rerun_nm.log"
exec > >(tee -a "${WATCH_LOG}") 2>&1

echo ""
echo "======================================================================"
echo "watch_besu_then_rerun_nm started | $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "======================================================================"

POLL_INTERVAL=300  # 5 min
TONIGHT_LOG="/home/yeochan.yoon/caliper-stress-test/raac_both_full6arm_tonight.log"

while true; do
    if grep -q "BOTH PLATFORMS COMPLETE" "${TONIGHT_LOG}" 2>/dev/null; then
        echo "[$(date '+%H:%M:%S')] Detected BOTH PLATFORMS COMPLETE — Besu phase done."
        break
    fi
    echo "[$(date '+%H:%M:%S')] Besu phase still running, waiting ${POLL_INTERVAL}s..."
    sleep "${POLL_INTERVAL}"
done

# Extra safety: make sure no leftover pipeline process is still holding the
# shared ports (8000/8545/8546) before we launch NM.
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
    echo "[$(date '+%H:%M:%S')] Leftover process(es) still exiting, waiting 10s (attempt ${i}/12)..."
    sleep 10
done

if pgrep -f "hyperledger.besu.Besu\|nethermind.dll\|serve\.py" > /dev/null 2>&1; then
    echo "[$(date '+%H:%M:%S')] ABORT: pipeline processes still present after 2min grace — refusing to launch NM rerun to avoid port collision. Manual check needed."
    pgrep -af "hyperledger.besu.Besu\|nethermind.dll\|serve\.py"
    exit 1
fi

echo "[$(date '+%H:%M:%S')] Clean. Launching fresh NM-only full6arm re-run (fixed serve.py, adaptive RSS re-baseline)..."
bash scripts/run_raac_nm_full_6arm.sh
rc=$?
echo "[$(date '+%H:%M:%S')] NM rerun exit code: ${rc}"
echo "[$(date '+%H:%M:%S')] NM rerun results dir: $(cat LATEST_NM_FULL6ARM_RESULTS_DIR.txt 2>/dev/null || echo MISSING)"
echo "======================================================================"
echo "watch_besu_then_rerun_nm finished | $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "======================================================================"
