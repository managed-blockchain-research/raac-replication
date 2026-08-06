#!/usr/bin/env bash
# Watches run_all_tonight_now.log for each individual run's completion
# ("  ✓ <label> complete" or a FAILED marker file) and appends a compact
# per-run analysis (round completion, GC summary, guard-failure count) to
# run_by_run_analysis.log, so results can be reported as each run finishes
# instead of waiting for whole phases/the whole chain.
set -uo pipefail
cd /home/yeochan.yoon/caliper-stress-test

MAIN_LOG="run_all_tonight_now.log"
OUT_LOG="run_by_run_analysis.log"
: > "${OUT_LOG}"

seen_count=0

analyze_one() {
    local label="$1"
    local status="$2"   # "complete" or "FAILED:<reason>"
    local run_dir
    run_dir=$(find results/raac_eval -maxdepth 2 -type d -name "${label}" -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)

    {
        echo "----------------------------------------------------------------------"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] RUN: ${label} | status: ${status}"
        if [ -z "${run_dir}" ]; then
            echo "  (run_dir not found)"
        else
            echo "  run_dir: ${run_dir}"
            local cc="${run_dir}/caliper_console.log"
            if [ -f "${cc}" ]; then
                local rounds_finished
                rounds_finished=$(grep -c "Finished round" "${cc}" 2>/dev/null || echo 0)
                echo "  rounds finished: ${rounds_finished}/6"
                grep "Started round\|Finished round" "${cc}" 2>/dev/null | tail -12 | sed 's/^/    /'
                local guard_fails
                guard_fails=$(grep -c "wall-clock deadline\|outer-guard" "${cc}" 2>/dev/null || echo 0)
                echo "  guard failures: ${guard_fails}"
            fi
            local rundir_parent
            rundir_parent=$(dirname "${run_dir}")
            grep -A2 "RUN: ${label}" "${rundir_parent}"/*.log 2>/dev/null | grep -E "GC:|RAAC total" | tail -3 | sed 's/^/    /'
            if [ -f "${run_dir}/FAILED" ]; then
                echo "  FAILED marker: $(cat "${run_dir}/FAILED")"
            fi
        fi
        echo ""
    } >> "${OUT_LOG}"
}

while true; do
    if [ -f "${MAIN_LOG}" ]; then
        # New completions since last check
        mapfile -t new_completes < <(grep -oP '(?<=  ✓ )\S+(?= complete)' "${MAIN_LOG}" 2>/dev/null | tail -n +$((seen_count + 1)))
        for label in "${new_completes[@]}"; do
            analyze_one "${label}" "complete"
            seen_count=$((seen_count + 1))
        done
    fi
    sleep 30
done
