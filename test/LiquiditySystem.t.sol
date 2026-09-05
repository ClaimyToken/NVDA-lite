// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IPonsFeeEscrow, IPonsFactory} from "../src/interfaces/IPons.sol";
import {IReferenceOracle} from "../src/interfaces/IReferenceOracle.sol";
import {LiquidityFeeReceiver} from "../src/LiquidityFeeReceiver.sol";
import {LockedLiquidityVault} from "../src/LockedLiquidityVault.sol";

contract MockToken is ERC20 {
    address public reentryTarget;
    address public reentryFrom;
    constructor() ERC20("test", "TEST") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function attack(address from, address target) external { reentryFrom = from; reentryTarget = target; }
    function _update(address from, address to, uint256 amount) internal override {
        super._update(from, to, amount);
        if (from == reentryFrom && reentryTarget != address(0)) {
            LiquidityFeeReceiver(reentryTarget).claimFeesAndInject();
        }
    }
}

contract MockEscrow is IPonsFeeEscrow {
    mapping(address => mapping(address => uint256)) private balances;
    function credit(address recipient, MockToken asset, uint256 amount) external {
        asset.mint(address(this), amount);
        balances[recipient][address(asset)] += amount;
    }
    function balanceOfToken(address recipient, address asset) external view returns (uint256) {
        return balances[recipient][asset];
    }
    function claimToken(address asset) external returns (uint256 amount) {
        amount = balances[msg.sender][asset];
        balances[msg.sender][asset] = 0;
        IERC20(asset).transfer(msg.sender, amount);
    }
}

contract MockFactory is IPonsFactory {
    Launch private launch;
    address public poolManager;
    address public memeHook;
    address public feeEscrow;
    function configure(address manager, address hook, address escrow) external {
        poolManager = manager; memeHook = hook; feeEscrow = escrow;
    }
    function getLaunchFeePolicy(address) external pure returns (FeePolicy memory) {
        return FeePolicy(address(1), 3000, 0, 100, 100);
    }
    function set(Launch memory next) external { launch = next; }
    function setPhase(uint8 phase) external { launch.phase = phase; }
    function getLaunchedToken(address) external view returns (Launch memory) { return launch; }
}

contract MockOracle is IReferenceOracle {
    int24 public tick;
    uint256 public timestamp;
    function set(int24 nextTick, uint256 nextTimestamp) external { tick = nextTick; timestamp = nextTimestamp; }
    function read(bytes32) external view returns (int24, uint256) { return (tick, timestamp); }
}

contract MockPonsHook {
    function feeBps() external pure returns (uint256) { return 100; }
    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        return IHooks.beforeInitialize.selector;
    }
    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external returns (bytes4, int128)
    {
        int128 out = params.zeroForOne ? delta.amount1() : delta.amount0();
        int128 fee = out * 2 / 100;
        IPoolManager(msg.sender).take(params.zeroForOne ? key.currency1 : key.currency0, address(this), uint128(fee));
        return (IHooks.afterSwap.selector, fee);
    }
    function sweepFees(uint256) external pure { revert("operator pending"); }
    function sweepPoolFees(bytes32, uint256, uint256) external pure { revert("operator pending"); }
}

