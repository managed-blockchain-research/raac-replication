#!/usr/bin/env bash
# NM (Nethermind) equivalent of raac_arm_functions.sh — same 6 arms, adapted to
# .NET/Nethermind specifics: RSS-based pressure signal (not GC log), dotnet-trace
# for GC measurement (not -Xlog:gc), TxPool.Size for native eviction (not
# tx-pool-layer-max-capacity byte cap — NM doesn't expose one).
#
# IMPORTANT: NM and Besu share ports 8545/8546 and the AI service port 8000 —
# never run this concurrently with run_raac_full_6arm.sh (Besu). Same rule as
# AGENTS.md item 7.

DOTNET_BIN="/home/yeochan.yoon/.dotnet/dotnet"
# Clique PoA, not NethDev — NethDev has a hard-coded 5-tx/block ceiling that a
# 30-worker/100tps attack burst blows straight through no matter what the
# admission-control policy does (confirmed: 99.98% eth_sendRawTransaction
# failures under static/no-control). XRAY hit the exact same wall and fixed it
# by moving to Clique ("NethDev ceiling is uncontrolled confound") — reusing
# that fix here. HEAP_NM stays at RAAC's own calibrated 4GB (NOT XRAY's 64GB
# production-equivalent heap) since RAAC's whole point is a memory-constrained
# heap that the attack workload can actually pressure.
NM_DLL="/home/yeochan.yoon/nethermind/src/Nethermind/artifacts/bin/Nethermind.Runner/release/nethermind.dll"
CHAINSPEC_NM="/home/yeochan.yoon/banning/raac_clique_nm.json"
SEALER_KEY_NM="/home/yeochan.yoon/banning/experiments/xray/scripts/xray_sealer.key"
HEAP_NM=4000000000
NETWORKCONFIG_NM="networkconfig_nethermind_caliper.json"
DEPLOY_NM="deploy_multi_contracts_nm.js"
BENCHCONFIG_RAAC="benchconfig-raac-burst-dynamic.yaml"
DT_BIN="${HOME}/.dotnet/tools/dotnet-trace"
GC_PARSER_NM="/home/yeochan.yoon/banning/experiments/raac/scripts/parse_gc_nettrace/bin/Release/net10.0/parse_gc_nettrace"
AI_SERVICE_DIR="/home/yeochan.yoon/banning/ai_service"
export RAAC_AI_URL="http://127.0.0.1:8000"

