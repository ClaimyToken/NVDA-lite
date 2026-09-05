// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Deployment prerequisite: an independently secured, pool-specific reference.
/// @dev Tick is log_1.0001(raw token1 / raw token0), with Uniswap currency ordering.
/// A spot-price reader or an unrestricted writer MUST NOT be used in production.
interface IReferenceOracle {
    function read(bytes32 poolId) external view returns (int24 tick, uint256 updatedAt);
}
