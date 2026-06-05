'use strict';

/**
 * Mixed Attack Workload — LOH Pressure, RAAC Enabled
 * 70% "normal" txs: StateBloater.bloat(startIdx, 1) — low gas, small calldata
 * 30% "attack" txs: StateBloater.sink(96KB_data)    — 96 KB calldata, gas=12M
 *
 * Before each tx, queries the AI service at RAAC_AI_URL (/predict).
 * Attack txs are classified by features (gas_limit=12M, bytecode_size=96000) and rejected.
 * Rejected attack txs are NOT submitted to the node → no LOH allocation in NM.
 */

const { WorkloadModuleBase } = require('@hyperledger/caliper-core');
const http = require('http');
const fs   = require('fs');
const path = require('path');

const ATTACK_RATIO = 0.30;
const ATTACK_DATA  = '0x' + '00'.repeat(96000); // 96 KB zero calldata
const AI_URL       = process.env.RAAC_AI_URL || 'http://127.0.0.1:8000';

const NORMAL_FEATURES = {
    gas_price:     50,
    gas_limit:     21_000,
    wei_value:     1_000_000_000_000_000_000,
    bytecode_size: 0,
    opcode_count:  10,
    call_depth:    0,
    sstore_count:  0,
};

const ATTACK_FEATURES = {
    gas_price:     1,
    gas_limit:     12_000_000,
    wei_value:     0,
    bytecode_size: 96_000,
    opcode_count:  40_000,
    call_depth:    12,
    sstore_count:  0,
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
        req.write(data);
        req.end();
    });
}

class MixedAttackLOHRaacWorkload extends WorkloadModuleBase {
    constructor() {
        super();
        this.txIndex     = 0;
        this.contractId  = null;
        this.normalCount = 0;
        this.attackCount = 0;
        this.raacAllowed = 0;
        this.raacBlocked = 0;
        this.tpCount     = 0;
        this.fpCount     = 0;
        this.logStream   = null;
    }

    async initializeWorkloadModule(workerIndex, totalWorkers, numberProtocols, adapterConfig, blockchainConfig) {
        await super.initializeWorkloadModule(workerIndex, totalWorkers, numberProtocols, adapterConfig, blockchainConfig);

        const args = this.roundArguments || {};
        const numContracts = args.numContracts || 30;
        const prefix       = args.contractPrefix || 'SB';
        this.contractId    = `${prefix}${workerIndex % numContracts}`;

        const logDir = args.logDir || process.env.RAAC_LOG_DIR || null;
        if (logDir) {
            const logFile = path.join(logDir, `worker${workerIndex}_raac.jsonl`);
            this.logStream = fs.createWriteStream(logFile, { flags: 'a' });
        }

        console.log(`[MixedAttackLOH/RAAC] Worker ${workerIndex} → contract ${this.contractId} | AI: ${AI_URL}`);
    }

    async submitTransaction() {
        this.txIndex++;
        const isAttack = Math.random() < ATTACK_RATIO;
        const features = isAttack ? ATTACK_FEATURES : NORMAL_FEATURES;
        const txHash   = `0x${this.workerIndex.toString(16).padStart(4, '0')}${this.txIndex.toString(16).padStart(8, '0')}`;

        if (isAttack) this.attackCount++;
        else          this.normalCount++;

        const aiResp  = await httpPost(`${AI_URL}/predict`, { tx_hash: txHash, ...features });
        const blocked = (aiResp.action === 'reject');

        if (blocked) { this.raacBlocked++; if (isAttack) this.tpCount++; else this.fpCount++; }
        else          { this.raacAllowed++; }

        if (this.logStream) {
            this.logStream.write(JSON.stringify({
                worker:         this.workerIndex,
                txIndex:        this.txIndex,
                type:           isAttack ? 'attack' : 'normal',
                ai_action:      aiResp.action,
                anomaly_score:  aiResp.anomaly_score,
                dyn_threshold:  aiResp.dynamic_threshold,
                submitted:      !blocked,
            }) + '\n');
        }

        if (blocked) return;

        let request;
        if (isAttack) {
            // Attack tx was allowed (shouldn't happen with working AI service — fail-open only)
            request = { contract: this.contractId, verb: 'sink', args: [ATTACK_DATA], readOnly: false };
        } else {
            const startIdx = (this.workerIndex * 10_000_000) + this.txIndex;
            request = { contract: this.contractId, verb: 'bloat', args: [startIdx, 1], readOnly: false };
        }

        await this.sutAdapter.sendRequests(request);
    }

    async cleanupWorkloadModule() {
        if (this.logStream) this.logStream.end();
        const tpr = this.attackCount > 0 ? (this.tpCount / this.attackCount * 100).toFixed(1) : 'N/A';
        const fpr = this.normalCount > 0 ? (this.fpCount / this.normalCount * 100).toFixed(1) : 'N/A';
        console.log(`[MixedAttackLOH/RAAC] Worker ${this.workerIndex}: ` +
            `normal=${this.normalCount} attack=${this.attackCount} | ` +
            `allowed=${this.raacAllowed} blocked=${this.raacBlocked} | ` +
            `TPR=${tpr}% FPR=${fpr}%`);
    }
}

module.exports.createWorkloadModule = () => new MixedAttackLOHRaacWorkload();
