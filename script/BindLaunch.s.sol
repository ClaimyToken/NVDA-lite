// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {LiquidityFeeReceiver} from "../src/LiquidityFeeReceiver.sol";

/// @notice One-time binding step after the Pons token exists.
/// This creates the permanent liquidity vault. Forge does not broadcast by default.
contract BindLaunch is Script {
    function run() external returns (address vault) {
        require(block.chainid == 4663, "Wrong chain");
        LiquidityFeeReceiver receiver = LiquidityFeeReceiver(vm.envAddress("RECEIVER_ADDRESS"));
        address token = vm.envAddress("PROJECT_TOKEN_ADDRESS");
        require(address(receiver).code.length != 0 && token.code.length != 0, "Contracts not deployed");
        require(receiver.token() == address(0), "Receiver already bound");

        vm.startBroadcast();
        receiver.bindLaunch(token);
        vm.stopBroadcast();

        vault = address(receiver.vault());
        require(vault.code.length != 0, "Vault was not created");
        console2.log("Permanent liquidity vault:", vault);
        console2.logBytes32(receiver.vault().poolId());
    }
}
