#!/usr/bin/env bash
# RAAC NM eval13 — Within-run threshold comparison
# 3 configs × n=3 runs = 9 total, interleaved order
# Fix applied: normal tx uses sink(1KB) — zero state changes, no Merkle trie growth
#
# Configs (all use RAAC AI; differ only in threshold adaptation behavior):
#   static:     THRESHOLD_BASE=THRESHOLD_MIN=0.95 → never adapts → attacks always pass
#   moderate:   base=0.95 min=0.70 delta_high=350MB → adapts at full pressure
#   aggressive: base=0.95 min=0.70 delta_high=200MB → adapts faster
set -euo pipefail
cd /home/yeochan.yoon/caliper-stress-test

RUN_ID="$(date +%Y%m%d_%H%M%S)_raac_nm_eval13"
RESULTS_DIR="/home/yeochan.yoon/caliper-stress-test/results/raac_eval/${RUN_ID}"
LOG_FILE="/home/yeochan.yoon/caliper-stress-test/raac_eval13_run.log"

DOTNET_BIN="/home/yeochan.yoon/.dotnet/dotnet"
NM_DLL="/home/yeochan.yoon/nethermind-last/nethermind.dll"
NM_CFG="/home/yeochan.yoon/caliper-stress-test/nethermind-caliper-config/caliper_nethdev_cfg.json"
HEAP_NM=4000000000
NETWORKCONFIG_NM="networkconfig_nethermind_caliper.json"
DEPLOY_NM="deploy_multi_contracts_nm.js"
BENCHCONFIG_RAAC="benchconfig-raac-burst-dynamic.yaml"
DT_BIN="${HOME}/.dotnet/tools/dotnet-trace"
GC_PARSER="/home/yeochan.yoon/banning/experiments/raac/scripts/parse_gc_nettrace/bin/Release/net10.0/parse_gc_nettrace"
AI_SERVICE_DIR="/home/yeochan.yoon/banning/ai_service"
export RAAC_AI_URL="http://127.0.0.1:8000"

mkdir -p "${RESULTS_DIR}"
exec > >(tee -a "${LOG_FILE}") 2>&1

echo "======================================================================"
echo "RAAC NM eval13 (3-config within-run comparison) | RUN_ID: ${RUN_ID}"
echo "  static:     threshold fixed 0.95 — attacks always pass (no GC relief)"
echo "  moderate:   threshold 0.95→0.70, delta_high=350MB"
echo "  aggressive: threshold 0.95→0.70, delta_high=200MB (faster response)"
echo "======================================================================"

wait_for_rpc() {
    local port="${1:-8545}"; local max=120; local c=0
    echo -n "  Waiting for RPC"
    while [ $c -lt $max ]; do
        curl -s --max-time 2 -X POST -H "Content-Type: application/json" \
            --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
            http://localhost:${port} > /dev/null 2>&1 && echo " READY" && return 0
        echo -n "."; sleep 1; c=$((c+1))
    done
    echo " TIMEOUT"; return 1
}

stop_nm() {
    local pid="$1"
    kill "${pid}" 2>/dev/null || true
    local w=0; while kill -0 "${pid}" 2>/dev/null && [ $w -lt 30 ]; do sleep 1; w=$((w+1)); done
    kill -9 "${pid}" 2>/dev/null || true
    pkill -9 -f "nethermind.dll" 2>/dev/null || true
    fuser -k 8545/tcp 8546/tcp 2>/dev/null || true
    sleep 5
}

restart_ai_service_with_config() {
    local base_thr="$1" min_thr="$2" delta_high="$3"
    pkill -f "serve\.py" 2>/dev/null || true
    sleep 2
    cd "${AI_SERVICE_DIR}"
    OMP_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 MKL_NUM_THREADS=1 NUMEXPR_NUM_THREADS=1 \
    AI_THRESHOLD_BASE="${base_thr}" AI_THRESHOLD_MIN="${min_thr}" AI_DELTA_HIGH_MB="${delta_high}" \
    nohup python3 serve.py > /tmp/serve_ai.log 2>&1 &
    echo "  AI service (re)started: base=${base_thr} min=${min_thr} delta_high=${delta_high}MB (PID $!)"
    sleep 6
    cd /home/yeochan.yoon/caliper-stress-test
}

