// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.22;

import { AtomicQueue } from "./../../src/atomic-queue/AtomicQueue.sol";
import { BaseScript } from "../Base.s.sol";
import { ConfigReader } from "../ConfigReader.s.sol";

bytes32 constant SALT = 0x9bac910c72debe007de61c000000000000000000000000000000000000000000;

contract DeployAtomicQueue is BaseScript {
    function run() public broadcast returns (AtomicQueue atomicQueue) {
        bytes memory creationCode = type(AtomicQueue).creationCode;
        atomicQueue = AtomicQueue(CREATEX.deployCreate3(SALT, creationCode));
    }

    function deploy(ConfigReader.Config memory) public override broadcast returns (address) {
        bytes memory creationCode = type(AtomicQueue).creationCode;
        return CREATEX.deployCreate3(SALT, creationCode);
    }
}