wait_for_rpc_nm() {
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

# args: mode base_thr min_thr delta_low delta_high heap_only_cutoff dagor_cpu_low dagor_cpu_high
restart_ai_service_nm() {
    local mode="$1" base_thr="$2" min_thr="$3" delta_low="$4" delta_high="$5"
    local cutoff="${6:-0.5}" dagor_cpu_low="${7:-100.0}" dagor_cpu_high="${8:-800.0}"
    pkill -f "serve\.py" 2>/dev/null || true
    sleep 2
    cd "${AI_SERVICE_DIR}"
    OMP_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 MKL_NUM_THREADS=1 NUMEXPR_NUM_THREADS=1 \
    AI_MODE="${mode}" AI_HEAP_ONLY_CUTOFF="${cutoff}" \
    AI_THRESHOLD_BASE="${base_thr}" AI_THRESHOLD_MIN="${min_thr}" \
    AI_DELTA_LOW_MB="${delta_low}" AI_DELTA_HIGH_MB="${delta_high}" \
    AI_TARGET_PROCESS_PATTERN="nethermind.dll" \
    AI_DAGOR_CPU_LOW="${dagor_cpu_low}" AI_DAGOR_CPU_HIGH="${dagor_cpu_high}" \
    AI_DAGOR_PROCESS_PATTERN="nethermind.dll" \
    nohup python3 serve.py > /tmp/serve_ai_nm_full6arm.log 2>&1 &
    echo "  AI service (re)started: mode=${mode} base=${base_thr} min=${min_thr} delta=[${delta_low},${delta_high}]MB cutoff=${cutoff} dagor_cpu=[${dagor_cpu_low},${dagor_cpu_high}] (PID $!)"
    sleep 6
    cd /home/yeochan.yoon/caliper-stress-test
}

ensure_ai_service_nm() {
    local c=0
    while [ $c -lt 20 ]; do
        result=$(curl -s --max-time 3 http://127.0.0.1:8000/ 2>/dev/null)
        if echo "${result}" | grep -q '"dynamic_threshold"'; then
            echo "  AI service ready: ${result}"
            return 0
        fi
        sleep 2; c=$((c+1))
    done
    echo "  ERROR: AI service failed to respond after 40s"; return 1
}

# args: config rep
run_config_nm() {
    local config="$1"; local rep="$2"
    local label="${config}_nm_${rep}"
    local run_dir="${RESULTS_DIR}/${label}"; mkdir -p "${run_dir}"
    local data_dir="/home/yeochan.yoon/caliper-stress-test/data_n_${label}_${RUN_ID}"
    local nettrace="${run_dir}/gc_trace.nettrace"
    local txpool_size="4096"

    echo ""; echo "────────────────────────────────────────────────────────────────"
    echo "RUN: ${label} | $(date '+%Y-%m-%d %H:%M:%S')"
    echo "────────────────────────────────────────────────────────────────"

    case "${config}" in
        static)
            restart_ai_service_nm "raac" "0.95" "0.95" "100" "350"
            ;;
        native_evict)
            restart_ai_service_nm "raac" "0.95" "0.95" "100" "350"
            txpool_size="64"
            ;;
        heap_only)
            restart_ai_service_nm "heap_only" "0.95" "0.70" "100" "250" "0.5"
            ;;
        dagor)
            restart_ai_service_nm "dagor" "0.95" "0.70" "100" "350" "0.5" "100" "800"
            ;;
        moderate)
            restart_ai_service_nm "raac" "0.95" "0.70" "100" "350"
            ;;
        aggressive)
            restart_ai_service_nm "raac" "0.95" "0.70" "100" "200"
            ;;
        *)
            echo "Unknown config: ${config}"; return 1 ;;
    esac

    ensure_ai_service_nm || {
        echo "failed=ai_service_down" > "${run_dir}/FAILED"; return 1
    }

    local raac_log_dir="${run_dir}/raac_logs"
    rm -rf "${raac_log_dir}"; mkdir -p "${raac_log_dir}"
    export RAAC_LOG_DIR="${raac_log_dir}"

    pkill -9 -f "nethermind.dll" 2>/dev/null || true
    fuser -k 8545/tcp 8546/tcp 2>/dev/null || true
    sleep 5; rm -rf "${data_dir}"; mkdir -p "${data_dir}"

    # Server GC (not Workstation) — matches XRAY's fix; per-core heaps scale
    # better under the 30-worker concurrent load that was starving NethDev.
    export DOTNET_GCHeapHardLimit="${HEAP_NM}"
    export COMPlus_GCHeapHardLimit="${HEAP_NM}"
    export DOTNET_gcServer=1
    export COMPlus_gcServer=1
    export DOTNET_EnableDiagnostics=1
    unset DOTNET_GCHighMemPercent COMPlus_GCHighMemPercent 2>/dev/null || true

    nohup "${DOTNET_BIN}" "${NM_DLL}" \
        --Init.ChainSpecPath "${CHAINSPEC_NM}" \
        --Init.BaseDbPath "${data_dir}" \
        --Init.EnableUnsecuredDevWallet true \
        --Init.KeepDevWalletInMemory true \
        --Init.DiagnosticMode MemDb \
        --Init.DiscoveryEnabled false \
        --Init.PeerManagerEnabled false \
        --Init.MemoryHint 2000000000 \
        --KeyStore.EnodeKeyFile "${SEALER_KEY_NM}" \
        --Mining.Enabled true \
        --JsonRpc.Enabled true --JsonRpc.Host 0.0.0.0 --JsonRpc.Port 8545 --JsonRpc.Timeout 20000 \
        --JsonRpc.EnabledModules "Eth,Net,Web3,Debug,Admin,TxPool,Clique" \
        --Sync.NetworkingEnabled false --Sync.SynchronizationEnabled false \
        --Network.DiscoveryPort 0 --Network.P2PPort 0 \
        --Blocks.MinGasPrice 0 --Blocks.TargetBlockGasLimit 1000000000 \
        --TxPool.Size "${txpool_size}" --TxPool.BlobsSupport Disabled \
        --Merge.Enabled false \
        > "${run_dir}/nm_console.log" 2>&1 &
    local pid=$!; echo "  NM PID: ${pid}"

    sleep 8
    if ! kill -0 ${pid} 2>/dev/null; then
        echo "failed=startup" > "${run_dir}/FAILED"
        unset DOTNET_GCHeapHardLimit COMPlus_GCHeapHardLimit DOTNET_gcServer COMPlus_gcServer
        unset RAAC_LOG_DIR 2>/dev/null || true; return 1
    fi
    wait_for_rpc_nm || {
        stop_nm "${pid}"; echo "failed=rpc_timeout" > "${run_dir}/FAILED"
        unset DOTNET_GCHeapHardLimit COMPlus_GCHeapHardLimit DOTNET_gcServer COMPlus_gcServer
        unset RAAC_LOG_DIR 2>/dev/null || true; return 1
    }

    node "${DEPLOY_NM}" > "${run_dir}/deploy.log" 2>&1
    grep -q "Contract Address:\|SB0:" "${run_dir}/deploy.log" || {
        stop_nm "${pid}"; echo "failed=deploy" > "${run_dir}/FAILED"
        unset DOTNET_GCHeapHardLimit COMPlus_GCHeapHardLimit DOTNET_gcServer COMPlus_gcServer
        unset RAAC_LOG_DIR 2>/dev/null || true; return 1
    }
    sleep 5

    local dt_pid=""
    [ -f "${DT_BIN}" ] && {
        "${DT_BIN}" collect --process-id "${pid}" --profile gc-collect \
            --output "${nettrace}" > "${run_dir}/dotnet_trace.log" 2>&1 &
        dt_pid=$!; echo "  dotnet-trace PID: ${dt_pid}"
    }

    cp /tmp/serve_ai_nm_full6arm.log "${run_dir}/ai_service_before.log" 2>/dev/null || true

    echo "  Running Caliper (60s warmup + 90+120+90+120+60s burst pattern)..."
    timeout 900 npx caliper launch manager \
        --caliper-workspace ./ --caliper-benchconfig "${BENCHCONFIG_RAAC}" \
        --caliper-networkconfig "${NETWORKCONFIG_NM}" \
        > "${run_dir}/caliper_console.log" 2>&1 || true

    cp /tmp/serve_ai_nm_full6arm.log "${run_dir}/ai_service_after.log" 2>/dev/null || true
    [ -n "${dt_pid}" ] && kill -INT "${dt_pid}" 2>/dev/null || true
    sleep 8; [ -n "${dt_pid}" ] && kill "${dt_pid}" 2>/dev/null || true

    cp caliper.log "${run_dir}/caliper.log" 2>/dev/null || true
    cp report.html "${run_dir}/report.html" 2>/dev/null || true
    : > caliper.log 2>/dev/null || true

    stop_nm "${pid}"; rm -rf "${data_dir}"
    unset DOTNET_GCHeapHardLimit COMPlus_GCHeapHardLimit DOTNET_gcServer COMPlus_gcServer \
          DOTNET_GCHighMemPercent COMPlus_GCHighMemPercent 2>/dev/null || true
    unset RAAC_LOG_DIR 2>/dev/null || true

    if [ -f "${nettrace}" ] && [ -f "${GC_PARSER_NM}" ]; then
        local gc_out
        # tail -1: parse_gc_nettrace prints diagnostic lines then the final
        # numeric summary last (confirmed working pattern from
        # run_raac_eval13_supplement.sh, the script that produced the paper's
        # existing NM numbers).
        gc_out=$("${GC_PARSER_NM}" "${nettrace}" 2>/dev/null | tail -1 || echo "parse_error")
        echo "${gc_out}" > "${run_dir}/gc_summary.txt"
        echo "  GC: ${gc_out}"
    else
        echo "no_gc_events" > "${run_dir}/gc_summary.txt"
        echo "  GC: gc_trace or parser missing"
    fi

    if ls "${raac_log_dir}"/*.jsonl > /dev/null 2>&1; then
        local total rejects
        total=$(cat "${raac_log_dir}"/*.jsonl | wc -l || echo 0)
        rejects=$(grep -h '"ai_action":"reject"' "${raac_log_dir}"/*.jsonl 2>/dev/null | wc -l || echo 0)
        echo "  RAAC total: rejects=${rejects}/${total}"
    fi

    grep "Transaction Info\|Summary" "${run_dir}/caliper_console.log" 2>/dev/null | \
        tail -5 | sed 's/^/  Caliper: /' || true
    echo "  ✓ ${label} complete"
}