ensure_ai_service() {
    local c=0
    while [ $c -lt 20 ]; do
        result=$(curl -s --max-time 3 http://127.0.0.1:8000/ 2>/dev/null)
        if echo "${result}" | grep -q '"dynamic_threshold"'; then
            dyn=$(echo "${result}" | python3 -c \
                "import sys,json; d=json.load(sys.stdin); print(f'threshold={d[\"dynamic_threshold\"]} pressure={d[\"gc_pressure\"]}')" \
                2>/dev/null || echo "ok")
            echo "  AI service ready: ${dyn}"
            return 0
        fi
        sleep 2; c=$((c+1))
    done
    echo "  ERROR: AI service failed to respond after 40s"; return 1
}

run_config() {
    local config="$1"; local rep="$2"
    local label="${config}_nm_${rep}"
    local run_dir="${RESULTS_DIR}/${label}"; mkdir -p "${run_dir}"
    local data_dir="/home/yeochan.yoon/caliper-stress-test/data_n_${label}_${RUN_ID}"
    local nettrace="${run_dir}/gc_trace.nettrace"

    echo ""; echo "────────────────────────────────────────────────────────────────"
    echo "RUN: ${label} | $(date '+%Y-%m-%d %H:%M:%S')"
    echo "────────────────────────────────────────────────────────────────"

    case "${config}" in
        static)     restart_ai_service_with_config "0.95" "0.95" "350" ;;
        moderate)   restart_ai_service_with_config "0.95" "0.70" "350" ;;
        aggressive) restart_ai_service_with_config "0.95" "0.70" "200" ;;
        *)          echo "Unknown config: ${config}"; return 1 ;;
    esac

    ensure_ai_service || {
        echo "failed=ai_service_down" > "${run_dir}/FAILED"; return 1
    }

    local raac_log_dir="${run_dir}/raac_logs"
    rm -rf "${raac_log_dir}"; mkdir -p "${raac_log_dir}"
    export RAAC_LOG_DIR="${raac_log_dir}"

    pkill -9 -f "nethermind.dll" 2>/dev/null || true
    fuser -k 8545/tcp 8546/tcp 2>/dev/null || true
    sleep 5; rm -rf "${data_dir}"; mkdir -p "${data_dir}"

    export NETHERMIND_LAST_MODE="DISABLED"
    export DOTNET_GCHeapHardLimit="${HEAP_NM}"
    export COMPlus_GCHeapHardLimit="${HEAP_NM}"
    export COMPlus_GCServer=0
    export DOTNET_GCServer=0
    export DOTNET_EnableDiagnostics=1
    unset DOTNET_GCHighMemPercent COMPlus_GCHighMemPercent 2>/dev/null || true

    nohup "${DOTNET_BIN}" "${NM_DLL}" --config "${NM_CFG}" \
        --Init.BaseDbPath "${data_dir}" \
        --Blocks.MinGasPrice 0 \
        --TxPool.Size 4096 \
        > "${run_dir}/nm_console.log" 2>&1 &
    local pid=$!; echo "  NM PID: ${pid}"

    sleep 8
    if ! kill -0 ${pid} 2>/dev/null; then
        echo "failed=startup" > "${run_dir}/FAILED"
        unset NETHERMIND_LAST_MODE DOTNET_GCHeapHardLimit COMPlus_GCHeapHardLimit \
              COMPlus_GCServer DOTNET_GCServer
        unset RAAC_LOG_DIR 2>/dev/null || true
        return 1
    fi
    wait_for_rpc || {
        stop_nm "${pid}"; echo "failed=rpc_timeout" > "${run_dir}/FAILED"
        unset NETHERMIND_LAST_MODE DOTNET_GCHeapHardLimit COMPlus_GCHeapHardLimit \
              COMPlus_GCServer DOTNET_GCServer
        unset RAAC_LOG_DIR 2>/dev/null || true
        return 1
    }

    node "${DEPLOY_NM}" > "${run_dir}/deploy.log" 2>&1
    grep -q "Contract Address:\|SB0:" "${run_dir}/deploy.log" || {
        stop_nm "${pid}"; echo "failed=deploy" > "${run_dir}/FAILED"
        unset NETHERMIND_LAST_MODE DOTNET_GCHeapHardLimit COMPlus_GCHeapHardLimit \
              COMPlus_GCServer DOTNET_GCServer
        unset RAAC_LOG_DIR 2>/dev/null || true
        return 1
    }
    sleep 5

    local dt_pid=""
    [ -f "${DT_BIN}" ] && {
        "${DT_BIN}" collect --process-id "${pid}" \
            --profile gc-collect \
            --output "${nettrace}" > "${run_dir}/dotnet_trace.log" 2>&1 &
        dt_pid=$!; echo "  dotnet-trace PID: ${dt_pid}"
    }

    cp /tmp/serve_ai.log "${run_dir}/ai_service_before.log" 2>/dev/null || true

    echo "  Running Caliper (60s warmup + 90+120+90+120+60s burst pattern)..."
    timeout 2400 npx caliper launch manager \
        --caliper-workspace ./ --caliper-benchconfig "${BENCHCONFIG_RAAC}" \
        --caliper-networkconfig "${NETWORKCONFIG_NM}" \
        > "${run_dir}/caliper_console.log" 2>&1 || true

    cp /tmp/serve_ai.log "${run_dir}/ai_service_after.log" 2>/dev/null || true

    [ -n "${dt_pid}" ] && kill -INT "${dt_pid}" 2>/dev/null || true
    sleep 8; [ -n "${dt_pid}" ] && kill "${dt_pid}" 2>/dev/null || true

    cp caliper.log "${run_dir}/caliper.log" 2>/dev/null || true
    cp report.html "${run_dir}/report.html" 2>/dev/null || true
    stop_nm "${pid}"; rm -rf "${data_dir}"
    unset NETHERMIND_LAST_MODE DOTNET_GCHeapHardLimit COMPlus_GCHeapHardLimit \
          COMPlus_GCServer DOTNET_GCServer \
          DOTNET_GCHighMemPercent COMPlus_GCHighMemPercent 2>/dev/null || true

    if [ -f "${nettrace}" ] && [ -f "${GC_PARSER}" ]; then
        local gc_out
        gc_out=$("${GC_PARSER}" "${nettrace}" 2>/dev/null || echo "parse_error")
        echo "${gc_out}" > "${run_dir}/gc_summary.txt"
        echo "  GC: ${gc_out}"
    fi

    if ls "${raac_log_dir}"/*.jsonl > /dev/null 2>&1; then
        local total rejects
        total=$(cat "${raac_log_dir}"/*.jsonl | wc -l || echo 0)
        rejects=$(grep -h '"ai_action":"reject"' "${raac_log_dir}"/*.jsonl 2>/dev/null | wc -l || echo 0)
        echo "  RAAC total: rejects=${rejects}/${total}"
    fi
    unset RAAC_LOG_DIR 2>/dev/null || true

    grep "Transaction Info\|Summary" "${run_dir}/caliper_console.log" 2>/dev/null | \
        tail -5 | sed 's/^/  Caliper: /' || true
    echo "  ✓ ${label} complete"
}

echo ""
echo "=============================="
echo "Starting eval13: 3 configs × 3 reps = 9 runs (interleaved)"
echo "=============================="

for i in 1 2 3; do
    run_config "static"     "${i}" || echo "  WARNING: static_nm_${i} failed, continuing"
    sleep 15
    run_config "moderate"   "${i}" || echo "  WARNING: moderate_nm_${i} failed, continuing"
    sleep 15
    run_config "aggressive" "${i}" || echo "  WARNING: aggressive_nm_${i} failed, continuing"
    [ "${i}" -lt 3 ] && sleep 15
done

echo ""
echo "======================================================================"
echo "eval13 COMPLETE — results in ${RESULTS_DIR}"
echo "======================================================================"
