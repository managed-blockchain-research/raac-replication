'use strict';

/**
 * Burst Attack Workload — LOH Pressure, RAAC Enabled (Dynamic Threshold)
 *
 * attackRatio is set per-round via benchmark YAML arguments:
 *   0.0  → all normal txs (calm phase)
 *   1.0  → all attack txs (burst phase)
 *
 * Each tx queries the AI service. The AI service uses a dynamic threshold
 * driven by NM's RSS-based GC pressure. At idle (low pressure) the threshold
 * is 0.95, which allows attack txs through (score 0.8952 < 0.95). As LOH
 * builds, RSS rises, threshold drops below 0.8952, attacks are blocked, GC
 * pressure falls, and the cycle repeats.
 */

const { WorkloadModuleBase } = require('@hyperledger/caliper-core');
const http = require('http');
const fs   = require('fs');
const path = require('path');

const ATTACK_DATA = '0x' + '00'.repeat(96000);
const NORMAL_DATA = '0x';   // empty: 428 txs/block × 178B = 76KB < 85KB LOH threshold
const AI_URL      = process.env.RAAC_AI_URL || 'http://127.0.0.1:8000';
// Caliper's own fixed-rate controller paces off txCounters.totalSubmitted,
// which only increments when sutAdapter.sendRequests() actually runs (see
// @hyperledger/caliper-core connector-base.js emitting Events.TxsSubmitted).
// Since a RAAC-rejected tx returns before ever calling sendRequests(), it
// never increments that counter, so the built-in rate controller thinks far
// less time has elapsed than really has and stops throttling almost
// entirely once the reject rate is high (confirmed: 305,781 attempts vs. a
// 12,000 target in one 120s/100tps round for a mostly-rejecting policy,
// vs. 12,061 for an always-accepting one). Self-pace here instead, keyed on
// total ATTEMPTS (this.txIndex) rather than accepted-and-submitted count,
// so admission-control outcome can no longer affect the offered load.
const TARGET_TPS  = Number(process.env.RAAC_TARGET_TPS) || 100;

// Caliper's runDuration() fires submitTransaction() in a fire-and-forget
// loop (via setImmediatePromise, which resolves once the call is made, not
// once it settles -- see @hyperledger/caliper-core caliper-worker.js). With
// no cap on concurrent in-flight calls, a slow/degraded SUT lets thousands
// of AI-POST+sendRequests chains pile up per worker process; confirmed via
// a real run where the observer reported "0/0/0/0" for 7+ minutes then a
// single burst of 55,602 submitted/38,884 failed all at once -- consistent
// with Node's event loop (and/or Caliper's own IPC aggregation) being
// swamped by a huge backlog rather than any single tx's own timeout.
// Bound per-worker concurrency instead, so degradation causes bounded
// backpressure (new attempts wait for a slot) rather than unbounded queueing.
const MAX_INFLIGHT = Number(process.env.RAAC_MAX_INFLIGHT) || 5;

class Semaphore {
    constructor(max) { this.max = max; this.count = 0; this.queue = []; }
    async acquire() {
        if (this.count < this.max) { this.count++; return; }
        await new Promise(resolve => this.queue.push(resolve));
        this.count++;
    }
    release() {
        this.count--;
        const next = this.queue.shift();
        if (next) next();
    }
}

const NORMAL_FEATURES = {
    gas_price: 50, gas_limit: 21_000, wei_value: 1_000_000_000_000_000_000,
    bytecode_size: 0, opcode_count: 10, call_depth: 0, sstore_count: 0,
};
// gas_price matches NORMAL_FEATURES: an economically camouflaged attacker
// pays normal-tier price so a price-only filter (e.g. tx-pool-min-gas-price)
// cannot separate it from benign traffic — only the allocation-heavy
// footprint (bytecode_size/gas_limit/wei_value=0) gives it away.
const ATTACK_FEATURES = {
    gas_price: 50, gas_limit: 12_000_000, wei_value: 0,
    bytecode_size: 96_000, opcode_count: 40_000, call_depth: 12, sstore_count: 0,
};

