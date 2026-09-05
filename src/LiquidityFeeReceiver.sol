// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPonsFeeEscrow, IPonsFactory, IPonsCurve, IPonsHook} from "./interfaces/IPons.sol";
import {IReferenceOracle} from "./interfaces/IReferenceOracle.sol";
import {LockedLiquidityVault} from "./LockedLiquidityVault.sol";

/// @notice Pons fee recipient with fixed 50/50 accounting and public execution.
/// @dev Bootstrapper can bind one verified launch only; no further admin powers.
contract LiquidityFeeReceiver is ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Config {
        IPonsFeeEscrow escrow;
        IPonsFactory factory;
        IPoolManager manager;
        IReferenceOracle oracle;
        address hook;
        IERC20 quote;
        address treasury;
        address bootstrapper;
        uint256 minBatch;
        uint256 maxBatch;
    }

    IPonsFeeEscrow public immutable escrow;
    IPonsFactory public immutable factory;
    IPoolManager public immutable manager;
    IReferenceOracle public immutable oracle;
    address public immutable hook;
    IERC20 public immutable quote;
    address public immutable treasury;
    address public immutable bootstrapper;
    uint256 public immutable minBatch;
    uint256 public immutable maxBatch;
    LockedLiquidityVault.Limits private executionLimits;
    address public token;
    address public curve;
    LockedLiquidityVault public vault;
    uint256 public totalClaimed;
    uint256 public liquidityBudget;
    uint256 public treasuryAccrued;
    uint256 public totalTreasuryPaid;
    uint256 public totalSentToVault;

    error InvalidConfiguration();
    error Unauthorized();
    error InvalidLaunch();
    error InexactTransfer();
    error InsufficientBudget();
    event LaunchBound(address indexed token, address indexed vault, bytes32 poolId);
    event FeesClaimed(uint256 received, uint256 liquidityAllocation, uint256 treasuryAllocation);
    event LiquidityDonated(uint256 amount);
    event InjectionCompleted(address indexed caller, uint256 budgetSent, uint128 liquidityAdded);
    event InjectionDeferred(bytes reason);
    event SweepDeferred(bytes reason);
    event TreasuryPaid(uint256 amount);

    constructor(Config memory config, LockedLiquidityVault.Limits memory limits) {
        if (address(config.escrow).code.length == 0 || address(config.factory).code.length == 0
            || address(config.manager).code.length == 0 || address(config.oracle).code.length == 0
            || config.hook.code.length == 0 || address(config.quote).code.length == 0
            || config.treasury == address(0) || config.treasury == address(this)
            || config.bootstrapper == address(0) || config.minBatch == 0 || config.maxBatch < config.minBatch) {
            revert InvalidConfiguration();
        }
        if (config.factory.poolManager() != address(config.manager) || config.factory.memeHook() != config.hook
            || config.factory.feeEscrow() != address(config.escrow)
            || uint160(config.hook) & 0x3fff != 0x2044
            || limits.maxOracleAge == 0 || limits.maxSwapQuote == 0
            || limits.maxSwapQuote > uint256(uint128(type(int128).max))
            || limits.maxTickDeviation <= 0 || limits.maxTickDeviation > 200
            || limits.maxSwapLossBps == 0 || limits.maxSwapLossBps > 500) revert InvalidConfiguration();
        escrow = config.escrow;
        factory = config.factory;
        manager = config.manager;
        oracle = config.oracle;
        hook = config.hook;
        quote = config.quote;
        treasury = config.treasury;
        bootstrapper = config.bootstrapper;
        minBatch = config.minBatch;
        maxBatch = config.maxBatch;
        executionLimits = limits;
    }

    function bindLaunch(address token_) external nonReentrant {
        if (msg.sender != bootstrapper) revert Unauthorized();
        if (token != address(0) || token_ == address(quote) || token_.code.length == 0) revert InvalidLaunch();
        IPonsFactory.Launch memory launch = factory.getLaunchedToken(token_);
        if (!launch.exists || launch.token != token_ || launch.creatorFeeRecipient != address(this)
            || launch.pairToken != address(quote) || launch.buybackEnabled || launch.creatorTaxBps != 100
            || launch.poolFee != 0 || launch.tickSpacing <= 0 || launch.curve.code.length == 0 || launch.phase == 3) {
            revert InvalidLaunch();
        }
        IPonsFactory.FeePolicy memory policy = factory.getLaunchFeePolicy(token_);
        if (policy.hookFeeBps != 100 || policy.protocolFeeShareBps != 3000
            || IPonsCurve(launch.curve).feeBps() != 100) revert InvalidLaunch();
        token = token_;
        curve = launch.curve;
        bool quoteFirst = address(quote) < token_;
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(quoteFirst ? address(quote) : token_),
            currency1: Currency.wrap(quoteFirst ? token_ : address(quote)),
            fee: launch.poolFee, tickSpacing: launch.tickSpacing, hooks: IHooks(hook)
        });
        vault = new LockedLiquidityVault(address(this), manager, oracle, key, quote, executionLimits);
        emit LaunchBound(token_, address(vault), vault.poolId());
    }

    /// @notice Collect already-claimable escrow funds even before binding/graduation.
    function claimFees() external nonReentrant returns (uint256) { return _claim(); }

    /// @notice Attempts an authorized Pons sweep, claims, then tries one bounded batch.
    /// Unsafe/unavailable injections preserve the newly claimed budget for later.
    function claimFeesAndInject() external nonReentrant returns (uint256 claimed, uint128 added) {
        if (token != address(0)) _trySweep();
        claimed = _claim();
        if (token == address(0) || liquidityBudget < minBatch) return (claimed, 0);
        IPonsFactory.Launch memory launch = factory.getLaunchedToken(token);
        if (launch.phase != 2) return (claimed, 0);
        uint256 batch = liquidityBudget < maxBatch ? liquidityBudget : maxBatch;
        try this.executeInjection(batch) returns (uint128 result) {
            added = result;
            emit InjectionCompleted(msg.sender, batch, result);
        } catch (bytes memory reason) {
            emit InjectionDeferred(reason);
        }
    }

    /// @dev External self-call provides atomic rollback of a failed injection only.
    function executeInjection(uint256 batch) external returns (uint128 added) {
        if (msg.sender != address(this)) revert Unauthorized();
        if (batch < minBatch || batch > maxBatch || batch > liquidityBudget) revert InsufficientBudget();
        liquidityBudget -= batch;
        quote.forceApprove(address(vault), batch);
        added = vault.inject(batch);
        quote.forceApprove(address(vault), 0);
        totalSentToVault += batch;
    }

    /// @notice Anyone can deliver the accrued treasury share, only to its fixed address.
    function payTreasury() external nonReentrant returns (uint256 amount) {
        amount = treasuryAccrued;
        treasuryAccrued = 0;
        totalTreasuryPaid += amount;
        if (amount != 0) quote.safeTransfer(treasury, amount);
        emit TreasuryPaid(amount);
    }

    /// @notice Direct quote donations are 100% liquidity funding, never split again.
    function syncDonations() external nonReentrant returns (uint256 amount) {
        amount = quote.balanceOf(address(this)) - liquidityBudget - treasuryAccrued;
        liquidityBudget += amount;
        emit LiquidityDonated(amount);
    }

    function _claim() private returns (uint256 received) {
        if (escrow.balanceOfToken(address(this), address(quote)) == 0) return 0;
        uint256 beforeBalance = quote.balanceOf(address(this));
        uint256 reported = escrow.claimToken(address(quote));
        received = quote.balanceOf(address(this)) - beforeBalance;
        if (reported != received) revert InexactTransfer();
        // Cumulative rounding prevents repeated one-unit claims from changing the split.
        uint256 treasuryShare = (totalClaimed + received) / 2 - totalClaimed / 2;
        totalClaimed += received;
        treasuryAccrued += treasuryShare;
        liquidityBudget += received - treasuryShare;
        emit FeesClaimed(received, received - treasuryShare, treasuryShare);
    }

    function _trySweep() private {
        IPonsFactory.Launch memory launch = factory.getLaunchedToken(token);
        // A Pons recipient redirection does not move our previously accrued budget.
        if (launch.creatorFeeRecipient != address(this)) return;
        if (launch.phase == 0) {
            try IPonsCurve(curve).sweepFees(0) {} catch (bytes memory reason) { emit SweepDeferred(reason); }
        } else if (launch.phase == 2) {
            try IPonsHook(hook).sweepPoolFees(vault.poolId(), 0, 0) {}
            catch (bytes memory reason) { emit SweepDeferred(reason); }
        }
    }
}
