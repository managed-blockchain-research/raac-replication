#!/usr/bin/env bash
# Waits until 21:00 KST, then polls resource headroom every 10 minutes
# (idle_cores>25, free_mem>50GB -- same thresholds as resource_gate.sh) and
# starts the full chain (run_all_tonight_now.sh: fragmentation-fix + ML
# ablation -> Besu 6-arm rerun -> NM 6-arm rerun) as soon as headroom is
# available. No hard cutoff this time (unlike the earlier dagor-preflight
# script) since there's no more `at` job to protect against -- this IS the
# whole night's run.
#
# Triggered by the 2026-07-30 daytime attempt getting hit by severe
# business-hours load (idle_cores dropped to 1.1 at one point), producing
# at least 2 incomplete reps (rule_based_besu_1 cut off mid-round-3 by the
# 900s timeout, aggressive_besu_8 fragmentation-fix rep similarly cut off
# mid-round-5). Both partial attempts logged to
# run_all_tonight_now_ATTEMPT1_daytime_incomplete.log for reference.
set -uo pipefail
cd /home/yeochan.yoon/caliper-stress-test

LOG="/home/yeochan.yoon/caliper-stress-test/wait_then_run_all_tonight.log"
exec > >(tee -a "${LOG}") 2>&1

echo ""
echo "======================================================================"
echo "wait_then_run_all_tonight started | $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "======================================================================"

TARGET_START_EPOCH=$(date -d "21:00:00" +%s)
now_epoch=$(date +%s)
if [ "${now_epoch}" -lt "${TARGET_START_EPOCH}" ]; then
    echo "[$(date '+%H:%M:%S')] Waiting until 21:00 to begin resource checks..."
    while [ "$(date +%s)" -lt "${TARGET_START_EPOCH}" ]; do
        sleep 60
    done
fi

echo "[$(date '+%H:%M:%S')] Polling resource headroom every 10 min (idle_cores>25, free_gb>50)..."
nproc_count=$(nproc --all)
while true; do
    read -r load1 _ _ < /proc/loadavg
    idle_cores=$(awk -v n="${nproc_count}" -v l="${load1}" 'BEGIN{printf "%.1f", n-l}')
    free_gb=$(free -g | awk '/Mem:/{print $7}')

    load_ok=0
    awk -v i="${idle_cores}" 'BEGIN{exit !(i>25)}' && load_ok=1
    mem_ok=0
    [ "${free_gb}" -gt 50 ] && mem_ok=1

    echo "[$(date '+%H:%M:%S')] load1=${load1} idle_cores=${idle_cores} free_gb=${free_gb} load_ok=${load_ok} mem_ok=${mem_ok}"

    if [ "${load_ok}" -eq 1 ] && [ "${mem_ok}" -eq 1 ]; then
        echo "[$(date '+%H:%M:%S')] Headroom available. Verifying no leftover pipeline processes..."
        clean=1
        for pat in "hyperledger.besu.Besu" "nethermind.dll" "serve\.py"; do
            if pgrep -f "${pat}" > /dev/null 2>&1; then
                clean=0
            fi
        done
        if [ "${clean}" -eq 1 ]; then
            break
        else
            echo "[$(date '+%H:%M:%S')] leftover process(es) present despite good resources -- waiting 600s before rechecking."
        fi
    fi
    sleep 600
done

echo "[$(date '+%H:%M:%S')] Starting the full chain."
bash scripts/analyze_each_run.sh &
echo "  analyze_each_run.sh PID: $!"
bash scripts/run_all_tonight_now.sh
rc=$?
echo "[$(date '+%H:%M:%S')] run_all_tonight_now.sh exit code: ${rc}"
