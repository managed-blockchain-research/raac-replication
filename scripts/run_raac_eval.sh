#!/bin/bash
# ============================================================
# RAAC Evaluation — Besu + Nethermind @ 1 GB / 1500 TPS DDoS
#
# Architecture: AI proxy (FastAPI IsolationForest) sits in front
# of the blockchain node. Caliper submits to node directly; the
# mixedAttackRaac.js workload module calls the AI service before
# each tx and drops "reject" responses (RAAC admission control).
#
# Variants (2 × 2 clients × 5 reps = 20 runs):
#   baseline : mixedAttack.js  — all txs reach node (90% normal + 10% attack)
#   raac     : mixedAttackRaac.js — attack txs blocked by AI service
#
# Metrics: Full GC count, Total GC Time, Confirmed TPS, TPR/FPR
# NM TxPool.Size = 8192 (configured in caliper_nethdev_cfg.json override)
# Output: results/raac_eval/<RUN_ID>/
# ============================================================
set -e
cd /home/yeochan.yoon/caliper-stress-test

# ── Binaries ──────────────────────────────────────────────────────────────────
BESU_BIN="/home/yeochan.yoon/besu-source/build/install/besu/bin/besu"
NM_DLL="/home/yeochan.yoon/nethermind-last/nethermind.dll"
DOTNET_BIN="/home/yeochan.yoon/.dotnet/dotnet"
GC_PARSER="/home/yeochan.yoon/caliper-stress-test/gc-collector/publish/NettraceGcParser.dll"
DT_BIN="${HOME}/.dotnet/tools/dotnet-trace"
LOG4J_CONFIG="/home/yeochan.yoon/caliper-stress-test/log4j2-console.xml"
AI_SERVICE_DIR="/home/yeochan.yoon/banning/ai_service"

# ── Caliper config ────────────────────────────────────────────────────────────
BENCHCONFIG_BASELINE="benchconfig-raac-ddos.yaml"
BENCHCONFIG_RAAC="benchconfig-raac-ddos-filtered.yaml"
NETWORKCONFIG_BESU="networkconfig.json"
NETWORKCONFIG_NM="networkconfig_nethermind_caliper.json"
DEPLOY_BESU="deploy_multi_contracts.py"
DEPLOY_NM="deploy_multi_contracts_nm.js"
NM_CFG="/home/yeochan.yoon/caliper-stress-test/nethermind-caliper-config/caliper_nethdev_cfg.json"

# ── Parameters ────────────────────────────────────────────────────────────────
HEAP_BESU="1g"
HEAP_NM=1000000000
REPLICATIONS=5
LASS75_OPTS="-Dlass.old.gen.activation.threshold=2.0"  # LASS disabled for RAAC eval
AI_URL="http://127.0.0.1:8000"

export DOTNET_ROOT="/home/yeochan.yoon/.dotnet"
export PATH="${DOTNET_ROOT}:${PATH}:${HOME}/.dotnet/tools"

# ── Output directory ──────────────────────────────────────────────────────────
RUN_ID=$(date +%Y%m%d_%H%M%S)_raac_eval
RESULTS_DIR="/home/yeochan.yoon/caliper-stress-test/results/raac_eval/${RUN_ID}"
mkdir -p "${RESULTS_DIR}"

echo "======================================================================"
echo "RAAC Evaluation | 1500 TPS | 1 GB | 5 reps | Besu + NM"
echo "Run ID: ${RUN_ID}"
echo "======================================================================"

# ── AI Service ────────────────────────────────────────────────────────────────
AI_PID=""
start_ai_service() {
    echo "Starting RAAC AI service on port 8000..."
    pkill -f "uvicorn.*main:app" 2>/dev/null || true
    sleep 2
    cd "${AI_SERVICE_DIR}"
    nohup python3 -m uvicorn main:app --host 127.0.0.1 --port 8000 \
        > "${RESULTS_DIR}/ai_service.log" 2>&1 &
    AI_PID=$!
    cd /home/yeochan.yoon/caliper-stress-test

    # Wait for AI service ready
    local count=0
    while [ ${count} -lt 30 ]; do
        if curl -s --max-time 2 http://127.0.0.1:8000/predict \
            -X POST -H "Content-Type: application/json" \
            -d '{"tx_hash":"probe","gas_price":50,"gas_limit":21000,"wei_value":1000000000000000000,"bytecode_size":0,"opcode_count":10,"call_depth":0,"sstore_count":0}' \
            > /dev/null 2>&1; then
            echo "  AI service ready (PID ${AI_PID})"
            export RAAC_AI_URL="${AI_URL}"
            return 0
        fi
        sleep 1; count=$((count+1))
    done
    echo "  WARNING: AI service did not respond — RAAC runs will fail-open"
}

