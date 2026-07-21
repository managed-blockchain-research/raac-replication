#!/usr/bin/env bash
# Resource-gated launcher for tonight's combined NM+Besu full 6-policy n=8
# run. Started via `at 21:00` (fully detached from any terminal/session, so
# it survives a disconnect) — polls resources every 10 min from launch time
# and fires ONLY once there is real headroom. No hard deadline / forced
# launch: keep monitoring and start when resources are actually free.
#
# Thresholds are calibrated against real data, not guessed:
#   - This box has 48 cores (nproc). preflight_20260720_230000.log (an actual
#     23:00 KST preflight from last night) showed load average 13-18, driven
#     by 6+ other-team `simv` hardware-verification jobs each pegging ~99% of
#     one core continuously (elapsed times of hours/days — this is their
#     always-on regression farm, not tied to business hours). A naive
#     "load1 < 8" gate would likely never fire since that's below this box's
#     normal baseline. Gating on IDLE CORES (nproc - load1) instead measures
#     what actually matters for us: how much CPU headroom is left for our own
#     GC-thread / asyncio-event-loop-latency-sensitive processes.
#   - Memory: our whole footprint is ~10GB (1GB Besu heap + 4GB NM heap +
#     Caliper workers + AI service) on a 502GB box, so "available mem" is
#     essentially never the real constraint here — used only as a sanity
#     floor, not a discriminating gate.
set -uo pipefail
cd /home/yeochan.yoon/caliper-stress-test
LOG_FILE="/home/yeochan.yoon/caliper-stress-test/raac_gated_launch.log"
exec > >(tee -a "${LOG_FILE}") 2>&1

echo ""
echo "======================================================================"
echo "Gated launcher started: $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "======================================================================"

CHECK_INTERVAL=600  # 10 min
NPROC=$(nproc --all)
MIN_IDLE_CORES=15   # baseline other-team load is ~13-18 -> ~30-35 idle normally;
                     # this only blocks if load rises well beyond that baseline
MIN_AVAIL_MEM_GB=50 # our footprint is ~10GB; this is a sanity floor, not the real gate

while true; do
    read -r load1 _ _ < /proc/loadavg
    free_gb=$(free -g | awk '/Mem:/{print $7}')
    idle_cores=$(awk -v n="${NPROC}" -v l="${load1}" 'BEGIN{printf "%.1f", n-l}')

    conflicting=0
    for pat in "hyperledger.besu.Besu" "nethermind.dll" "serve\.py" \
               "run_raac_full_6arm.sh" "run_raac_nm_full_6arm.sh" \
               "run_raac_both_full6arm_tonight.sh"; do
        pgrep -f "${pat}" > /dev/null 2>&1 && conflicting=1
    done

    load_ok=0
    awk -v i="${idle_cores}" -v m="${MIN_IDLE_CORES}" 'BEGIN{exit !(i>m)}' && load_ok=1
    mem_ok=0
    [ "${free_gb}" -gt "${MIN_AVAIL_MEM_GB}" ] && mem_ok=1

    recent_oom=0
    last_oom_line=$(dmesg -T 2>/dev/null | grep -E "Out of memory|Killed process" | tail -1)
    if [ -n "${last_oom_line}" ]; then
        oom_ts=$(echo "${last_oom_line}" | grep -oE '^\[[A-Za-z]{3} [A-Za-z]{3} +[0-9]+ [0-9:]+ [0-9]{4}\]' | tr -d '[]')
        oom_epoch=$(date -d "${oom_ts}" +%s 2>/dev/null || echo 0)
        now_epoch=$(date +%s)
        if [ "${oom_epoch}" -gt 0 ] && [ $(( now_epoch - oom_epoch )) -lt 900 ]; then
            recent_oom=1
        fi
    fi

    echo "$(date '+%H:%M:%S') check: load1=${load1} nproc=${NPROC} idle_cores=${idle_cores} avail_mem=${free_gb}G conflicting=${conflicting} recent_oom=${recent_oom}"

    if [ "${conflicting}" -eq 1 ]; then
        echo "  -> a pipeline process is already running (previous invocation?) — skipping this check."
    elif [ "${recent_oom}" -eq 1 ]; then
        echo "  -> recent OOM-killer activity in dmesg — waiting for the system to settle."
    elif [ "${load_ok}" -eq 1 ] && [ "${mem_ok}" -eq 1 ]; then
        echo "  -> resources OK (idle_cores=${idle_cores} > ${MIN_IDLE_CORES}, avail_mem=${free_gb}G > ${MIN_AVAIL_MEM_GB}G), launching now."
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
