#!/usr/bin/env bash
# Resource-gated launcher for tonight's combined NM+Besu full 6-policy n=8
# run. Started via `at 21:00` (fully detached from any terminal/session, so
# it survives a disconnect) — polls load/mem every 10 min from launch time
# and fires ONLY once resources actually look free. No hard deadline / forced
# launch: explicit instruction is to keep monitoring and start when there is
# real headroom, not to force a start just because a clock time was reached.
set -uo pipefail
cd /home/yeochan.yoon/caliper-stress-test
LOG_FILE="/home/yeochan.yoon/caliper-stress-test/raac_gated_launch.log"
exec > >(tee -a "${LOG_FILE}") 2>&1

echo ""
echo "======================================================================"
echo "Gated launcher started: $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "======================================================================"

CHECK_INTERVAL=600  # 10 min

while true; do
    read -r load1 _ _ < /proc/loadavg
    free_gb=$(free -g | awk '/Mem:/{print $7}')

    conflicting=0
    for pat in "hyperledger.besu.Besu" "nethermind.dll" "serve\.py" \
               "run_raac_full_6arm.sh" "run_raac_nm_full_6arm.sh" \
               "run_raac_both_full6arm_tonight.sh"; do
        pgrep -f "${pat}" > /dev/null 2>&1 && conflicting=1
    done

    load_ok=0
    awk -v l="${load1}" 'BEGIN{exit !(l<8.0)}' && load_ok=1
    mem_ok=0
    [ "${free_gb}" -gt 80 ] && mem_ok=1

    echo "$(date '+%H:%M:%S') check: load1=${load1} avail_mem=${free_gb}G conflicting=${conflicting}"

    if [ "${conflicting}" -eq 1 ]; then
        echo "  -> a pipeline process is already running (previous invocation?) — skipping this check."
    elif [ "${load_ok}" -eq 1 ] && [ "${mem_ok}" -eq 1 ]; then
        echo "  -> resources OK, launching now."
        break
    else
        echo "  -> resources not ideal yet, waiting ${CHECK_INTERVAL}s."
    fi

    sleep "${CHECK_INTERVAL}"
done

echo ""
echo "Launching run_raac_both_full6arm_tonight.sh at $(date '+%Y-%m-%d %H:%M:%S %Z')"
bash scripts/run_raac_both_full6arm_tonight.sh
rc=$?
echo "run_raac_both_full6arm_tonight.sh finished with exit code ${rc} at $(date '+%Y-%m-%d %H:%M:%S %Z')"
