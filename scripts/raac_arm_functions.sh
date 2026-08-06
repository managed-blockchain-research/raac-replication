#!/usr/bin/env bash
# Shared functions/config for RAAC 6-arm eval runs. Sourced by both
# run_raac_full_6arm.sh (the full night's loop) and rerun_single_run.sh
# (targeted re-run of one arm/rep, e.g. after a mid-run sanity check flags
# something wrong). Keeping this in one place means a fix here (like the
# taskset/OOM lessons already learned) applies to both automatically.
#
# Callers must set: RESULTS_DIR, RUN_ID, N_REPS (N_REPS only matters for the
# fragmentation-fuzz hook's "last aggressive rep" check) before calling
# run_config.

BESU_BIN="/home/yeochan.yoon/besu-source/build/install/besu/bin/besu"
LOG4J_CONFIG="/home/yeochan.yoon/caliper-stress-test/log4j2-console.xml"
# Redesign 2026-07-24 (raac-experiment-redesign debate): was "1g". At the
# fixed workload (100tps x 96KB payload x 120s attack-burst-1, attackRatio=
# 1.0), one burst offers ~1.15GB of attack payload -- ~115% of a 1GB heap vs.
# ~29% of NM's 4GB heap (HEAP_NM in raac_nm_arm_functions.sh). That ~4x
# severity mismatch, not just differing GC internals, plausibly explains why
# NM and Besu inverted on dagor/native_evict completion under nominally
# identical policy configs. Matched to NM's 4GB so both platforms are tested
# against comparably-severe relative attack volume.
HEAP_BESU="${HEAP_BESU_OVERRIDE:-4g}"
# Redesign 2026-07-24 (2nd pass): the shared networkconfig.json uses
# ws://localhost:8546. Root-caused static_besu_1's death at round 4 (n=3
# pilot, RUN_ID 20260724_171328) via /octo:debug to a flood of 2269
# "java.lang.IllegalStateException: WebSocket is closed" errors in Besu's
# own vert.x RPC handler -- the exact same bug class already found and
# fixed for the RACE track this session (WS freezes workers once a client
# connection drops mid-stream; see feedback_ws_to_http_race_nm memory).
# That fix was never ported to RAAC. Use a RAAC-specific copy (NOT the
# shared networkconfig.json, which many other experiment tracks reference
# and which has a different, incompatible contract ABI than the existing
# networkconfig_besu_http.json) with only the url field changed to http.
NETWORKCONFIG_BESU="networkconfig_raac_besu_http.json"
DEPLOY_BESU="deploy_multi_contracts.py"
BENCHCONFIG_RAAC="benchconfig-raac-burst-dynamic.yaml"
GC_PARSER="scripts/parse_besu_gc.py"
AI_SERVICE_DIR="/home/yeochan.yoon/banning/ai_service"
export RAAC_AI_URL="http://127.0.0.1:8000"
# mixedAttackLOHRaacBurst.js caps per-worker concurrent in-flight
# {AI-POST+sendRequests} chains via RAAC_MAX_INFLIGHT (JS default 5, tuned
# for NM where normal per-tx latency is low). Besu needs a per-policy value
# instead of one constant -- see max_inflight inside run_config() for why
# (native_evict's tiny tx-pool vs every other arm's default 2048 pool
# behave completely differently under concurrent load).

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

