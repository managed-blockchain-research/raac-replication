#!/usr/bin/env bash
# RAAC Besu eval13 — static/moderate/aggressive × n=3 (interleaved)
# Pressure signal: G1GC heap occupancy from -Xlog:gc* (v6 serve.py gclog mode).
# Heap=1g so attack txs (96KB calldata) drive meaningful heap occupancy rise.
# GC metric: total STW pause time from -Xlog:gc* log, parsed by parse_besu_gc.py.
#
# OCCU thresholds (heap_after/heap_max from G1GC XM->YM(ZM) lines):
#   Calm heap_after ≈ 6-7% (60-70M / 1024M); attack heap_after ≈ 28-33%.
#   OCCU_LOW=0.10  (no pressure when heap_after < 10%)
#   moderate:   OCCU_HIGH=0.25  (full pressure when heap_after >= 25%)
#   aggressive: OCCU_HIGH=0.20  (full pressure when heap_after >= 20%)
#   Attack score ~0.8952; blocking starts at pressure > 0.219 →
#     moderate:   heap_after > 14.5% ≈ 148MB  (well within attack range 28-33%)
#     aggressive: heap_after > 12.2% ≈ 125MB  (reached almost immediately in attack)
set -euo pipefail
cd /home/yeochan.yoon/caliper-stress-test

RUN_ID="$(date +%Y%m%d_%H%M%S)_raac_besu_eval13"
RESULTS_DIR="/home/yeochan.yoon/caliper-stress-test/results/raac_eval/${RUN_ID}"
LOG_FILE="/home/yeochan.yoon/caliper-stress-test/raac_besu_eval13_run.log"

BESU_BIN="/home/yeochan.yoon/besu-source/build/install/besu/bin/besu"
LOG4J_CONFIG="/home/yeochan.yoon/caliper-stress-test/log4j2-console.xml"
HEAP_BESU="1g"
NETWORKCONFIG_BESU="networkconfig.json"
DEPLOY_BESU="deploy_multi_contracts.py"
BENCHCONFIG_RAAC="benchconfig-raac-burst-dynamic.yaml"
GC_PARSER="scripts/parse_besu_gc.py"
AI_SERVICE_DIR="/home/yeochan.yoon/banning/ai_service"
export RAAC_AI_URL="http://127.0.0.1:8000"

mkdir -p "${RESULTS_DIR}"
exec > >(tee -a "${LOG_FILE}") 2>&1

echo ""
echo "======================================================================"
echo "RAAC Besu eval13 | static/moderate/aggressive × n=3 | RUN_ID: ${RUN_ID}"
echo "  Heap=${HEAP_BESU}, TxPool=2048, interleaved s1→m1→a1→...→s3→m3→a3"
echo "  Pressure: G1GC heap occupancy (serve.py v6 gclog mode)"
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

stop_besu() {
    local pid="$1"
    kill "${pid}" 2>/dev/null || true
    local w=0; while kill -0 "${pid}" 2>/dev/null && [ $w -lt 30 ]; do sleep 1; w=$((w+1)); done
    kill -9 "${pid}" 2>/dev/null || true
    pkill -9 -f "hyperledger.besu.Besu" 2>/dev/null || true
    fuser -k 8545/tcp 8546/tcp 30303/tcp 2>/dev/null || true
    sleep 5
}