function httpPost(url, body) {
    return new Promise((resolve) => {
        const data = JSON.stringify(body);
        const u    = new URL(url);
        const opts = {
            hostname: u.hostname, port: u.port || 80, path: u.pathname,
            method: 'POST',
            headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(data) },
        };
        const req = http.request(opts, (res) => {
            let raw = '';
            res.on('data', c => raw += c);
            res.on('end', () => { try { resolve(JSON.parse(raw)); } catch { resolve({ action: 'accept' }); } });
        });
        req.on('error', () => resolve({ action: 'accept' }));
        req.setTimeout(2000, () => { req.destroy(); resolve({ action: 'accept' }); });
        req.write(data); req.end();
    });
}

class MixedAttackLOHRaacBurstWorkload extends WorkloadModuleBase {
    constructor() {
        super();
        this.txIndex     = 0;
        this.contractId  = null;
        this.attackRatio = 0;
        this.normalCount = 0;
        this.attackCount = 0;
        this.raacBlocked = 0;
        this.tpCount     = 0;
        this.fpCount     = 0;
        this.logStream   = null;
        this._firstAttemptTime = null;
        this._inflightSem = new Semaphore(MAX_INFLIGHT);
    }

    async initializeWorkloadModule(workerIndex, totalWorkers, numberProtocols, adapterConfig, blockchainConfig) {
        await super.initializeWorkloadModule(workerIndex, totalWorkers, numberProtocols, adapterConfig, blockchainConfig);

        const args         = this.roundArguments || {};
        const numContracts = args.numContracts || 30;
        const prefix       = args.contractPrefix || 'SB';
        this.contractId    = `${prefix}${workerIndex % numContracts}`;
        this.attackRatio   = typeof args.attackRatio === 'number' ? args.attackRatio : 0;
        this._firstAttemptTime = null;

        // UPDATE 2026-07-31: Caliper's runDuration() dispatches submitTransaction()
        // fire-and-forget (setImmediatePromise resolves on dispatch, not completion --
        // see the top-of-file comment), so the outer loop can dispatch WAY more calls
        // within the round's nominal wall-clock window than the self-pacing sleep
        // above is designed to actually execute per second -- each dispatched call
        // just queues its own setTimeout and fires later, in order, correctly paced,
        // but there can be far more of them queued than the round duration allows.
        // Confirmed live: a 90s/100tps calm-1 round (target ~9000 aggregate) still had
        // Submitted climbing past 94,000 after 26+ minutes -- the round doesn't finish
        // until every dispatched (queued) attempt eventually fires and resolves, so
        // massive over-dispatch directly explains rounds running many times their
        // nominal duration. Cap total attempts per worker at the round's own target
        // count so submitTransaction() becomes a (rate-limited, non-busy-looping) no-op
        // once that's reached, instead of accepting unbounded dispatch.
        const roundDurationSeconds = Number(args.roundDurationSeconds) || 0;
        const tpsPerWorkerForCap = TARGET_TPS / totalWorkers;
        this._maxAttempts = roundDurationSeconds > 0 && tpsPerWorkerForCap > 0
            ? Math.ceil(tpsPerWorkerForCap * roundDurationSeconds * 1.05)   // +5% slack for pacing jitter
            : Infinity;

        const logDir = args.logDir || process.env.RAAC_LOG_DIR || null;
        if (logDir) {
            const label   = args.roundLabel || 'round';
            const logFile = path.join(logDir, `worker${workerIndex}_${label}_raac.jsonl`);
            this.logStream = fs.createWriteStream(logFile, { flags: 'a' });
        }

        console.log(`[RaacBurst] Worker ${workerIndex} → ${this.contractId} | attackRatio=${this.attackRatio} | AI: ${AI_URL}`);
    }