# args: mode base_thr min_thr occu_low occu_high gc_log_path heap_only_cutoff dagor_cpu_low dagor_cpu_high
restart_ai_service_with_config() {
    local mode="$1" base_thr="$2" min_thr="$3" occu_low="$4" occu_high="$5" gc_log_path="$6"
    local cutoff="${7:-0.5}" dagor_cpu_low="${8:-100.0}" dagor_cpu_high="${9:-800.0}"
    pkill -f "serve\.py" 2>/dev/null || true
    sleep 2
    cd "${AI_SERVICE_DIR}"
    # See raac_nm_arm_functions.sh: AI service's asyncio accept loop spins on
    # EMFILE under heavy attack-burst connection volume when the default
    # soft limit (1024) is hit. Hard limit is 262144; raise the soft limit
    # for this process (and its nohup'd child) accordingly.
    ulimit -n 65536
    OMP_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 MKL_NUM_THREADS=1 NUMEXPR_NUM_THREADS=1 \
    AI_MODE="${mode}" AI_HEAP_ONLY_CUTOFF="${cutoff}" \
    AI_THRESHOLD_BASE="${base_thr}" AI_THRESHOLD_MIN="${min_thr}" \
    AI_GC_LOG_PATH="${gc_log_path}" AI_GC_OCCU_LOW="${occu_low}" AI_GC_OCCU_HIGH="${occu_high}" \
    AI_DAGOR_CPU_LOW="${dagor_cpu_low}" AI_DAGOR_CPU_HIGH="${dagor_cpu_high}" \
    AI_DAGOR_PROCESS_PATTERN="hyperledger.besu.Besu" \
    nohup python3 serve.py > /tmp/serve_ai_full6arm.log 2>&1 &
    echo "  AI service (re)started: mode=${mode} base=${base_thr} min=${min_thr} occu=[${occu_low},${occu_high}] cutoff=${cutoff} dagor_cpu=[${dagor_cpu_low},${dagor_cpu_high}] (PID $!)"
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

# args: config rep [occu_low occu_high heap_only_cutoff dagor_cpu_low dagor_cpu_high]
# The optional trailing args let a targeted re-run override the calibrated
# defaults for exactly one arm (e.g. dagor_cpu bounds turned out miscalibrated
# against real observed Besu CPU%) without touching the main script.
run_config() {
    local config="$1"; local rep="$2"
    local override_occu_low="${3:-}" override_occu_high="${4:-}" override_cutoff="${5:-}"
    local override_dagor_low="${6:-}" override_dagor_high="${7:-}"
    local label="${config}_besu_${rep}"
    local run_dir="${RESULTS_DIR}/${label}"; mkdir -p "${run_dir}"
    local data_dir="/home/yeochan.yoon/caliper-stress-test/data_n_${label}_${RUN_ID}"
    local gc_log="${run_dir}/gc_besu.log"

    local tx_pool_max_prioritized="2048"
    local tx_pool_layer_max_capacity="2048"
    local occu_low="0.10" occu_high="0.25"
    local outer_timeout="3600"
    # RAAC_MAX_INFLIGHT (per-worker concurrency cap in
    # mixedAttackLOHRaacBurst.js) must match how much real processing Besu
    # does per submitted tx, which differs sharply by tx-pool size, not just
    # by platform. native_evict's tiny prioritized pool (64) means Besu
    # rejects most submissions near-instantly regardless of concurrency, so
    # a high cap (50) was safe there. Every other arm here uses the default
    # 2048-pool, where Besu actually validates/queues each submission --
    # UPDATE 2026-07-31 later same day: MAX_INFLIGHT=50 originally caused
    # aggressive/rule_based to permanently stall (0/6 rounds) -- but the
    # actual root cause was a nonce-claim TOCTOU race in ethereum-connector.js
    # (context.localNonce read/fetch/increment wasn't atomic across
    # concurrent in-flight sends), now fixed there via a per-context
    # promise-chain mutex (_claimNonce). Lowering MAX_INFLIGHT to 10 was
    # treating the symptom, not the disease -- confirmed today it makes
    # EVERY non-native_evict policy (including "static", previously always
    # fast) ~27x slower than the healthy reference (warmup 83s -> 37+ min).
    # With the nonce race actually fixed, reverting to a uniform 50 (same
    # as native_evict) should be safe. Re-validate before trusting this for
    # real data collection.
    local max_inflight="50"

    echo ""; echo "────────────────────────────────────────────────────────────────"
    echo "RUN: ${label} | $(date '+%Y-%m-%d %H:%M:%S')"
    echo "────────────────────────────────────────────────────────────────"

    case "${config}" in
        static)
            restart_ai_service_with_config "raac" "0.95" "0.95" "${override_occu_low:-0.10}" "${override_occu_high:-0.25}" "${gc_log}"
            ;;
        native_evict)
            restart_ai_service_with_config "raac" "0.95" "0.95" "${override_occu_low:-0.10}" "${override_occu_high:-0.25}" "${gc_log}"
            tx_pool_max_prioritized="64"
            # UPDATE 2026-08-01: --tx-pool-layer-max-capacity is BYTES, not a
            # transaction count (confirmed via `besu --help`: default is
            # 12,500,000 bytes / ~12.5MB). "500000" (500KB) was ~25x SMALLER
            # than Besu's own default -- the opposite of the intended "large
            # non-prioritized overflow layer" contrasted against the
            # deliberately tiny 64-slot prioritized pool. Root-caused live
            # during the weekend n=8 run: this tiny capacity triggered a real
            # Besu-internal bug under load -- besu_console.log showed repeated
            # "LayeredPendingTransactions - Unexpected error
            # java.lang.IllegalStateException: Sender ... cannot
            # simultaneously have and not have priority" warnings from
            # SparseTransactions.promote(), consistent with transactions being
            # silently dropped from the pool after acceptance (client sees
            # wall-clock-deadline timeouts waiting for a receipt that never
            # comes, at fail rates of 17-41% on CALM rounds with attackRatio=0
            # -- reproduced across native_evict_besu_1 and _2, all 3 retry
            # attempts each). Raised to comfortably exceed Besu's own default.
            tx_pool_layer_max_capacity="50000000"
            # UPDATE 2026-08-01 ~07:00 KST: layer-capacity fix above removed the
            # Besu-internal exception, but native_evict STILL showed calm-round
            # fail rates 23-63% (attackRatio=0), now dominated by "Transaction
            # nonce is too distant from current sender nonce" -- i.e. genuine
            # transaction loss from the tx-pool. Hypothesis: MAX_INFLIGHT=50 was
            # calibrated on the (wrong) assumption that native_evict's tiny
            # tx_pool_max_prioritized=64 makes Besu reject excess submissions
            # near-instantly and cheaply; in practice up to 50-per-worker x 30
            # workers = up to 1500 concurrent claims contend for only 64
            # prioritized slots, and losers get silently evicted rather than
            # cleanly rejected. Lowering to reduce contention pressure on the
            # tiny prioritized tier specifically for this arm.
            # UPDATE 2026-08-01 ~12:35 KST: lowering MAX_INFLIGHT to 15 (above)
            # fixed the fail-rate problem but made an ALREADY-mysterious
            # over-submission volume (45,000-150,000+ vs ~9,000 target on
            # every round) take even LONGER to grind through at lower
            # concurrency: calm-1 alone took 6653s (1h51m). Root cause of the
            # volume explosion has since been FOUND AND FIXED (see
            # mixedAttackLOHRaacBurst.js: the dispatch cap's this.txIndex++
            # happened AFTER a self-pacing await, so concurrent fire-and-forget
            # calls could all read the same stale txIndex and pass the cap
            # check before any of them incremented it -- fixed by claiming the
            # slot synchronously). Re-validated at MAX_INFLIGHT=50 post-fix:
            # round durations now sane (~100-185s vs 540s nominal, full 6-round
            # run finished in ~925s total) but calm-round fail rates are back up
            # to 26-45% (all "tx wall-clock deadline exceeded", NOT nonce-gap --
            # confirmed 0 "too distant" occurrences) -- MAX_INFLIGHT=50 now
            # genuinely overwhelms the tiny 64-slot prioritized pool once
            # dispatch volume is correctly capped near target. Lowering back to
            # 15 to relieve that contention; since the volume bug is fixed,
            # this should no longer blow up round duration the way it did last
            # time -- re-validate with a smoke test before trusting.
            max_inflight="15"
            outer_timeout="10800"
            ;;
        heap_only)
            restart_ai_service_with_config "heap_only" "0.95" "0.70" "${override_occu_low:-0.10}" "${override_occu_high:-0.25}" "${gc_log}" "${override_cutoff:-0.5}"
            ;;
        dagor)
            restart_ai_service_with_config "dagor" "0.95" "0.70" "${override_occu_low:-0.10}" "${override_occu_high:-0.25}" "${gc_log}" "0.5" "${override_dagor_low:-100}" "${override_dagor_high:-800}"
            ;;
        moderate)
            restart_ai_service_with_config "raac" "0.95" "0.70" "${override_occu_low:-0.10}" "${override_occu_high:-0.25}" "${gc_log}"
            ;;
        aggressive)
            restart_ai_service_with_config "raac" "0.95" "0.70" "${override_occu_low:-0.10}" "${override_occu_high:-0.20}" "${gc_log}"
            ;;
        rule_based)
            # ML ablation (JSS/JPDC "no ML ablation" fix): identical
            # thresholds/occupancy bounds to "moderate", differing only in
            # AI_MODE (rule_based vs raac) -- isolates whether the trained
            # Isolation Forest adds value over a naive fixed payload-size
            # rule under the same adaptive-threshold mechanism.
            restart_ai_service_with_config "rule_based" "0.95" "0.70" "${override_occu_low:-0.10}" "${override_occu_high:-0.25}" "${gc_log}"
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

    # -XX:+ExitOnOutOfMemoryError: heap OOM under full attack load is a real,
    # measured failure mode for static/moderate/aggressive/dagor (not just a
    # host-contention artifact — seen at load~5 too). This doesn't fix the
    # crash, but makes it fail fast instead of lingering as an unresponsive
    # zombie for the full 900s caliper timeout, which matters for rerun cycle
    # time. Heap size (HEAP_BESU) WAS deliberately left at 1g through the
    # 20260724_073519 partial run for comparability with earlier data, but is
    # now raised to 4g as of the redesign above — this run's data is NOT
    # comparable to any earlier Besu run at 1g.
    local java_opts="-Xms${HEAP_BESU} -Xmx${HEAP_BESU} \
-XX:+UseG1GC -XX:MaxGCPauseMillis=200 -XX:+ExitOnOutOfMemoryError \
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
        --rpc-http-max-active-connections=3000 \
        --rpc-ws-enabled \
        --rpc-ws-host=0.0.0.0 \
        --rpc-ws-port=8546 \
        --rpc-ws-api=ETH,NET,WEB3,DEBUG,ADMIN,TXPOOL \
        --rpc-ws-max-active-connections=3000 \
        --host-allowlist="*" \
        --min-gas-price=0 \
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

    cp /tmp/serve_ai_full6arm.log "${run_dir}/ai_service_before.log" 2>/dev/null || true

    export RAAC_MAX_INFLIGHT="${max_inflight}"
    # Besu confirmed (2026-07-31, live diagnosis) to NOT need the NM-calibrated
    # retry-backoff sleeps in ethereum-connector.js (txpool stayed empty, CPU idle,
    # even with hundreds of wall-clock-deadline failures per round) -- those backoffs
    # compounded into rounds taking 10-25x reference duration despite Besu itself
    # staying healthy. Shrink them ~7x (8-15s -> ~1.1-2.1s) for Besu specifically;
    # NM's arm functions leave RAAC_TX_BACKOFF_MULTIPLIER unset (defaults to 1.0).
    export RAAC_TX_BACKOFF_MULTIPLIER="0.14"
    echo "  Running Caliper (60s warmup + 90+120+90+120+60s burst pattern)... [RAAC_MAX_INFLIGHT=${max_inflight}, backoff_mult=${RAAC_TX_BACKOFF_MULTIPLIER}]"
    timeout "${outer_timeout}" npx caliper launch manager \
        --caliper-workspace ./ \
        --caliper-benchconfig "${BENCHCONFIG_RAAC}" \
        --caliper-networkconfig "${NETWORKCONFIG_BESU}" \
        > "${run_dir}/caliper_console.log" 2>&1 &
    local caliper_pid=$!

    # Fragmentation fuzz-loop hook: only on the LAST aggressive rep. Fired
    # once caliper's own round-orchestrator reports it has actually STARTED
    # the steady-state-stress round ("attack-burst-2"), plus a short buffer,
    # WHILE caliper's own attack traffic is still running in parallel, so
    # pressure is genuinely elevated when the probe fires.
    #
    # History: v1 of this hook ran synchronously AFTER the full 540s caliper
    # invocation (incl. the 60s cool-down) had already returned -- pressure
    # had decayed to baseline by then (confirmed: gc_pressure_before=0.0 for
    # every fragment in every captured run). v2 fired after a fixed
    # `sleep 390` (nominal 60+90+120+90+30) concurrently with caliper --
    # still wrong, because caliper's rounds are transaction-count-based, not
    # fixed-wall-clock: under host contention each round takes longer than
    # nominal, so a hardcoded offset can land in the wrong round entirely
    # (confirmed via smoke test on a contended host: sleep 390 landed in
    # calm-2/recovery, since attack-burst-2 didn't actually start until
    # t~495s that run). v3 (this version) polls caliper's own log for its
    # round-orchestrator's phase-transition marker instead of guessing a
    # fixed offset, so it self-adapts to whatever pace the host is actually
    # running at.
    local fuzz_pid=""
    if [ "${config}" = "aggressive" ] && [ "${rep}" = "${N_REPS:-}" ]; then
        (
            local waited=0
            while [ "${waited}" -lt 700 ]; do
                grep -q "Started round 5 (attack-burst-2)" "${run_dir}/caliper_console.log" 2>/dev/null && break
                sleep 5
                waited=$((waited + 5))
            done
            if [ "${waited}" -ge 700 ]; then
                echo "  WARNING: attack-burst-2 phase marker never appeared after 700s -- firing fuzz-loop anyway (best-effort, likely uninformative)"
            else
                sleep 20   # let pressure build a bit within the steady-state-stress round before probing
            fi
            echo "  Running fragmentation fuzz-loop against live (pressured) node..."
            CONTRACT_ADDR=$(python3 -c "import json; print(json.load(open('deployed_contracts.json'))['addresses'][0])" 2>/dev/null || echo "")
            if [ -n "${CONTRACT_ADDR}" ]; then
                python3.11 scripts/fragmentation_fuzz.py \
                    --ai-url http://127.0.0.1:8000 --contract-address "${CONTRACT_ADDR}" \
                    --contract-abi StateBloater.json --k-values 1,2,3,4,5,6,8,10 --drip-delay 0 \
                    --out "${run_dir}/fragmentation_fast.json" \
                    > "${run_dir}/fragmentation_fast.log" 2>&1 || echo "  WARNING: fast fragmentation fuzz failed"
                # Slow-drip (~140-180s total) will run past the 120s
                # steady-state-stress window into cool-down — expected and
                # informative: it directly shows whether pressure decays
                # back to baseline mid-sequence, which is exactly the
                # "pacing evades detection" question this variant tests.
                python3.11 scripts/fragmentation_fuzz.py \
                    --ai-url http://127.0.0.1:8000 --contract-address "${CONTRACT_ADDR}" \
                    --contract-abi StateBloater.json --k-values 5 --drip-delay 35 \
                    --out "${run_dir}/fragmentation_slowdrip.json" \
                    > "${run_dir}/fragmentation_slowdrip.log" 2>&1 || echo "  WARNING: slow-drip fragmentation fuzz failed"
            else
                echo "  WARNING: could not resolve contract address for fragmentation fuzz-loop"
            fi
        ) &
        fuzz_pid=$!
    fi

    wait "${caliper_pid}" || true
    [ -n "${fuzz_pid}" ] && { wait "${fuzz_pid}" 2>/dev/null || true; }

    cp /tmp/serve_ai_full6arm.log "${run_dir}/ai_service_after.log" 2>/dev/null || true
    cp caliper.log "${run_dir}/caliper.log" 2>/dev/null || true
    cp report.html "${run_dir}/report.html" 2>/dev/null || true
    # caliper.log is append-only across invocations (never truncated by
    # caliper itself) — reset it now that this run's copy is safely saved,
    # or it grows unbounded across all 48 runs tonight (hit 20GB once already).
    : > caliper.log 2>/dev/null || true

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