# args: base_thr min_thr occu_high gc_log_path
restart_ai_service_with_config() {
    local base_thr="$1" min_thr="$2" occu_high="$3" gc_log_path="$4"
    pkill -f "serve\.py" 2>/dev/null || true
    sleep 2
    cd "${AI_SERVICE_DIR}"
    OMP_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 MKL_NUM_THREADS=1 NUMEXPR_NUM_THREADS=1 \
    AI_THRESHOLD_BASE="${base_thr}" AI_THRESHOLD_MIN="${min_thr}" \
    AI_GC_LOG_PATH="${gc_log_path}" AI_GC_OCCU_LOW="0.10" AI_GC_OCCU_HIGH="${occu_high}" \
    nohup python3 serve.py > /tmp/serve_ai.log 2>&1 &
    echo "  AI service (re)started: base=${base_thr} min=${min_thr} occu_high=${occu_high} gc_log=${gc_log_path} (PID $!)"
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
    local label="${config}_besu_${rep}"
    local run_dir="${RESULTS_DIR}/${label}"; mkdir -p "${run_dir}"
    local data_dir="/home/yeochan.yoon/caliper-stress-test/data_n_${label}_${RUN_ID}"
    local gc_log="${run_dir}/gc_besu.log"

    echo ""; echo "────────────────────────────────────────────────────────────────"
    echo "RUN: ${label} | $(date '+%Y-%m-%d %H:%M:%S')"
    echo "────────────────────────────────────────────────────────────────"

    case "${config}" in
        static)     restart_ai_service_with_config "0.95" "0.95" "0.25" "${gc_log}" ;;
        moderate)   restart_ai_service_with_config "0.95" "0.70" "0.25" "${gc_log}" ;;
        aggressive) restart_ai_service_with_config "0.95" "0.70" "0.20" "${gc_log}" ;;
        *)          echo "Unknown config: ${config}"; return 1 ;;
    esac

    ensure_ai_service || {
        echo "failed=ai_service_down" > "${run_dir}/FAILED"; return 1
    }

    local raac_log_dir="${run_dir}/raac_logs"
    rm -rf "${raac_log_dir}"; mkdir -p "${raac_log_dir}"
    export RAAC_LOG_DIR="${raac_log_dir}"

    pkill -9 -f "hyperledger.besu.Besu" 2>/dev/null || true
    fuser -k 8545/tcp 8546/tcp 30303/tcp 2>/dev/null || true
    sleep 5; rm -rf "${data_dir}"; mkdir -p "${data_dir}"

    local java_opts="-Xms${HEAP_BESU} -Xmx${HEAP_BESU} \
-XX:+UseG1GC -XX:MaxGCPauseMillis=200 \
-Xlog:gc*=info:file=${gc_log}:time,uptime,level,tags:filecount=5,filesize=100M \
-Dlog4j.configurationFile=${LOG4J_CONFIG} \
-Dlast.variant=DISABLED \
-Dlass.old.gen.activation.threshold=2.0"
    export BESU_OPTS="${java_opts}"

    nohup "${BESU_BIN}" \
        --network=dev \
        --miner-enabled \
        --miner-coinbase=0xfe3b557e8fb62b89f4916b721be55ceb828dbd73 \
        --data-path="${data_dir}" \
        --rpc-http-enabled \
        --rpc-http-host=0.0.0.0 \
        --rpc-http-port=8545 \
        --rpc-http-cors-origins="*" \
        --rpc-http-api=ETH,NET,WEB3,DEBUG,ADMIN,TXPOOL \
        --rpc-ws-enabled \
        --rpc-ws-host=0.0.0.0 \
        --rpc-ws-port=8546 \
        --rpc-ws-api=ETH,NET,WEB3,DEBUG,ADMIN,TXPOOL \
        --host-allowlist="*" \
        --min-gas-price=0 \
        --tx-pool-max-prioritized=2048 \
        --tx-pool-layer-max-capacity=2048 \
        --logging=INFO \
        > "${run_dir}/besu_console.log" 2>&1 &
    local pid=$!; echo "  Besu PID: ${pid}"
    unset BESU_OPTS

    sleep 8
    if ! kill -0 ${pid} 2>/dev/null; then
        echo "failed=startup" > "${run_dir}/FAILED"
        unset RAAC_LOG_DIR 2>/dev/null || true; return 1
    fi
    wait_for_rpc || {
        stop_besu "${pid}"; echo "failed=rpc_timeout" > "${run_dir}/FAILED"
        unset RAAC_LOG_DIR 2>/dev/null || true; return 1
    }

    python3 "${DEPLOY_BESU}" > "${run_dir}/deploy.log" 2>&1
    grep -q "Contract Address:" "${run_dir}/deploy.log" || {
        stop_besu "${pid}"; echo "failed=deploy" > "${run_dir}/FAILED"
        unset RAAC_LOG_DIR 2>/dev/null || true; return 1
    }
    sleep 5

    cp /tmp/serve_ai.log "${run_dir}/ai_service_before.log" 2>/dev/null || true

    echo "  Running Caliper (60s warmup + 90+120+90+120+60s burst pattern)..."
    timeout 2400 npx caliper launch manager \
        --caliper-workspace ./ \
        --caliper-benchconfig "${BENCHCONFIG_RAAC}" \
        --caliper-networkconfig "${NETWORKCONFIG_BESU}" \
        > "${run_dir}/caliper_console.log" 2>&1 || true

    cp /tmp/serve_ai.log "${run_dir}/ai_service_after.log" 2>/dev/null || true
    cp caliper.log "${run_dir}/caliper.log" 2>/dev/null || true
    cp report.html "${run_dir}/report.html" 2>/dev/null || true

    stop_besu "${pid}"; rm -rf "${data_dir}"
    unset RAAC_LOG_DIR 2>/dev/null || true

    if [ -f "${gc_log}" ]; then
        gc_out=$(python3 "${GC_PARSER}" \
            --log "${gc_log}" --variant "${config}" --run "${rep}" 2>&1 \
            | grep "total_ms=" | sed 's/.*total_ms=\([0-9.]*\).*/\1/' \
            || echo "parse_error")
        [ -z "${gc_out}" ] && gc_out="no_gc_events"
        echo "${gc_out}" > "${run_dir}/gc_summary.txt"
        echo "  GC: ${gc_out} ms (total STW)"
    else
        echo "  GC: gc_log missing"
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

echo ""
echo "=============================="
echo "Starting eval13: all 9 runs"
echo "=============================="

for i in 1 2 3; do
    run_config "static"     "${i}" || echo "  WARNING: static_besu_${i} failed, continuing"
    sleep 15
    run_config "moderate"   "${i}" || echo "  WARNING: moderate_besu_${i} failed, continuing"
    sleep 15
    run_config "aggressive" "${i}" || echo "  WARNING: aggressive_besu_${i} failed, continuing"
    [ "${i}" -lt 3 ] && sleep 15
done

echo ""
echo "======================================================================"
echo "RAAC Besu eval13 COMPLETE — results in ${RESULTS_DIR}"
echo "======================================================================"