stop_ai_service() {
    [ -n "${AI_PID}" ] && kill "${AI_PID}" 2>/dev/null || true
    pkill -f "uvicorn.*main:app" 2>/dev/null || true
}

# ── Helpers ───────────────────────────────────────────────────────────────────
wait_for_rpc() {
    local port="${1:-8545}"
    local max=120; local c=0
    echo -n "  Waiting for RPC"
    while [ $c -lt $max ]; do
        curl -s --max-time 2 -X POST -H "Content-Type: application/json" \
            --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
            http://localhost:${port} > /dev/null 2>&1 && echo " READY" && return 0
        echo -n "."; sleep 1; c=$((c+1))
    done
    echo " TIMEOUT"; return 1
}

stop_besu() {
    local pid="$1"
    kill "${pid}" 2>/dev/null || true
    local w=0; while kill -0 "${pid}" 2>/dev/null && [ $w -lt 30 ]; do sleep 1; w=$((w+1)); done
    kill -9 "${pid}" 2>/dev/null || true
    pkill -9 -f "hyperledger.besu.Besu" 2>/dev/null || true
    fuser -k 8545/tcp 8546/tcp 30303/tcp 2>/dev/null || true
    sleep 5
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

# run_besu_single VARIANT REP BENCHCONFIG
run_besu_single() {
    local variant="$1"; local rep="$2"; local benchcfg="$3"
    local label="${variant}_besu_${rep}"
    local run_dir="${RESULTS_DIR}/${label}"; mkdir -p "${run_dir}"
    local data_dir="/home/yeochan.yoon/caliper-stress-test/data_raac_b_${label}_${RUN_ID}"
    local gc_log="${run_dir}/gc_besu.log"
    local raac_log_dir="${run_dir}/raac_logs"; mkdir -p "${raac_log_dir}"

    echo ""; echo "────────────────────────────────────────────────────────────────"
    echo "RUN: ${label} | $(date '+%Y-%m-%d %H:%M:%S') | benchcfg=${benchcfg}"
    echo "────────────────────────────────────────────────────────────────"

    pkill -9 -f "hyperledger.besu.Besu" 2>/dev/null || true
    fuser -k 8545/tcp 8546/tcp 30303/tcp 2>/dev/null || true
    sleep 5; rm -rf "${data_dir}"; mkdir -p "${data_dir}"

    local java_opts="-Xms${HEAP_BESU} -Xmx${HEAP_BESU} \
-XX:+UseG1GC -XX:MaxGCPauseMillis=200 -XX:G1HeapWastePercent=5 \
-Xlog:gc*=info:file=${gc_log}:time,uptime,level,tags:filecount=5,filesize=100M \
-Dlog4j.configurationFile=${LOG4J_CONFIG} \
-Dlast.variant=DISABLED ${LASS75_OPTS}"
    export BESU_OPTS="${java_opts}"

    nohup "${BESU_BIN}" --network=dev --miner-enabled \
        --miner-coinbase=0xfe3b557e8fb62b89f4916b721be55ceb828dbd73 \
        --data-path="${data_dir}" --rpc-http-enabled --rpc-http-port=8545 \
        --rpc-http-host=0.0.0.0 --rpc-http-cors-origins="*" \
        --rpc-ws-enabled --rpc-ws-port=8546 --rpc-ws-max-active-connections=200 \
        --rpc-http-max-active-connections=200 \
        --host-allowlist="*" --min-gas-price=0 \
        --tx-pool-layer-max-capacity=1000000 --tx-pool-max-prioritized=1000000 \
        --tx-pool-max-future-by-sender=100000 \
        > "${run_dir}/besu_console.log" 2>&1 &
    local pid=$!; echo "  Besu PID: ${pid}"

    sleep 8
    if ! kill -0 ${pid} 2>/dev/null; then
        echo "failed=startup" > "${run_dir}/FAILED"; return 1
    fi
    wait_for_rpc || { stop_besu "${pid}"; echo "failed=rpc_timeout" > "${run_dir}/FAILED"; return 1; }

    python3 "${DEPLOY_BESU}" > "${run_dir}/deploy.log" 2>&1
    grep -q "Contract Address:" "${run_dir}/deploy.log" || {
        stop_besu "${pid}"; echo "failed=deploy" > "${run_dir}/FAILED"; return 1; }
    sleep 3

    # Export log dir for workload module
    export RAAC_LOG_DIR="${raac_log_dir}"

    echo "  Running Caliper (120s warmup + 300s measure @ 1500 TPS)..."
    timeout 1500 npx caliper launch manager \
        --caliper-workspace ./ --caliper-benchconfig "${benchcfg}" \
        --caliper-networkconfig "${NETWORKCONFIG_BESU}" \
        > "${run_dir}/caliper_console.log" 2>&1 || true

    cp caliper.log "${run_dir}/caliper.log" 2>/dev/null || true
    cp report.html "${run_dir}/report.html" 2>/dev/null || true
    stop_besu "${pid}"; rm -rf "${data_dir}"

    # Quick GC summary
    [ -f "${gc_log}" ] && {
        full_count=$(grep -c "Pause Full" "${gc_log}" 2>/dev/null || echo 0)
        young_count=$(grep -c "Pause Young" "${gc_log}" 2>/dev/null || echo 0)
        mixed_count=$(grep -c "Pause Mixed" "${gc_log}" 2>/dev/null || echo 0)
        echo "  GC: Young=${young_count} Mixed=${mixed_count} Full=${full_count}"; }
    grep "| measure " "${run_dir}/caliper_console.log" | tail -1 | sed 's/^/  Caliper: /' || true
    echo "  ✓ ${label} complete"
}

# run_nm_single VARIANT REP BENCHCONFIG
run_nm_single() {
    local variant="$1"; local rep="$2"; local benchcfg="$3"
    local label="${variant}_nm_${rep}"
    local run_dir="${RESULTS_DIR}/${label}"; mkdir -p "${run_dir}"
    local data_dir="/home/yeochan.yoon/caliper-stress-test/data_raac_n_${label}_${RUN_ID}"
    local nettrace="${run_dir}/gc_trace.nettrace"
    local raac_log_dir="${run_dir}/raac_logs"; mkdir -p "${raac_log_dir}"

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

    # TxPool.Size 8192 exceeds 1 GB MemoryHintMan budget; use 4096 (config default)
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

    # dotnet-trace GC collection
    local dt_pid=""
    [ -f "${DT_BIN}" ] && {
        "${DT_BIN}" collect --process-id "${pid}" \
            --providers "Microsoft-Windows-DotNETRuntime:0x1:5" \
            --output "${nettrace}" > "${run_dir}/dotnet_trace.log" 2>&1 &
        dt_pid=$!; echo "  dotnet-trace PID: ${dt_pid}"; }

    export RAAC_LOG_DIR="${raac_log_dir}"

    echo "  Running Caliper (120s warmup + 300s measure @ 1500 TPS)..."
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

    # Parse nettrace
    [ -f "${nettrace}" ] && [ -f "${GC_PARSER}" ] && {
        "${DOTNET_BIN}" "${GC_PARSER}" "${nettrace}" 2>/dev/null | tee "${run_dir}/gc_summary.txt" | sed 's/^/    /'
        "${DOTNET_BIN}" "${GC_PARSER}" "${nettrace}" --csv 2>/dev/null | \
            awk -v v="${variant}" -v r="${rep}" -v c="nm" \
            'NR==1{print "variant,run,client,"$0} NR>1{print v","r",nm,"$0}' \
            > "${run_dir}/gc_events.csv"; }

    grep "| measure " "${run_dir}/caliper_console.log" | tail -1 | sed 's/^/  Caliper: /' || true
    echo "  ✓ ${label} complete"
}

# ── Provenance ────────────────────────────────────────────────────────────────
BESU_COMMIT=$(cd /home/yeochan.yoon/besu-source && git log --oneline -1 2>/dev/null || echo "unknown")
cat > "${RESULTS_DIR}/provenance.txt" <<EOF
RAAC Evaluation — Besu + NM / 1 GB / 1500 TPS
================================================
Run ID: ${RUN_ID} | Date: $(date) | Host: $(hostname)
Besu:   ${BESU_BIN} (${BESU_COMMIT})
NM:     ${NM_DLL}
AI:     ${AI_SERVICE_DIR}/main.py (IsolationForest, port 8000)
Heap:   Besu -Xmx1g | NM GCHeapHardLimit=1000000000
NM TxPool.Size: 4096
Load:   1500 TPS, 120s warmup + 300s measure, 30 workers
Mix:    90% normal (1-SSTORE) + 10% attack (200-SSTORE)
Variants:
  baseline : all txs reach node (no AI filter)
  raac     : attack txs blocked by AI service pre-filter (TPR~100%, FPR~0%)
EOF

# ── Pre-flight ────────────────────────────────────────────────────────────────
pkill -9 -f "hyperledger.besu.Besu" 2>/dev/null || true
pkill -9 -f "nethermind.dll" 2>/dev/null || true
fuser -k 8545/tcp 8546/tcp 30303/tcp 2>/dev/null || true
sleep 3

# Start AI service (needed for RAAC runs; baseline runs don't use it but harmless)
start_ai_service

# ── Phase 1: Baseline — Besu ──────────────────────────────────────────────────
echo ""; echo "=============================="; echo "PHASE 1: ${REPLICATIONS}×BASELINE / BESU"; echo "=============================="
for i in $(seq 1 ${REPLICATIONS}); do
    run_besu_single "baseline" "${i}" "${BENCHCONFIG_BASELINE}" \
        || echo "  WARNING: baseline_besu_${i} failed"
    [ "${i}" -lt "${REPLICATIONS}" ] && sleep 30
done

# ── Phase 2: Baseline — NM ────────────────────────────────────────────────────
echo ""; echo "=============================="; echo "PHASE 2: ${REPLICATIONS}×BASELINE / NM"; echo "=============================="
for i in $(seq 1 ${REPLICATIONS}); do
    run_nm_single "baseline" "${i}" "${BENCHCONFIG_BASELINE}" \
        || echo "  WARNING: baseline_nm_${i} failed"
    [ "${i}" -lt "${REPLICATIONS}" ] && sleep 30
done

# ── Phase 3: RAAC — Besu ─────────────────────────────────────────────────────
echo ""; echo "=============================="; echo "PHASE 3: ${REPLICATIONS}×RAAC / BESU"; echo "=============================="
for i in $(seq 1 ${REPLICATIONS}); do
    run_besu_single "raac" "${i}" "${BENCHCONFIG_RAAC}" \
        || echo "  WARNING: raac_besu_${i} failed"
    [ "${i}" -lt "${REPLICATIONS}" ] && sleep 30
done

# ── Phase 4: RAAC — NM ───────────────────────────────────────────────────────
echo ""; echo "=============================="; echo "PHASE 4: ${REPLICATIONS}×RAAC / NM"; echo "=============================="
for i in $(seq 1 ${REPLICATIONS}); do
    run_nm_single "raac" "${i}" "${BENCHCONFIG_RAAC}" \
        || echo "  WARNING: raac_nm_${i} failed"
    [ "${i}" -lt "${REPLICATIONS}" ] && sleep 30
done

stop_ai_service

# ── Parse results ─────────────────────────────────────────────────────────────
echo ""; echo "=============================="; echo "PARSING RESULTS"; echo "=============================="
python3 scripts/parse_besu_gc.py --results-dir "${RESULTS_DIR}" \
    --out-csv "${RESULTS_DIR}/besu_gc_events.csv" \
    > "${RESULTS_DIR}/gc_summary.md" 2>/dev/null && \
    echo "GC summary → ${RESULTS_DIR}/gc_summary.md"

python3 scripts/parse_raac_results.py --results-dir "${RESULTS_DIR}" \
    > "${RESULTS_DIR}/raac_summary.md" 2>/dev/null && \
    echo "RAAC summary → ${RESULTS_DIR}/raac_summary.md"

echo ""; echo "======================================================================"
echo "RAAC Evaluation complete. Results: ${RESULTS_DIR}"
echo "======================================================================"
