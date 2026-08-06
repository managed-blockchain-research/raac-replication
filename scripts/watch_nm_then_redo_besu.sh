#!/usr/bin/env bash
# Waits for redo_nm_ratecontrol_fix.sh to finish (NM: heap_only/moderate/
# aggressive redone with both the ulimit and rate-control fixes), then
# launches redo_besu_ratecontrol_fix.sh (Besu counterpart).
set -uo pipefail
cd /home/yeochan.yoon/caliper-stress-test

WATCH_LOG="/home/yeochan.yoon/caliper-stress-test/watch_nm_then_redo_besu.log"
exec > >(tee -a "${WATCH_LOG}") 2>&1

echo ""
echo "======================================================================"
echo "watch_nm_then_redo_besu started | $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "======================================================================"

NM_LOG="/home/yeochan.yoon/caliper-stress-test/redo_nm_ratecontrol_fix.log"
NM_RESULTS_DIR="/home/yeochan.yoon/caliper-stress-test/results/raac_eval/20260722_195217_raac_nm_full6arm"

while true; do
    if grep -q "redo_nm_ratecontrol_fix finished" "${NM_LOG}" 2>/dev/null \
        && ! pgrep -f "nethermind.dll" > /dev/null 2>&1 \
        && ! pgrep -f "redo_nm_ratecontrol_fix.sh" > /dev/null 2>&1; then
        echo "[$(date '+%H:%M:%S')] NM redo finished, no active NM process/script."
        break
    fi
    echo "[$(date '+%H:%M:%S')] NM redo still in progress, waiting 300s..."
    sleep 300
done

sleep 20
echo "[$(date '+%H:%M:%S')] Launching Besu redo..."
bash scripts/redo_besu_ratecontrol_fix.sh
rc=$?
echo "[$(date '+%H:%M:%S')] Besu redo exit code: ${rc}"

echo ""
echo "======================================================================"
echo "watch_nm_then_redo_besu finished | $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "======================================================================"
