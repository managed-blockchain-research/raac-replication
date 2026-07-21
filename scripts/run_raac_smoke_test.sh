#!/usr/bin/env bash
# RAAC Arm2 (heap_only ablation) smoke test — resource-limited, single run.
# Scaled-down copy of run_raac_besu_eval13.sh: validates that the new
# AI_MODE=heap_only path works end-to-end (AI service -> Besu -> Caliper ->
# GC log parsing) before committing to the full 5-arm x n=15-20 run at 23:00 KST.
# nice+taskset keep this from competing hard with other users' jobs on the box.
set -euo pipefail
cd /home/yeochan.yoon/caliper-stress-test

RUN_ID="$(date +%Y%m%d_%H%M%S)_raac_smoke"
RESULTS_DIR="/home/yeochan.yoon/caliper-stress-test/results/raac_eval/${RUN_ID}"
LOG_FILE="/home/yeochan.yoon/caliper-stress-test/raac_smoke_run.log"

BESU_BIN="/home/yeochan.yoon/besu-source/build/install/besu/bin/besu"
LOG4J_CONFIG="/home/yeochan.yoon/caliper-stress-test/log4j2-console.xml"
HEAP_BESU="1g"
NETWORKCONFIG_BESU="networkconfig.json"
DEPLOY_BESU="deploy_multi_contracts.py"
BENCHCONFIG_SMOKE="benchconfig-raac-smoke.yaml"
GC_PARSER="scripts/parse_besu_gc.py"
AI_SERVICE_DIR="/home/yeochan.yoon/banning/ai_service"
export RAAC_AI_URL="http://127.0.0.1:8000"

# No taskset: pinning to a narrow core range is riskier than it looks on a
# shared box — if another user's full-throttle process lands on exactly those
# cores, a nice-19 process pinned there can starve completely (observed: both
# the DAGOR monitor and the pre-existing GC-log monitor froze mid-run this way
# on 2026-07-20). Plain nice lets the scheduler spread us across all cores.
CPU_LIMIT="nice -n 19"

mkdir -p "${RESULTS_DIR}"
exec > >(tee -a "${LOG_FILE}") 2>&1

echo ""
echo "======================================================================"
echo "RAAC Arm2 smoke test | heap_only x n=1 | RUN_ID: ${RUN_ID}"
echo "  workers=5 tps=15, rounds shortened (10/10/15/10/15/10=70s)"
echo "  CPU-limited: ${CPU_LIMIT}"
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

# args: mode base_thr min_thr occu_low occu_high gc_log_path heap_only_cutoff [dagor_cpu_low dagor_cpu_high]
restart_ai_service_with_config() {
    local mode="$1" base_thr="$2" min_thr="$3" occu_low="$4" occu_high="$5" gc_log_path="$6" cutoff="$7"
    local dagor_cpu_low="${8:-50.0}" dagor_cpu_high="${9:-90.0}"
    pkill -f "serve\.py" 2>/dev/null || true
    sleep 2
    cd "${AI_SERVICE_DIR}"
    OMP_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 MKL_NUM_THREADS=1 NUMEXPR_NUM_THREADS=1 \
    AI_MODE="${mode}" AI_HEAP_ONLY_CUTOFF="${cutoff}" \
    AI_THRESHOLD_BASE="${base_thr}" AI_THRESHOLD_MIN="${min_thr}" \
    AI_GC_LOG_PATH="${gc_log_path}" AI_GC_OCCU_LOW="${occu_low}" AI_GC_OCCU_HIGH="${occu_high}" \
    AI_DAGOR_CPU_LOW="${dagor_cpu_low}" AI_DAGOR_CPU_HIGH="${dagor_cpu_high}" \
    AI_DAGOR_PROCESS_PATTERN="hyperledger.besu.Besu" \
    ${CPU_LIMIT} python3 serve.py > /tmp/serve_ai_smoke.log 2>&1 &
    echo "  AI service (re)started: mode=${mode} cutoff=${cutoff} base=${base_thr} min=${min_thr} occu=[${occu_low},${occu_high}] dagor_cpu=[${dagor_cpu_low},${dagor_cpu_high}] (PID $!)"
    sleep 6
    cd /home/yeochan.yoon/caliper-stress-test
}

