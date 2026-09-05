// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IReferenceOracle} from "./interfaces/IReferenceOracle.sol";

/// @notice Owns a direct v4 core position. There is no NFT, owner, upgrade, rescue,
/// approval, arbitrary call, or negative-liquidity path. Residual assets stay here.
contract LockedLiquidityVault is IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    struct Limits {
        uint256 maxOracleAge;
        uint256 maxSwapQuote;
        int24 maxTickDeviation;
        uint16 maxSwapLossBps;
    }

    uint256 private constant Q96 = 1 << 96;
    bytes32 public constant POSITION_SALT = keccak256("nvda1337.permanent.liquidity.v1");
    address public immutable receiver;
    IPoolManager public immutable manager;
    IReferenceOracle public immutable oracle;
    IERC20 public immutable quote;
    IERC20 public immutable projectToken;
    bool public immutable quoteIs0;
    int24 public immutable tickLower;
    int24 public immutable tickUpper;
    uint256 public immutable maxOracleAge;
    uint256 public immutable maxSwapQuote;
    int24 public immutable maxTickDeviation;
    uint16 public immutable maxSwapLossBps;
    PoolKey public poolKey;
    uint128 public totalLiquidityAdded;
    bool private unlocking;

    error InvalidConfiguration();
    error Unauthorized();
    error InvalidOracle();
    error UnsafePrice();
    error InexactTransfer();
    error NoLiquidity();
    error BadSwap();
    event LiquidityInjected(uint256 quoteReceived, uint128 liquidityAdded, uint256 quoteRemaining, uint256 tokenRemaining);

    constructor(
        address receiver_, IPoolManager manager_, IReferenceOracle oracle_,
        PoolKey memory key_, IERC20 quote_, Limits memory limits
    ) {
        address c0 = Currency.unwrap(key_.currency0);
        address c1 = Currency.unwrap(key_.currency1);
        if (receiver_ == address(0) || address(manager_).code.length == 0 || address(oracle_).code.length == 0
            || c0 == address(0) || c0 >= c1 || (address(quote_) != c0 && address(quote_) != c1)
            || key_.fee != 0 || key_.tickSpacing <= 0 || key_.tickSpacing > 32767
            || limits.maxOracleAge == 0 || limits.maxSwapQuote == 0
            || limits.maxSwapQuote > uint256(uint128(type(int128).max))
            || limits.maxTickDeviation <= 0 || limits.maxTickDeviation > 200
            || limits.maxSwapLossBps == 0 || limits.maxSwapLossBps > 500) revert InvalidConfiguration();
        receiver = receiver_;
        manager = manager_;
        oracle = oracle_;
        poolKey = key_;
        quote = quote_;
        quoteIs0 = address(quote_) == c0;
        projectToken = IERC20(address(quote_) == c0 ? c1 : c0);
        tickLower = TickMath.minUsableTick(key_.tickSpacing);
        tickUpper = TickMath.maxUsableTick(key_.tickSpacing);
        maxOracleAge = limits.maxOracleAge;
        maxSwapQuote = limits.maxSwapQuote;
        maxTickDeviation = limits.maxTickDeviation;
        maxSwapLossBps = limits.maxSwapLossBps;
    }

    function poolId() public view returns (bytes32) { return PoolId.unwrap(poolKey.toId()); }

    function inject(uint256 amount) external nonReentrant returns (uint128 added) {
        if (msg.sender != receiver) revert Unauthorized();
        uint256 beforeBalance = quote.balanceOf(address(this));
        if (amount != 0) quote.safeTransferFrom(receiver, address(this), amount);
        if (quote.balanceOf(address(this)) != beforeBalance + amount) revert InexactTransfer();
        unlocking = true;
        added = abi.decode(manager.unlock(""), (uint128));
        unlocking = false;
        totalLiquidityAdded += added;
        emit LiquidityInjected(amount, added, quote.balanceOf(address(this)), projectToken.balanceOf(address(this)));
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        if (msg.sender != address(manager) || !unlocking) revert Unauthorized();
        // Consume the callback authorization before making external token/hook calls.
        unlocking = false;
        PoolKey memory key = poolKey;
        (int24 referenceTick, uint256 timestamp) = oracle.read(poolId());
        if (timestamp == 0 || timestamp > block.timestamp || block.timestamp - timestamp > maxOracleAge
            || referenceTick <= tickLower + maxTickDeviation || referenceTick >= tickUpper - maxTickDeviation) {
            revert InvalidOracle();
        }
        _checkPrice(key, referenceTick);
        uint160 referencePrice = TickMath.getSqrtPriceAtTick(referenceTick);
        uint256 availableQuote = quote.balanceOf(address(this));
        uint256 tokenValue = _convert(projectToken.balanceOf(address(this)), referencePrice, !quoteIs0);
        // Reuse residual tokens before buying more. Any imbalance remains locked.
        uint256 swapAmount = availableQuote > tokenValue ? (availableQuote - tokenValue) / 2 : 0;
        if (swapAmount > maxSwapQuote) swapAmount = maxSwapQuote;
        if (swapAmount != 0) {
            int24 limitTick = quoteIs0 ? referenceTick - maxTickDeviation : referenceTick + maxTickDeviation;
            BalanceDelta delta = manager.swap(key, SwapParams({
                zeroForOne: quoteIs0,
                amountSpecified: -int256(swapAmount),
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(limitTick)
            }), "");
            int128 input = quoteIs0 ? delta.amount0() : delta.amount1();
            int128 output = quoteIs0 ? delta.amount1() : delta.amount0();
            if (input >= 0 || output <= 0) revert BadSwap();
            uint256 spent = uint256(-int256(input));
            uint256 expected = _convert(spent, referencePrice, quoteIs0);
            uint256 minimum = FullMath.mulDiv(expected, 10000 - maxSwapLossBps, 10000);
            if (spent > swapAmount || minimum == 0 || uint256(uint128(output)) < minimum) revert BadSwap();
            _settle(key.currency0, delta.amount0());
            _settle(key.currency1, delta.amount1());
        }
        uint160 price = _checkPrice(key, referenceTick);
        uint128 liquidity = _liquidityForBalances(key, price);
        if (liquidity == 0) revert NoLiquidity();
        (BalanceDelta added,) = manager.modifyLiquidity(key, ModifyLiquidityParams({
            tickLower: tickLower, tickUpper: tickUpper,
            liquidityDelta: int256(uint256(liquidity)), salt: POSITION_SALT
        }), "");
        _settle(key.currency0, added.amount0());
        _settle(key.currency1, added.amount1());
        _checkPrice(key, referenceTick);
        return abi.encode(liquidity);
    }

    function _checkPrice(PoolKey memory key, int24 referenceTick) private view returns (uint160 price) {
        (uint160 current, int24 tick,,) = manager.getSlot0(key.toId());
        int256 distance = int256(tick) - int256(referenceTick);
        if (current == 0 || distance >= maxTickDeviation || distance <= -int256(maxTickDeviation)) revert UnsafePrice();
        return current;
    }

    function _convert(uint256 amount, uint160 sqrtPrice, bool zeroForOne) private pure returns (uint256) {
        // Same precision split used by Uniswap's oracle quote calculation.
        if (sqrtPrice <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtPrice) * sqrtPrice;
            return zeroForOne ? FullMath.mulDiv(amount, ratioX192, 1 << 192)
                : FullMath.mulDiv(amount, 1 << 192, ratioX192);
        }
        uint256 ratioX128 = FullMath.mulDiv(sqrtPrice, sqrtPrice, 1 << 64);
        return zeroForOne ? FullMath.mulDiv(amount, ratioX128, 1 << 128)
            : FullMath.mulDiv(amount, 1 << 128, ratioX128);
    }

    function _liquidityForBalances(PoolKey memory key, uint160 price) private view returns (uint128) {
        uint160 lower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 upper = TickMath.getSqrtPriceAtTick(tickUpper);
        uint256 amount0 = IERC20(Currency.unwrap(key.currency0)).balanceOf(address(this));
        uint256 amount1 = IERC20(Currency.unwrap(key.currency1)).balanceOf(address(this));
        uint256 l0 = FullMath.mulDiv(amount0, FullMath.mulDiv(price, upper, Q96), upper - price);
        uint256 l1 = FullMath.mulDiv(amount1, Q96, price - lower);
        uint256 result = l0 < l1 ? l0 : l1;
        if (result > uint256(uint128(type(int128).max))) revert NoLiquidity();
        return uint128(result);
    }

    function _settle(Currency currency, int128 delta) private {
        if (delta < 0) {
            uint256 amount = uint256(-int256(delta));
            manager.sync(currency);
            IERC20(Currency.unwrap(currency)).safeTransfer(address(manager), amount);
            if (manager.settle() != amount) revert InexactTransfer();
        } else if (delta > 0) {
            manager.take(currency, address(this), uint256(uint128(delta)));
        }
    }
}
