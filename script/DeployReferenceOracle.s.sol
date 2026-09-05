// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {SignedReferenceOracle} from "../src/SignedReferenceOracle.sol";

/// @notice Forge simulates by default. Broadcasting requires a separate explicit flag.
contract DeployReferenceOracle is Script {
    function run() external returns (SignedReferenceOracle oracle) {
        require(block.chainid == 4663, "Wrong chain");
        address[] memory signers = vm.envAddress("ORACLE_SIGNERS", ",");
        uint256 threshold = vm.envUint("ORACLE_THRESHOLD");
        uint256 validity = vm.envUint("MAX_REPORT_VALIDITY_SECONDS");
        require(threshold <= type(uint8).max && validity <= type(uint64).max, "Configuration too large");

        vm.startBroadcast();
        oracle = new SignedReferenceOracle(signers, uint8(threshold), uint64(validity));
        vm.stopBroadcast();

        console2.log("Reference oracle:", address(oracle));
        console2.log("Set REFERENCE_ORACLE to this address only after bytecode/config verification.");
    }
}
