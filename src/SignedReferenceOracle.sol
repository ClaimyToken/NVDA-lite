// SPDX-License-Identifier: MIT
// Website: https://nvdalite.credit/
// X: https://x.com/nvdalite
pragma solidity ^0.8.26;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {IReferenceOracle} from "./interfaces/IReferenceOracle.sol";

/// @notice Immutable-quorum reference tick oracle for the liquidity vault.
/// @dev Anyone may relay a report, but every accepted report must carry enough
/// signatures from the signer set fixed at construction. Signatures must be
/// ordered by recovered signer address so duplicates are impossible.
contract SignedReferenceOracle is IReferenceOracle, EIP712 {
    struct StoredReport {
        int24 tick;
        uint64 observedAt;
        uint64 sequence;
    }

    bytes32 public constant REPORT_TYPEHASH = keccak256(
        "TickReport(bytes32 poolId,int24 tick,uint64 observedAt,uint64 validUntil,uint64 sequence)"
    );
    int24 private constant MIN_TICK = -887272;
    int24 private constant MAX_TICK = 887272;

    uint8 public immutable threshold;
    uint64 public immutable maxReportValidity;
    mapping(address => bool) public isSigner;
    mapping(bytes32 => StoredReport) private reports;

    error InvalidConfiguration();
    error InvalidReport();
    error InsufficientSignatures();
    error SignaturesNotStrictlyOrdered();

    event ReportAccepted(
        bytes32 indexed poolId,
        int24 tick,
        uint64 observedAt,
        uint64 validUntil,
        uint64 sequence
    );

    constructor(address[] memory signers, uint8 threshold_, uint64 maxReportValidity_)
        EIP712("NVDA Signed Reference Oracle", "1")
    {
        if (
            signers.length == 0 || signers.length > type(uint8).max || threshold_ == 0
                || threshold_ > signers.length || maxReportValidity_ == 0
        ) revert InvalidConfiguration();

        address previous;
        for (uint256 i; i < signers.length; ++i) {
            address signer = signers[i];
            // A sorted constructor list makes duplicates obvious and produces a
            // deterministic deployment configuration.
            if (signer == address(0) || signer <= previous) revert InvalidConfiguration();
            isSigner[signer] = true;
            previous = signer;
        }
        threshold = threshold_;
        maxReportValidity = maxReportValidity_;
    }

    /// @notice Returns the latest accepted report for a pool.
    function read(bytes32 poolId) external view returns (int24 tick, uint256 updatedAt) {
        StoredReport memory report = reports[poolId];
        return (report.tick, report.observedAt);
    }

    function latestSequence(bytes32 poolId) external view returns (uint64) {
        return reports[poolId].sequence;
    }

    function hashReport(
        bytes32 poolId,
        int24 tick,
        uint64 observedAt,
        uint64 validUntil,
        uint64 sequence
    ) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(abi.encode(REPORT_TYPEHASH, poolId, tick, observedAt, validUntil, sequence))
        );
    }

    /// @notice Relays a quorum-approved tick report. The relayer needs no role.
    function submit(
        bytes32 poolId,
        int24 tick,
        uint64 observedAt,
        uint64 validUntil,
        uint64 sequence,
        bytes[] calldata signatures
    ) external {
        StoredReport memory current = reports[poolId];
        if (
            poolId == bytes32(0) || tick < MIN_TICK || tick > MAX_TICK || observedAt == 0
                || observedAt > block.timestamp || validUntil < block.timestamp
                || validUntil < observedAt || validUntil - observedAt > maxReportValidity
                || sequence <= current.sequence || observedAt <= current.observedAt
        ) revert InvalidReport();
        if (signatures.length < threshold) revert InsufficientSignatures();

        bytes32 digest = hashReport(poolId, tick, observedAt, validUntil, sequence);
        address previous;
        for (uint256 i; i < signatures.length; ++i) {
            address signer = ECDSA.recover(digest, signatures[i]);
            if (!isSigner[signer]) revert InsufficientSignatures();
            if (signer <= previous) revert SignaturesNotStrictlyOrdered();
            previous = signer;
        }

        reports[poolId] = StoredReport(tick, observedAt, sequence);
        emit ReportAccepted(poolId, tick, observedAt, validUntil, sequence);
    }
}