    async submitTransaction() {
        // Dispatch cap (see initializeWorkloadModule comment): once this worker has
        // already attempted its share of the round's target count, no-op instead of
        // queuing yet another self-paced attempt further into the future. A short
        // fixed sleep (not zero) keeps Caliper's fire-and-forget outer loop from
        // busy-spinning on free no-ops for whatever wall-clock time it has left.
        if (this.txIndex >= this._maxAttempts) {
            await new Promise(resolve => setTimeout(resolve, 200));
            return;
        }

        // UPDATE 2026-08-01: claim this attempt's slot SYNCHRONOUSLY, before any
        // await, so concurrent fire-and-forget invocations of submitTransaction()
        // (Caliper dispatches the next call without waiting for this one to
        // settle) can't all read the same stale this.txIndex and pass the cap
        // check above before any of them increments it. That race is the real
        // root cause of native_evict's Submitted count reaching 45,000-150,000+
        // vs. a ~9,450 target: this call's downstream work (AI predict + tx
        // send) can take many seconds under eviction/backoff, giving the caliper
        // dispatch loop a wide window to pile up more concurrent calls, all
        // stuck at the (previously non-atomic) check-then-increment gap.
        const myIndex = this.txIndex;
        this.txIndex++;

        // Self-pace on total attempts, not on Caliper's accepted-and-submitted
        // count — see TARGET_TPS comment above for why the built-in rate
        // controller can't be trusted here.
        const tpsPerWorker = TARGET_TPS / this.totalWorkers;
        if (tpsPerWorker > 0) {
            const sleepTimeMs = 1000 / tpsPerWorker;
            if (this._firstAttemptTime === null) this._firstAttemptTime = Date.now();
            const diff = sleepTimeMs * myIndex - (Date.now() - this._firstAttemptTime);
            if (diff > 0) await new Promise(resolve => setTimeout(resolve, diff));
        }

        const isAttack = Math.random() < this.attackRatio;
        const features  = isAttack ? ATTACK_FEATURES : NORMAL_FEATURES;
        const txHash    = `0x${this.workerIndex.toString(16).padStart(4,'0')}${(myIndex + 1).toString(16).padStart(8,'0')}`;

        if (isAttack) this.attackCount++; else this.normalCount++;

        await this._inflightSem.acquire();
        try {
            const aiResp  = await httpPost(`${AI_URL}/predict`, { tx_hash: txHash, ...features });
            const blocked = aiResp.action === 'reject';

            if (blocked) {
                this.raacBlocked++;
                if (isAttack) this.tpCount++; else this.fpCount++;
            }

            if (this.logStream) {
                this.logStream.write(JSON.stringify({
                    worker:            this.workerIndex,
                    txIndex:           this.txIndex,
                    type:              isAttack ? 'attack' : 'normal',
                    ai_action:         aiResp.action,
                    anomaly_score:     aiResp.anomaly_score,
                    dyn_threshold:     aiResp.dynamic_threshold,
                    gc_pressure:       aiResp.gc_pressure,
                    submitted:         !blocked,
                }) + '\n');
            }

            if (blocked) return;

            let request;
            if (isAttack) {
                request = { contract: this.contractId, verb: 'sink', args: [ATTACK_DATA], readOnly: false };
            } else {
                request = { contract: this.contractId, verb: 'sink', args: [NORMAL_DATA], readOnly: false };
            }
            await this.sutAdapter.sendRequests(request);
        } finally {
            this._inflightSem.release();
        }
    }

    async cleanupWorkloadModule() {
        if (this.logStream) this.logStream.end();
        const tpr = this.attackCount > 0 ? (this.tpCount / this.attackCount * 100).toFixed(1) : 'N/A';
        const fpr = this.normalCount > 0 ? (this.fpCount / this.normalCount * 100).toFixed(1) : 'N/A';
        console.log(`[RaacBurst] Worker ${this.workerIndex}: ` +
            `normal=${this.normalCount} attack=${this.attackCount} ` +
            `blocked=${this.raacBlocked} TPR=${tpr}% FPR=${fpr}%`);
    }
}

module.exports.createWorkloadModule = () => new MixedAttackLOHRaacBurstWorkload();
