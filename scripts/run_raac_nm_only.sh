#!/usr/bin/env bash
set -euo pipefail
cd /home/yeochan.yoon/caliper-stress-test

# ── 기존 run과 동일한 RUN_ID/RESULTS_DIR 사용 ──────────────────────────────
RUN_ID="20260429_113915_raac_eval"
RESULTS_DIR="/home/yeochan.yoon/caliper-stress-test/results/raac_eval/${RUN_ID}"

# ── Variables ──────────────────────────────────────────────────────────────────
DOTNET_BIN="/home/yeochan.yoon/.dotnet/dotnet"
NM_DLL="/home/yeochan.yoon/nethermind-last/nethermind.dll"
NM_CFG="/home/yeochan.yoon/caliper-stress-test/nethermind-caliper-config/caliper_nethdev_cfg.json"
HEAP_NM=1000000000
NETWORKCONFIG_NM="networkconfig_nethermind_caliper.json"
DEPLOY_NM="deploy_multi_contracts_nm.js"
BENCHCONFIG_RAAC="benchconfig-raac-ddos-filtered.yaml"
DT_BIN="${HOME}/.dotnet/tools/dotnet-trace"
GC_PARSER="/home/yeochan.yoon/caliper-stress-test/gc-collector/publish/NettraceGcParser.dll"
REPLICATIONS=5
export RAAC_AI_URL="http://127.0.0.1:8000"

echo "======================================================================"
echo "RAAC NM-Only Phase | RUN_ID: ${RUN_ID}"
echo "======================================================================"

# ── Helpers ────────────────────────────────────────────────────────────────────
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

run_nm_single() {
    local variant="$1"; local rep="$2"; local benchcfg="$3"
    local label="${variant}_nm_${rep}"
    local run_dir="${RESULTS_DIR}/${label}"; mkdir -p "${run_dir}"
    local data_dir="/home/yeochan.yoon/caliper-stress-test/data_raac_n_${label}_${RUN_ID}"
    local nettrace="${run_dir}/gc_trace.nettrace"
    local raac_log_dir="${run_dir}/raac_logs"; rm -rf "${raac_log_dir}"; mkdir -p "${raac_log_dir}"

    echo ""; echo "────────────────────────────────────────────────────────────────"
    echo "RUN: ${label} | $(date '+%Y-%m-%d %H:%M:%S') | benchcfg=${benchcfg}"
    echo "────────────────────────────────────────────────────────────────"

    pkill -9 -f "nethermind.dll" 2>/dev/null || true
    fuser -k 8545/tcp 8546/tcp 2>/dev/null || true
    sleep 5; rm -rf "${data_dir}"; mkdir -p "${data_dir}"

    export NETHERMIND_LAST_MODE="DISABLED"
    export DOTNET_GCHeapHardLimit="${HEAP_NM}"
    export COMPlus_GCHeapHardLimit="${HEAP_NM}"
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
        unset NETHERMIND_LAST_MODE DOTNET_GCHeapHardLimit COMPlus_GCHeapHardLimit; return 1
    fi
    wait_for_rpc || {
        stop_nm "${pid}"; echo "failed=rpc_timeout" > "${run_dir}/FAILED"
        unset NETHERMIND_LAST_MODE DOTNET_GCHeapHardLimit COMPlus_GCHeapHardLimit; return 1; }

    node "${DEPLOY_NM}" > "${run_dir}/deploy.log" 2>&1
    grep -q "Contract Address:" "${run_dir}/deploy.log" || {
        stop_nm "${pid}"; echo "failed=deploy" > "${run_dir}/FAILED"
        unset NETHERMIND_LAST_MODE DOTNET_GCHeapHardLimit COMPlus_GCHeapHardLimit; return 1; }
    sleep 5

    local dt_pid=""
    [ -f "${DT_BIN}" ] && {
        "${DT_BIN}" collect --process-id "${pid}" \
            --providers "Microsoft-Windows-DotNETRuntime:0x1:5" \
            --output "${nettrace}" > "${run_dir}/dotnet_trace.log" 2>&1 &
        dt_pid=$!; echo "  dotnet-trace PID: ${dt_pid}"; }

    export RAAC_LOG_DIR="${raac_log_dir}"

    echo "  Running Caliper (120s warmup + 300s measure)..."
    timeout 1500 npx caliper launch manager \
        --caliper-workspace ./ --caliper-benchconfig "${benchcfg}" \
        --caliper-networkconfig "${NETWORKCONFIG_NM}" \
        > "${run_dir}/caliper_console.log" 2>&1 || true

    [ -n "${dt_pid}" ] && kill -INT "${dt_pid}" 2>/dev/null || true
    sleep 5; [ -n "${dt_pid}" ] && kill "${dt_pid}" 2>/dev/null || true

    cp caliper.log "${run_dir}/caliper.log" 2>/dev/null || true
    cp report.html "${run_dir}/report.html" 2>/dev/null || true
    stop_nm "${pid}"; rm -rf "${data_dir}"
    unset NETHERMIND_LAST_MODE DOTNET_GCHeapHardLimit COMPlus_GCHeapHardLimit \
          DOTNET_GCHighMemPercent COMPlus_GCHighMemPercent 2>/dev/null || true

    [ -f "${nettrace}" ] && [ -f "${GC_PARSER}" ] && {
        "${DOTNET_BIN}" "${GC_PARSER}" "${nettrace}" 2>/dev/null | tee "${run_dir}/gc_summary.txt" | sed 's/^/    /'
        "${DOTNET_BIN}" "${GC_PARSER}" "${nettrace}" --csv 2>/dev/null | \
            awk -v v="${variant}" -v r="${rep}" -v c="nm" \
            'NR==1{print "variant,run,client,"$0} NR>1{print v","r",nm,"$0}' \
            > "${run_dir}/gc_events.csv"; }

    grep "| measure " "${run_dir}/caliper_console.log" | tail -1 | sed 's/^/  Caliper: /' || true
    echo "  ✓ ${label} complete"
}

# ── Phase 4: RAAC — NM ────────────────────────────────────────────────────────
echo ""; echo "=============================="; echo "PHASE 4: ${REPLICATIONS}×RAAC / NM"; echo "=============================="
for i in $(seq 1 ${REPLICATIONS}); do
    run_nm_single "raac" "${i}" "${BENCHCONFIG_RAAC}" \
        || echo "  WARNING: raac_nm_${i} failed"
    [ "${i}" -lt "${REPLICATIONS}" ] && sleep 15
done

echo ""
echo "======================================================================"
echo "raac_nm COMPLETE — results in ${RESULTS_DIR}"
echo "======================================================================"
