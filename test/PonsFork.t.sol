// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPonsFeeEscrow, IPonsFactory, IPonsLaunchFactory, IPonsCurve} from "../src/interfaces/IPons.sol";
import {LiquidityFeeReceiver} from "../src/LiquidityFeeReceiver.sol";
import {LockedLiquidityVault} from "../src/LockedLiquidityVault.sol";
import {MockToken, MockOracle} from "./LiquiditySystem.t.sol";

interface ITokenCredit { function creditToken(address recipient, address token, uint256 amount) external; }

/// @dev RPC reads only. All crediting, swaps and deposits occur inside a local fork.
contract PonsForkTest is Test {
    using StateLibrary for IPoolManager;
    IPonsFactory constant FACTORY = IPonsFactory(0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e);
    IPonsLaunchFactory constant LAUNCH_FACTORY = IPonsLaunchFactory(0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e);
    address constant EXISTING_TOKEN = 0x28BfF607409535285A5392f0b79516673b6072ac;
    address constant DEPLOYER = 0xC5DA7bdcCf0F934d725D358C8c1E24a1eA3E6973;

    function setUp() public {
        string memory rpc = vm.envOr("PONS_RPC_URL", string(""));
        if (bytes(rpc).length == 0) { vm.skip(true); return; }
        uint256 pinnedBlock = vm.envOr("PONS_FORK_BLOCK", uint256(0));
        if (pinnedBlock == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, pinnedBlock);
        assertEq(block.chainid, 4663);
        emit log_named_uint("Fork block", block.number);
    }

    function testForkRealEscrowClaimsForContractRecipient() public {
        MockToken quote = new MockToken();
        MockOracle oracle = new MockOracle();
        IPonsFeeEscrow escrow = IPonsFeeEscrow(FACTORY.feeEscrow());
        LiquidityFeeReceiver receiver = new LiquidityFeeReceiver(LiquidityFeeReceiver.Config({
            escrow: escrow, factory: FACTORY, manager: IPoolManager(FACTORY.poolManager()), oracle: oracle,
            hook: FACTORY.memeHook(), quote: quote, treasury: address(0xBEEF), bootstrapper: address(this),
            minBatch: 1e12, maxBatch: 100e18
        }), LockedLiquidityVault.Limits(300, 50e18, 100, 300));
        quote.mint(address(this), 100e18);
        quote.approve(address(escrow), 100e18);
        ITokenCredit(address(escrow)).creditToken(address(receiver), address(quote), 100e18);
        assertEq(escrow.balanceOfToken(address(receiver), address(quote)), 100e18);
        // A bystander has no claim on the receiver's balance.
        vm.prank(address(0xCAFE));
        (bool success,) = address(escrow).call(abi.encodeCall(IPonsFeeEscrow.claimToken, (address(quote))));
        // Zero-balance claims may return zero or revert; neither can take our funds.
        success;
        assertEq(quote.balanceOf(address(0xCAFE)), 0);
        assertEq(escrow.balanceOfToken(address(receiver), address(quote)), 100e18);
        vm.prank(address(0xCAFE));
        receiver.claimFeesAndInject();
        assertEq(receiver.totalClaimed(), 100e18);
        assertEq(receiver.liquidityBudget(), 50e18);
        assertEq(receiver.treasuryAccrued(), 50e18);
        assertEq(escrow.balanceOfToken(address(receiver), address(quote)), 0);
    }

    function testForkCreateNewPonsLaunchAndBindPermanentVault() public {
        assertTrue(LAUNCH_FACTORY.canLaunch(DEPLOYER));
        assertTrue(LAUNCH_FACTORY.approvedPairTokens(0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC));
        MockOracle oracle = new MockOracle();
        LiquidityFeeReceiver receiver = new LiquidityFeeReceiver(LiquidityFeeReceiver.Config({
            escrow: IPonsFeeEscrow(FACTORY.feeEscrow()), factory: FACTORY,
            manager: IPoolManager(FACTORY.poolManager()), oracle: oracle,
            hook: FACTORY.memeHook(), quote: IERC20(0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC),
            treasury: DEPLOYER, bootstrapper: DEPLOYER, minBatch: 1e12, maxBatch: 100e18
        }), LockedLiquidityVault.Limits(300, 50e18, 100, 300));

        uint256 configId = 0;
        IPonsLaunchFactory.LaunchConfig memory config = LAUNCH_FACTORY.getLaunchConfig(configId);
        assertTrue(config.enabled);
        assertEq(config.curveFeeBps, 100);
        assertEq(config.poolFee, 0);
        IPonsLaunchFactory.TokenParams memory params = IPonsLaunchFactory.TokenParams({
            name: "no value digital asset",
            symbol: "NVDA1337",
            logo: "ipfs://test-only",
            description: "Fund the liquidity of this no value digital asset.",
            socials: IPonsLaunchFactory.Socials("", "", "", "", ""),
            creatorFeeRecipient: address(receiver),
            creatorTaxBps: 100,
            buybackEnabled: false,
            expectedEconomics: LAUNCH_FACTORY.previewLaunchEconomics(configId, address(receiver.quote())),
            salt: keccak256("nvda1337.local-fork-only")
        });

        vm.deal(DEPLOYER, 1 ether);
        vm.prank(DEPLOYER);
        (address token,) = LAUNCH_FACTORY.launchToken{value: LAUNCH_FACTORY.launchFee()}(
            params, configId, address(receiver.quote())
        );
        IPonsFactory.Launch memory launch = FACTORY.getLaunchedToken(token);
        assertTrue(launch.exists);
        assertEq(launch.creatorFeeRecipient, address(receiver));
        assertEq(launch.pairToken, address(receiver.quote()));
        assertEq(launch.creatorTaxBps, 100);
        assertFalse(launch.buybackEnabled);

        vm.prank(DEPLOYER);
        receiver.bindLaunch(token);
        assertEq(receiver.token(), token);
        assertTrue(address(receiver.vault()).code.length != 0);
        assertEq(address(receiver.vault().oracle()), address(oracle));
        assertEq(address(receiver.vault().quote()), address(receiver.quote()));
        assertEq(address(receiver.vault().projectToken()), token);
    }

    function testForkAddAndIncreaseAgainstRealPonsHookAndNVDA() public {
        IPonsFactory.Launch memory launch = FACTORY.getLaunchedToken(EXISTING_TOKEN);
        assertEq(launch.phase, 2);
        assertEq(IPonsCurve(launch.curve).feeBps(), 100);
        IPonsFactory.FeePolicy memory policy = FACTORY.getLaunchFeePolicy(EXISTING_TOKEN);
        assertEq(policy.hookFeeBps, 100);
        assertEq(policy.protocolFeeShareBps, 3000);
        assertEq(launch.pairToken, 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC);
        IPoolManager manager = IPoolManager(FACTORY.poolManager());
        bool quoteFirst = launch.pairToken < EXISTING_TOKEN;
        PoolKey memory key = PoolKey(Currency.wrap(quoteFirst ? launch.pairToken : EXISTING_TOKEN),
            Currency.wrap(quoteFirst ? EXISTING_TOKEN : launch.pairToken), launch.poolFee, launch.tickSpacing, IHooks(FACTORY.memeHook()));
        (, int24 tick,,) = manager.getSlot0(key.toId());
        MockOracle oracle = new MockOracle();
        oracle.set(tick, block.timestamp);
        LockedLiquidityVault vault = new LockedLiquidityVault(address(this), manager, oracle, key,
            IERC20(launch.pairToken), LockedLiquidityVault.Limits(300, 1e12, 100, 300));
        deal(launch.pairToken, address(this), 2e12);
        IERC20(launch.pairToken).approve(address(vault), 2e12);
        uint128 first = vault.inject(1e12);
        uint128 second = vault.inject(1e12);
        assertGt(first, 0);
        assertGt(second, 0);
        (uint128 actual,,) = manager.getPositionInfo(key.toId(), address(vault), vault.tickLower(), vault.tickUpper(), vault.POSITION_SALT());
        assertEq(actual, uint256(first) + second);
    }
}
