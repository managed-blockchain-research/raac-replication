#!/usr/bin/env bash
# Attempt a dagor (NM) smoke test with the fixed harness (concurrency
# semaphore + txWallClockTimeout=8) BEFORE tonight's job 38 (23:00, Besu-only
# fragmentation-fix + ML ablation). dagor is the one arm not yet smoke-tested
# post-fix -- pre-fix it was the worst offender (calm-1, a ZERO-attack round,
# stretched to 730s/8x nominal), so its post-fix behavior is the biggest
# open uncertainty in the NM full-6arm-rerun time estimate.
#
# Starts polling for resource headroom at 21:00, every 10 minutes (same
# thresholds as resource_gate.sh: idle_cores>25, free_gb>50). Two safety
# cutoffs protect job 38's 23:00 start (shared ports 8545/8546/8000,
# AGENTS.md item 7):
#   - if no headroom found by 22:30, skip entirely (not enough time left)
#   - if the smoke test is still running at 22:55, hard-kill it
set -uo pipefail
cd /home/yeochan.yoon/caliper-stress-test
source scripts/raac_nm_arm_functions.sh

LOG="/home/yeochan.yoon/caliper-stress-test/dagor_smoketest_preflight.log"
exec > >(tee -a "${LOG}") 2>&1

echo ""
echo "======================================================================"
echo "dagor_preflight_smoketest started | $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "======================================================================"

TARGET_START_EPOCH=$(date -d "21:00:00" +%s)
POLL_CUTOFF_EPOCH=$(date -d "22:30:00" +%s)
HARD_CUTOFF_EPOCH=$(date -d "22:55:00" +%s)

now_epoch=$(date +%s)
if [ "${now_epoch}" -lt "${TARGET_START_EPOCH}" ]; then
    echo "[$(date '+%H:%M:%S')] Waiting until 21:00 to begin resource checks..."
    while [ "$(date +%s)" -lt "${TARGET_START_EPOCH}" ]; do
        sleep 60
    done
fi

echo "[$(date '+%H:%M:%S')] Polling resource headroom every 10 min (cutoff 22:30)..."
nproc_count=$(nproc --all)
while true; do
    now_epoch=$(date +%s)
    if [ "${now_epoch}" -ge "${POLL_CUTOFF_EPOCH}" ]; then
        echo "[$(date '+%H:%M:%S')] Cutoff (22:30) reached without headroom -- skipping dagor smoke test tonight (protecting job 38's 23:00 start)."
        exit 0
    fi

    read -r load1 _ _ < /proc/loadavg
    idle_cores=$(awk -v n="${nproc_count}" -v l="${load1}" 'BEGIN{printf "%.1f", n-l}')
    free_gb=$(free -g | awk '/Mem:/{print $7}')

    load_ok=0
    awk -v i="${idle_cores}" 'BEGIN{exit !(i>25)}' && load_ok=1
    mem_ok=0
    [ "${free_gb}" -gt 50 ] && mem_ok=1

    echo "[$(date '+%H:%M:%S')] idle_cores=${idle_cores} free_gb=${free_gb} load_ok=${load_ok} mem_ok=${mem_ok}"

    if [ "${load_ok}" -eq 1 ] && [ "${mem_ok}" -eq 1 ]; then
        echo "[$(date '+%H:%M:%S')] Headroom available."
        break
    fi
    sleep 600
done

now_epoch=$(date +%s)
job38_epoch=$(date -d "23:00:00" +%s)
remaining=$(( job38_epoch - now_epoch ))
if [ "${remaining}" -lt 1200 ]; then
    echo "[$(date '+%H:%M:%S')] Only ${remaining}s left before job 38 (23:00) -- not enough safety margin, skipping."
    exit 0
fi

N_REPS=1
RUN_ID="$(date +%Y%m%d_%H%M%S)_raac_nm_dagor_semaphore_smoketest"
RESULTS_DIR="/home/yeochan.yoon/caliper-stress-test/results/raac_eval/${RUN_ID}"
mkdir -p "${RESULTS_DIR}"
echo "[$(date '+%H:%M:%S')] Starting dagor smoke test. RUN_ID=${RUN_ID}"

run_config_nm "dagor" "1" &
RUN_PID=$!

while kill -0 "${RUN_PID}" 2>/dev/null; do
    if [ "$(date +%s)" -ge "${HARD_CUTOFF_EPOCH}" ]; then
        echo "[$(date '+%H:%M:%S')] Hard cutoff (22:55) reached -- killing dagor smoke test to protect job 38's 23:00 start."
        pkill -9 -f "nethermind.dll" 2>/dev/null || true
        pkill -9 -f "serve\.py" 2>/dev/null || true
        kill -9 "${RUN_PID}" 2>/dev/null || true
        break
    fi
    sleep 30
done
wait "${RUN_PID}" 2>/dev/null
rc=$?
echo "[$(date '+%H:%M:%S')] dagor smoke test exit code: ${rc}"
echo "${RESULTS_DIR}" > /home/yeochan.yoon/caliper-stress-test/LATEST_DAGOR_PREFLIGHT_RESULTS_DIR.txt

echo ""
echo "======================================================================"
echo "dagor_preflight_smoketest COMPLETE | $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "======================================================================"
