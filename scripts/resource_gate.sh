#!/usr/bin/env bash
# Shared resource-headroom gate, sourced by both run_raac_full_6arm.sh (Besu)
# and run_raac_nm_full_6arm.sh (NM). Call wait_for_resource_headroom before
# EACH individual run, not just once before the whole batch — this box's
# "quiet" state can change mid-batch (other-team simv jobs, business hours),
# so gating once up front and then running 48 reps blind isn't safe.
#
# Thresholds calibrated against real data (see run_raac_tonight_gated.sh
# comment header for the full story): idle cores (nproc - load1) > 15,
# available memory > 50G (sanity floor, not the real constraint — our own
# footprint is ~10GB on a 502GB box), no OOM-killer event in the last 15 min.

wait_for_resource_headroom() {
    local nproc_count min_idle=15 min_mem_gb=50 interval=600
    nproc_count=$(nproc --all)

    while true; do
        local load1 free_gb idle_cores load_ok mem_ok recent_oom
        read -r load1 _ _ < /proc/loadavg
        free_gb=$(free -g | awk '/Mem:/{print $7}')
        idle_cores=$(awk -v n="${nproc_count}" -v l="${load1}" 'BEGIN{printf "%.1f", n-l}')

        load_ok=0
        awk -v i="${idle_cores}" -v m="${min_idle}" 'BEGIN{exit !(i>m)}' && load_ok=1
        mem_ok=0
        [ "${free_gb}" -gt "${min_mem_gb}" ] && mem_ok=1

        recent_oom=0
        local last_oom_line oom_ts oom_epoch now_epoch
        last_oom_line=$(dmesg -T 2>/dev/null | grep -E "Out of memory|Killed process" | tail -1)
        if [ -n "${last_oom_line}" ]; then
            oom_ts=$(echo "${last_oom_line}" | grep -oE '^\[[A-Za-z]{3} [A-Za-z]{3} +[0-9]+ [0-9:]+ [0-9]{4}\]' | tr -d '[]')
            oom_epoch=$(date -d "${oom_ts}" +%s 2>/dev/null || echo 0)
            now_epoch=$(date +%s)
            if [ "${oom_epoch}" -gt 0 ] && [ $(( now_epoch - oom_epoch )) -lt 900 ]; then
                recent_oom=1
            fi
        fi

        echo "  [resource-gate] $(date '+%H:%M:%S') load1=${load1} idle_cores=${idle_cores} avail_mem=${free_gb}G recent_oom=${recent_oom}"

        if [ "${recent_oom}" -eq 1 ]; then
            echo "    -> recent OOM-killer activity, waiting ${interval}s before next check."
        elif [ "${load_ok}" -eq 1 ] && [ "${mem_ok}" -eq 1 ]; then
            echo "    -> resources OK, proceeding with next run."
            return 0
        else
            echo "    -> resources not ideal (need idle_cores>${min_idle}, avail_mem>${min_mem_gb}G), waiting ${interval}s."
        fi

        sleep "${interval}"
    done
}