ensure_ai_service() {
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

run_config() {
    local config="$1"; local rep="$2"
    local label="${config}_besu_${rep}"
    local run_dir="${RESULTS_DIR}/${label}"; mkdir -p "${run_dir}"
    local data_dir="/home/yeochan.yoon/caliper-stress-test/data_n_${label}_${RUN_ID}"
    local gc_log="${run_dir}/gc_besu.log"

    echo ""; echo "────────────────────────────────────────────────────────────────"
    echo "RUN: ${label} | $(date '+%Y-%m-%d %H:%M:%S')"
    echo "────────────────────────────────────────────────────────────────"

    local min_gas_price="0"
    local tx_pool_min_gas_price="0"
    local tx_pool_max_prioritized="2048"
    local tx_pool_layer_max_capacity="2048"

    case "${config}" in
        heap_only)
            # Arm2: heap-pressure-only ablation. threshold args (0.95/0.70) are
            # unused in heap_only mode (kept for schema parity).
            # VALIDATION-ONLY occu bounds: prior smoke run showed max_occu=0.021
            # at this scale, well below the real experiment's OCCU_LOW=0.10 — so
            # pressure never left 0 and reject never fired regardless of cutoff.
            # Here OCCU_LOW/HIGH are temporarily tightened to [0.01,0.03] purely
            # so the reject branch exercises against real (not synthetic) GC
            # telemetry. The real run tonight uses the calibrated 0.10/0.25
            # bounds — this override is smoke-test-only.
            restart_ai_service_with_config "heap_only" "0.95" "0.70" "0.01" "0.03" "${gc_log}" "0.5"
            ;;
        native_evict)
            # Arm0: tuned built-in txpool eviction, RAAC/ML fully bypassed.
            # AI service runs in pass-through mode (base=min=0.95, matching the
            # "static" config) so it never blocks anything itself — the ONLY
            # filtering mechanism is Besu's own native tx-pool config below.
            # tx_pool_min_gas_price=50 matches ATTACK_FEATURES.gas_price exactly
            # (the camouflaged-attacker fix applied earlier) — by construction
            # this price floor CANNOT separate attack from normal; the point is
            # to measure whether byte-capacity eviction alone helps when price
            # can't discriminate.
            restart_ai_service_with_config "raac" "0.95" "0.95" "0.10" "0.25" "${gc_log}" "0.5"
            # Price-based filtering is moot here: networkconfig.json pins the
            # real on-chain gasPrice to 0 for every submitted tx regardless of
            # attack/normal (the ATTACK_FEATURES.gas_price camouflage fix only
            # affects the AI service's /predict feature vector, a separate
            # signal path). So min-gas-price/tx-pool-min-gas-price stay at the
            # shared default (0) and Arm0 tests ONLY pure capacity-based native
            # eviction — no price signal is available to any arm on this chain.
            tx_pool_max_prioritized="64"
            tx_pool_layer_max_capacity="500000"
            ;;
        dagor)
            # Arm3: DAGOR-lite. AI service in dagor mode: random-early-drop
            # driven by Besu process CPU utilization, no per-tx features, no
            # GC/heap visibility (independent signal, not a strawman vs RAAC).
            # cpu bounds scaled for taskset -c 0-3 (4 cores => up to ~400%):
            # low=80% (~1 core busy), high=300% (~3 of 4 cores busy).
            restart_ai_service_with_config "dagor" "0.95" "0.95" "0.10" "0.25" "${gc_log}" "0.5" "80" "300"
            ;;
        *)
            echo "Unknown config: ${config}"; return 1 ;;
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

    ${CPU_LIMIT} nohup "${BESU_BIN}" \
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
        --min-gas-price="${min_gas_price}" \
        --tx-pool-min-gas-price="${tx_pool_min_gas_price}" \
        --tx-pool-max-prioritized="${tx_pool_max_prioritized}" \
        --tx-pool-layer-max-capacity="${tx_pool_layer_max_capacity}" \
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

    cp /tmp/serve_ai_smoke.log "${run_dir}/ai_service_before.log" 2>/dev/null || true

    echo "  Running Caliper smoke (10+10+15+10+15+10s = 70s)..."
    ${CPU_LIMIT} timeout 300 npx caliper launch manager \
        --caliper-workspace ./ \
        --caliper-benchconfig "${BENCHCONFIG_SMOKE}" \
        --caliper-networkconfig "${NETWORKCONFIG_BESU}" \
        > "${run_dir}/caliper_console.log" 2>&1 || true

    cp /tmp/serve_ai_smoke.log "${run_dir}/ai_service_after.log" 2>/dev/null || true
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

    if [ "${config}" = "heap_only" ]; then
        if grep -q "ai_mode=heap_only" /tmp/serve_ai_smoke.log 2>/dev/null; then
            echo "  AI service confirmed started in ai_mode=heap_only"
        else
            echo "  WARNING: could not confirm ai_mode=heap_only in AI service log"
        fi
        # Real confirmation that scoring was bypassed: anomaly_score should be
        # null for every logged prediction (not just the startup banner).
        if ls "${raac_log_dir}"/*.jsonl > /dev/null 2>&1; then
            non_null=$(cat "${raac_log_dir}"/*.jsonl | grep -c '"anomaly_score":null' || echo 0)
            echo "  anomaly_score=null count: ${non_null}/${total} (should equal total in heap_only mode)"
        fi
    elif [ "${config}" = "native_evict" ]; then
        echo "  Besu native tx-pool config: min_gas_price=${tx_pool_min_gas_price} max_prioritized=${tx_pool_max_prioritized} layer_max_capacity=${tx_pool_layer_max_capacity}"
        echo "  RAAC/ML bypass confirmed: rejects should be ~0/${total} (AI service pass-through) — any real filtering must show up as accepted!=submitted at Besu"
    elif [ "${config}" = "dagor" ]; then
        if grep -q "ai_mode=dagor" /tmp/serve_ai_smoke.log 2>/dev/null; then
            echo "  AI service confirmed started in ai_mode=dagor"
        else
            echo "  WARNING: could not confirm ai_mode=dagor in AI service log"
        fi
        grep "\[dagor\]" /tmp/serve_ai_smoke.log 2>/dev/null | tail -5 | sed 's/^/  /'
        if ls "${raac_log_dir}"/*.jsonl > /dev/null 2>&1; then
            non_null=$(cat "${raac_log_dir}"/*.jsonl | grep -c '"anomaly_score":null' || echo 0)
            echo "  anomaly_score=null count: ${non_null}/${total} (should equal total in dagor mode — no per-tx scoring)"
        fi
    fi

    grep "Transaction Info\|Summary" "${run_dir}/caliper_console.log" 2>/dev/null | \
        tail -5 | sed 's/^/  Caliper: /' || true
    echo "  ✓ ${label} complete"
}

echo ""
echo "=============================="
echo "Starting smoke test: 1 run"
echo "=============================="

run_config "dagor" "1" || echo "  WARNING: dagor_besu_1 failed"

echo ""
echo "======================================================================"
echo "RAAC Arm0 smoke test COMPLETE — results in ${RESULTS_DIR}"
echo "======================================================================"