contract LiquiditySystemTest is Test {
    using StateLibrary for IPoolManager;
    MockToken internal quote;
    MockToken internal project;
    MockEscrow internal escrow;
    MockFactory internal factory;
    MockOracle internal oracle;
    IPoolManager internal manager;
    LiquidityFeeReceiver internal receiver;
    LockedLiquidityVault internal vault;
    PoolKey internal key;
    PoolModifyLiquidityTest internal seed;
    PoolSwapTest internal swapper;
    address internal constant HOOK = address(0x2044);
    address internal constant TREASURY = address(0xBEEF);
    address internal constant PUBLIC = address(0xCAFE);

    function setUp() public {
        vm.warp(10000);
        quote = new MockToken();
        project = new MockToken();
        escrow = new MockEscrow();
        factory = new MockFactory();
        oracle = new MockOracle();
        oracle.set(0, block.timestamp);
        manager = new PoolManager(address(this));
        MockPonsHook hookImplementation = new MockPonsHook();
        vm.etch(HOOK, address(hookImplementation).code);
        factory.configure(address(manager), HOOK, address(escrow));
        receiver = new LiquidityFeeReceiver(LiquidityFeeReceiver.Config({
            escrow: escrow, factory: factory, manager: manager, oracle: oracle, hook: HOOK,
            quote: quote, treasury: TREASURY, bootstrapper: address(this), minBatch: 1e12, maxBatch: 100e18
        }), LockedLiquidityVault.Limits({maxOracleAge: 300, maxSwapQuote: 50e18, maxTickDeviation: 100, maxSwapLossBps: 300}));
        factory.set(IPonsFactory.Launch({
            token: address(project), curve: HOOK, deployer: address(this), creatorFeeRecipient: address(receiver),
            pairToken: address(quote), graduationThreshold: 1, poolFee: 0, tickSpacing: 200,
            creatorTaxBps: 100, buybackEnabled: false, phase: 0, sweptQuote: 0, sweptTokens: 0, sweptAt: 0, exists: true
        }));
        receiver.bindLaunch(address(project));
        vault = receiver.vault();
        bool quoteFirst = address(quote) < address(project);
        key = PoolKey(Currency.wrap(quoteFirst ? address(quote) : address(project)),
            Currency.wrap(quoteFirst ? address(project) : address(quote)), 0, 200, IHooks(HOOK));
        manager.initialize(key, uint160(1 << 96));
        seed = new PoolModifyLiquidityTest(manager);
        swapper = new PoolSwapTest(manager);
        quote.mint(address(this), 1e27);
        project.mint(address(this), 1e27);
        quote.approve(address(seed), type(uint256).max);
        project.approve(address(seed), type(uint256).max);
        quote.approve(address(swapper), type(uint256).max);
        project.approve(address(swapper), type(uint256).max);
        seed.modifyLiquidity(key, ModifyLiquidityParams(-887200, 887200, 1e24, bytes32(0)), "");
    }

    function testPublicClaimBeforeGraduationAndTreasuryPayment() public {
        escrow.credit(address(receiver), quote, 100e18);
        vm.prank(PUBLIC);
        receiver.claimFeesAndInject();
        assertEq(receiver.liquidityBudget(), 50e18);
        assertEq(receiver.treasuryAccrued(), 50e18);
        assertEq(vault.totalLiquidityAdded(), 0);
        vm.prank(PUBLIC);
        receiver.payTreasury();
        assertEq(quote.balanceOf(TREASURY), 50e18);
        assertEq(quote.balanceOf(PUBLIC), 0);
        assertEq(quote.balanceOf(address(receiver)), 50e18);
    }

    function testPublicInjectionWithRealV4AndHookFee() public {
        factory.setPhase(2);
        escrow.credit(address(receiver), quote, 100e18);
        vm.prank(PUBLIC);
        (uint256 claimed, uint128 added) = receiver.claimFeesAndInject();
        assertEq(claimed, 100e18);
        assertGt(added, 0);
        assertEq(receiver.liquidityBudget(), 0);
        assertEq(receiver.treasuryAccrued(), 50e18);
        assertEq(receiver.totalSentToVault(), 50e18);
        assertEq(quote.allowance(address(receiver), address(vault)), 0);
        (uint128 position,,) = manager.getPositionInfo(key.toId(), address(vault), vault.tickLower(), vault.tickUpper(), vault.POSITION_SALT());
        assertEq(position, added);
        assertGt(project.balanceOf(HOOK), 0);
        assertEq(quote.balanceOf(PUBLIC), 0);
    }

    function testExistingBudgetInjectsWithoutNewEscrowFees() public {
        escrow.credit(address(receiver), quote, 100e18);
        receiver.claimFees();
        factory.setPhase(2);
        (uint256 claimed, uint128 added) = receiver.claimFeesAndInject();
        assertEq(claimed, 0);
        assertGt(added, 0);
        assertEq(receiver.treasuryAccrued(), 50e18);
    }

    function testRepeatedInjectionsIncreaseSameLockedPosition() public {
        factory.setPhase(2);
        escrow.credit(address(receiver), quote, 100e18);
        receiver.claimFeesAndInject();
        uint128 first = vault.totalLiquidityAdded();
        escrow.credit(address(receiver), quote, 100e18);
        receiver.claimFeesAndInject();
        (uint128 position,,) = manager.getPositionInfo(key.toId(), address(vault), vault.tickLower(), vault.tickUpper(), vault.POSITION_SALT());
        assertGt(position, first);
        assertEq(position, vault.totalLiquidityAdded());
        assertEq(receiver.treasuryAccrued(), 100e18);
    }

    function testVaultSupportsOppositeQuoteCurrencyOrdering() public {
        LockedLiquidityVault other = new LockedLiquidityVault(address(this), manager, oracle, key,
            project, LockedLiquidityVault.Limits(300, 50e18, 100, 300));
        assertTrue(other.quoteIs0() != vault.quoteIs0());
        project.approve(address(other), 50e18);
        assertGt(other.inject(50e18), 0);
    }

    function testRescuedLaunchKeepsLiquidityBudgetAndAllowsTreasury() public {
        factory.setPhase(3);
        escrow.credit(address(receiver), quote, 100e18);
        receiver.claimFeesAndInject();
        receiver.payTreasury();
        assertEq(receiver.liquidityBudget(), 50e18);
        assertEq(vault.totalLiquidityAdded(), 0);
        assertEq(quote.balanceOf(TREASURY), 50e18);
    }

    function testFuzzInjectedFundsConservation(uint64 rawAmount) public {
        uint256 amount = bound(uint256(rawAmount), 2e12, 10e18);
        factory.setPhase(2);
        escrow.credit(address(receiver), quote, amount);
        receiver.claimFeesAndInject();
        receiver.payTreasury();
        assertGt(vault.totalLiquidityAdded(), 0);
        assertEq(receiver.totalSentToVault() + receiver.liquidityBudget() + receiver.totalTreasuryPaid(), amount);
        assertEq(receiver.totalTreasuryPaid(), amount / 2);
        assertEq(quote.balanceOf(address(receiver)), receiver.liquidityBudget());
    }

    function testStaleOraclePreservesClaimsAndApprovalsRollback() public {
        factory.setPhase(2);
        oracle.set(0, block.timestamp - 301);
        escrow.credit(address(receiver), quote, 100e18);
        receiver.claimFeesAndInject();
        assertEq(receiver.totalClaimed(), 100e18);
        assertEq(receiver.liquidityBudget(), 50e18);
        assertEq(receiver.treasuryAccrued(), 50e18);
        assertEq(quote.balanceOf(address(vault)), 0);
        assertEq(quote.allowance(address(receiver), address(vault)), 0);
        oracle.set(0, block.timestamp);
        (, uint128 added) = receiver.claimFeesAndInject();
        assertGt(added, 0);
    }

    function testManipulatedPoolPriceDefersInjection() public {
        factory.setPhase(2);
        swapper.swap(key, SwapParams(true, -int256(1e23), TickMath.getSqrtPriceAtTick(-1000)),
            PoolSwapTest.TestSettings(false, false), "");
        escrow.credit(address(receiver), quote, 100e18);
        receiver.claimFeesAndInject();
        assertEq(vault.totalLiquidityAdded(), 0);
        assertEq(receiver.liquidityBudget(), 50e18);
    }

    function testFutureOracleDefersInjection() public {
        factory.setPhase(2);
        oracle.set(0, block.timestamp + 1);
        escrow.credit(address(receiver), quote, 100e18);
        receiver.claimFeesAndInject();
        assertEq(receiver.liquidityBudget(), 50e18);
        assertEq(vault.totalLiquidityAdded(), 0);
    }

    function testReentrancyDuringSettlementRollsBackInjectionOnly() public {
        factory.setPhase(2);
        quote.attack(address(vault), address(receiver));
        escrow.credit(address(receiver), quote, 100e18);
        receiver.claimFeesAndInject();
        assertEq(receiver.liquidityBudget(), 50e18);
        assertEq(receiver.treasuryAccrued(), 50e18);
        assertEq(quote.balanceOf(address(vault)), 0);
        assertEq(vault.totalLiquidityAdded(), 0);
    }

    function testDirectDonationsNeverSplitOrResplit() public {
        quote.mint(address(receiver), 7e18);
        receiver.syncDonations();
        receiver.syncDonations();
        escrow.credit(address(receiver), quote, 100e18);
        receiver.claimFees();
        receiver.syncDonations();
        assertEq(receiver.liquidityBudget(), 57e18);
        assertEq(receiver.treasuryAccrued(), 50e18);
    }

    function testDeveloperPayoutCannotWithdrawReservedLiquidityOrPayCaller() public {
        escrow.credit(address(receiver), quote, 100e18);
        receiver.claimFees();
        vm.prank(PUBLIC);
        receiver.payTreasury();
        vm.prank(TREASURY);
        receiver.payTreasury();
        assertEq(quote.balanceOf(TREASURY), 50e18);
        assertEq(quote.balanceOf(PUBLIC), 0);
        assertEq(receiver.treasuryAccrued(), 0);
        assertEq(receiver.liquidityBudget(), 50e18);
        assertEq(quote.balanceOf(address(receiver)), 50e18);
        factory.setPhase(2);
        (, uint128 added) = receiver.claimFeesAndInject();
        assertGt(added, 0);
        vm.prank(TREASURY);
        receiver.payTreasury();
        assertEq(quote.balanceOf(TREASURY), 50e18);
        assertEq(vault.totalLiquidityAdded(), added);
    }

    function testBatchCapLeavesBudget() public {
        factory.setPhase(2);
        escrow.credit(address(receiver), quote, 1000e18);
        receiver.claimFeesAndInject();
        assertEq(receiver.totalSentToVault(), 100e18);
        assertEq(receiver.liquidityBudget(), 400e18);
        assertEq(receiver.treasuryAccrued(), 500e18);
    }

    function testUntrustedCallersCannotBindExecuteOrEnterCallback() public {
        vm.prank(PUBLIC);
        vm.expectRevert(LiquidityFeeReceiver.Unauthorized.selector);
        receiver.bindLaunch(address(project));
        vm.expectRevert(LiquidityFeeReceiver.InvalidLaunch.selector);
        receiver.bindLaunch(address(project));
        vm.expectRevert(LiquidityFeeReceiver.Unauthorized.selector);
        receiver.executeInjection(100e18);
        vm.expectRevert(LockedLiquidityVault.Unauthorized.selector);
        vault.inject(0);
        vm.expectRevert(LockedLiquidityVault.Unauthorized.selector);
        vault.unlockCallback("");
        vm.prank(address(manager));
        vm.expectRevert(LockedLiquidityVault.Unauthorized.selector);
        vault.unlockCallback("");
    }

    function testFuzzSplitConservationWithOddClaims(uint96 a, uint96 b) public {
        escrow.credit(address(receiver), quote, a);
        receiver.claimFees();
        receiver.payTreasury();
        escrow.credit(address(receiver), quote, b);
        receiver.claimFees();
        uint256 total = uint256(a) + b;
        assertEq(receiver.totalClaimed(), total);
        assertEq(receiver.totalTreasuryPaid() + receiver.treasuryAccrued(), total / 2);
        assertEq(receiver.liquidityBudget(), total - total / 2);
        assertEq(quote.balanceOf(address(receiver)), receiver.liquidityBudget() + receiver.treasuryAccrued());
    }
}
