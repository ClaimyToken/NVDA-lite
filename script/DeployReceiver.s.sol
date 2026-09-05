// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPonsFactory, IPonsFeeEscrow} from "../src/interfaces/IPons.sol";
import {IReferenceOracle} from "../src/interfaces/IReferenceOracle.sol";
import {LiquidityFeeReceiver} from "../src/LiquidityFeeReceiver.sol";
import {LockedLiquidityVault} from "../src/LockedLiquidityVault.sol";

/// @notice Forge simulates by default. Broadcasting requires a separate explicit flag.
/// No oracle, treasury, bootstrapper, or execution limits are silently defaulted.
contract DeployReceiver is Script {
    function run() external returns (LiquidityFeeReceiver receiver) {
        require(block.chainid == 4663, "Wrong chain");
        IPonsFactory factory = IPonsFactory(0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e);
        uint256 deviation = vm.envUint("MAX_TICK_DEVIATION");
        uint256 loss = vm.envUint("MAX_SWAP_LOSS_BPS");
        require(deviation > 0 && deviation <= 200 && loss > 0 && loss <= 500, "Invalid price limits");
        LiquidityFeeReceiver.Config memory config = LiquidityFeeReceiver.Config({
            escrow: IPonsFeeEscrow(factory.feeEscrow()), factory: factory,
            manager: IPoolManager(factory.poolManager()), oracle: IReferenceOracle(vm.envAddress("REFERENCE_ORACLE")),
            hook: factory.memeHook(), quote: IERC20(0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC),
            treasury: vm.envAddress("PROJECT_TREASURY"), bootstrapper: vm.envAddress("LAUNCH_BOOTSTRAPPER"),
            minBatch: vm.envUint("MIN_BATCH_RAW"), maxBatch: vm.envUint("MAX_BATCH_RAW")
        });
        LockedLiquidityVault.Limits memory limits = LockedLiquidityVault.Limits({
            maxOracleAge: vm.envUint("MAX_ORACLE_AGE_SECONDS"), maxSwapQuote: vm.envUint("MAX_SWAP_QUOTE_RAW"),
            maxTickDeviation: int24(uint24(deviation)), maxSwapLossBps: uint16(loss)
        });
        vm.startBroadcast();
        receiver = new LiquidityFeeReceiver(config, limits);
        vm.stopBroadcast();
        console2.log("Receiver (use as Pons creatorFeeRecipient):", address(receiver));
        console2.log("Next: launch on Pons with 100 bps creator tax, buybacks off; bootstrapper calls bindLaunch(token).");
    }
}
