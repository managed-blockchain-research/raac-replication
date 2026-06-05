'use strict';
const { WorkloadModuleBase } = require('@hyperledger/caliper-core');

class MyWorkload extends WorkloadModuleBase {
    async submitTransaction() {
        const sendOptions = {
            verb: 'transfer',
            args: {
                to: '0x0000000000000000000000000000000000000000',
                value: '0',
                gas: 21000,
                gasPrice: '0' // Set to 0 here as well
            }
        };
        await this.sutAdapter.sendRequests(sendOptions);
    }
}

function createWorkloadModule() { return new MyWorkload(); }
module.exports.createWorkloadModule = createWorkloadModule;
