// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPonsLaunchFactory} from "../src/interfaces/IPons.sol";
import {LiquidityFeeReceiver} from "../src/LiquidityFeeReceiver.sol";

/// @notice Launches the project token through Pons V2 after the receiver exists.
/// Forge simulates by default. Broadcasting requires a separate explicit flag.
contract LaunchProjectToken is Script {
    IPonsLaunchFactory private constant FACTORY = IPonsLaunchFactory(0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e);
    address private constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;

    function run() external returns (address token, address curve) {
        require(block.chainid == 4663, "Wrong chain");
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        address receiverAddress = vm.envAddress("RECEIVER_ADDRESS");
        uint256 configId = vm.envUint("PONS_LAUNCH_CONFIG_ID");
        bytes32 salt = vm.envBytes32("PONS_LAUNCH_SALT");
        require(receiverAddress.code.length != 0, "Receiver not deployed");
        require(FACTORY.canLaunch(deployer), "Deployer cannot launch");
        require(FACTORY.approvedPairTokens(NVDA), "NVDA pair not approved");
        require(FACTORY.maxCreatorTaxBps() >= 100, "Creator tax unavailable");

        LiquidityFeeReceiver receiver = LiquidityFeeReceiver(receiverAddress);
        require(address(receiver.factory()) == address(FACTORY), "Receiver factory mismatch");
        require(address(receiver.quote()) == NVDA, "Receiver quote mismatch");
        require(receiver.token() == address(0), "Receiver already bound");

        IPonsLaunchFactory.LaunchConfig memory launchConfig = FACTORY.getLaunchConfig(configId);
        require(launchConfig.enabled, "Launch config disabled");
        require(launchConfig.curveFeeBps == 100, "Expected 1% base fee");
        require(launchConfig.poolFee == 0, "Expected zero V4 core fee");

        IPonsLaunchFactory.Socials memory socials = IPonsLaunchFactory.Socials({
            twitter: vm.envOr("TOKEN_TWITTER", string("")),
            telegram: vm.envOr("TOKEN_TELEGRAM", string("")),
            discord: vm.envOr("TOKEN_DISCORD", string("")),
            website: vm.envOr("TOKEN_WEBSITE", string("")),
            farcaster: vm.envOr("TOKEN_FARCASTER", string(""))
        });
        IPonsLaunchFactory.TokenParams memory params = IPonsLaunchFactory.TokenParams({
            name: vm.envString("TOKEN_NAME"),
            symbol: vm.envString("TOKEN_SYMBOL"),
            logo: vm.envString("TOKEN_LOGO_URI"),
            description: vm.envString("TOKEN_DESCRIPTION"),
            socials: socials,
            creatorFeeRecipient: receiverAddress,
            creatorTaxBps: 100,
            buybackEnabled: false,
            expectedEconomics: FACTORY.previewLaunchEconomics(configId, NVDA),
            salt: salt
        });

        uint256 fee = FACTORY.launchFee();
        vm.startBroadcast();
        (token, curve) = FACTORY.launchToken{value: fee}(params, configId, NVDA);
        vm.stopBroadcast();

        console2.log("Project token:", token);
        console2.log("Pons curve:", curve);
        console2.log("Next: set PROJECT_TOKEN_ADDRESS and run BindLaunch.");
    }
}
