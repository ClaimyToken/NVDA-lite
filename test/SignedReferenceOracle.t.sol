// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SignedReferenceOracle} from "../src/SignedReferenceOracle.sol";

contract SignedReferenceOracleTest is Test {
    uint256 private constant KEY_A = 0xA11CE;
    uint256 private constant KEY_B = 0xB0B;
    uint256 private constant KEY_C = 0xCA801;
    bytes32 private constant POOL = keccak256("project/NVDA");

    SignedReferenceOracle private oracle;

    function setUp() public {
        vm.warp(1_800_000_000);
        address[] memory signers = new address[](3);
        signers[0] = vm.addr(KEY_A);
        signers[1] = vm.addr(KEY_B);
        signers[2] = vm.addr(KEY_C);
        _sort(signers);
        oracle = new SignedReferenceOracle(signers, 2, 300);
    }

    function testAnyoneCanRelayQuorumReport() public {
        uint64 observedAt = uint64(block.timestamp - 10);
        uint64 validUntil = uint64(block.timestamp + 60);
        bytes[] memory signatures = _signed(POOL, 1234, observedAt, validUntil, 1, KEY_A, KEY_B);

        vm.prank(address(0x1337));
        oracle.submit(POOL, 1234, observedAt, validUntil, 1, signatures);

        (int24 tick, uint256 updatedAt) = oracle.read(POOL);
        assertEq(tick, 1234);
        assertEq(updatedAt, observedAt);
        assertEq(oracle.latestSequence(POOL), 1);
    }

    function testRejectsOneSignature() public {
        uint64 observedAt = uint64(block.timestamp - 10);
        uint64 validUntil = uint64(block.timestamp + 60);
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = _sign(POOL, 1, observedAt, validUntil, 1, KEY_A);
        vm.expectRevert(SignedReferenceOracle.InsufficientSignatures.selector);
        oracle.submit(POOL, 1, observedAt, validUntil, 1, signatures);
    }

    function testRejectsUnauthorizedSigner() public {
        uint64 observedAt = uint64(block.timestamp - 10);
        uint64 validUntil = uint64(block.timestamp + 60);
        bytes[] memory signatures = _signed(POOL, 1, observedAt, validUntil, 1, KEY_A, 0xBAD);
        vm.expectRevert(SignedReferenceOracle.InsufficientSignatures.selector);
        oracle.submit(POOL, 1, observedAt, validUntil, 1, signatures);
    }

    function testRejectsDuplicateSigner() public {
        uint64 observedAt = uint64(block.timestamp - 10);
        uint64 validUntil = uint64(block.timestamp + 60);
        bytes memory signature = _sign(POOL, 1, observedAt, validUntil, 1, KEY_A);
        bytes[] memory signatures = new bytes[](2);
        signatures[0] = signature;
        signatures[1] = signature;
        vm.expectRevert(SignedReferenceOracle.SignaturesNotStrictlyOrdered.selector);
        oracle.submit(POOL, 1, observedAt, validUntil, 1, signatures);
    }

    function testRejectsExpiredFutureAndOverlongReports() public {
        uint64 observedAt = uint64(block.timestamp - 100);
        bytes[] memory expired = _signed(POOL, 1, observedAt, uint64(block.timestamp - 1), 1, KEY_A, KEY_B);
        vm.expectRevert(SignedReferenceOracle.InvalidReport.selector);
        oracle.submit(POOL, 1, observedAt, uint64(block.timestamp - 1), 1, expired);

        observedAt = uint64(block.timestamp + 1);
        bytes[] memory future = _signed(POOL, 1, observedAt, uint64(block.timestamp + 20), 1, KEY_A, KEY_B);
        vm.expectRevert(SignedReferenceOracle.InvalidReport.selector);
        oracle.submit(POOL, 1, observedAt, uint64(block.timestamp + 20), 1, future);

        observedAt = uint64(block.timestamp - 1);
        bytes[] memory overlong = _signed(POOL, 1, observedAt, uint64(block.timestamp + 300), 1, KEY_A, KEY_B);
        vm.expectRevert(SignedReferenceOracle.InvalidReport.selector);
        oracle.submit(POOL, 1, observedAt, uint64(block.timestamp + 300), 1, overlong);
    }

    function testRejectsReplayAndOlderObservation() public {
        uint64 observedAt = uint64(block.timestamp - 10);
        uint64 validUntil = uint64(block.timestamp + 60);
        bytes[] memory first = _signed(POOL, 1, observedAt, validUntil, 1, KEY_A, KEY_B);
        oracle.submit(POOL, 1, observedAt, validUntil, 1, first);

        vm.expectRevert(SignedReferenceOracle.InvalidReport.selector);
        oracle.submit(POOL, 1, observedAt, validUntil, 1, first);

        bytes[] memory older = _signed(POOL, 2, observedAt - 1, validUntil, 2, KEY_A, KEY_B);
        vm.expectRevert(SignedReferenceOracle.InvalidReport.selector);
        oracle.submit(POOL, 2, observedAt - 1, validUntil, 2, older);
    }

    function testConstructorRejectsUnsortedOrDuplicateSigners() public {
        address[] memory signers = new address[](2);
        signers[0] = vm.addr(KEY_B);
        signers[1] = vm.addr(KEY_A);
        if (signers[0] < signers[1]) (signers[0], signers[1]) = (signers[1], signers[0]);
        vm.expectRevert(SignedReferenceOracle.InvalidConfiguration.selector);
        new SignedReferenceOracle(signers, 2, 300);

        signers[1] = signers[0];
        vm.expectRevert(SignedReferenceOracle.InvalidConfiguration.selector);
        new SignedReferenceOracle(signers, 2, 300);
    }

    function _signed(
        bytes32 poolId,
        int24 tick,
        uint64 observedAt,
        uint64 validUntil,
        uint64 sequence,
        uint256 keyA,
        uint256 keyB
    ) private view returns (bytes[] memory signatures) {
        signatures = new bytes[](2);
        address signerA = vm.addr(keyA);
        address signerB = vm.addr(keyB);
        bytes memory signatureA = _sign(poolId, tick, observedAt, validUntil, sequence, keyA);
        bytes memory signatureB = _sign(poolId, tick, observedAt, validUntil, sequence, keyB);
        if (signerA < signerB) {
            signatures[0] = signatureA;
            signatures[1] = signatureB;
        } else {
            signatures[0] = signatureB;
            signatures[1] = signatureA;
        }
    }

    function _sign(
        bytes32 poolId,
        int24 tick,
        uint64 observedAt,
        uint64 validUntil,
        uint64 sequence,
        uint256 key
    ) private view returns (bytes memory) {
        bytes32 digest = oracle.hashReport(poolId, tick, observedAt, validUntil, sequence);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function _sort(address[] memory addresses) private pure {
        for (uint256 i = 1; i < addresses.length; ++i) {
            address value = addresses[i];
            uint256 j = i;
            while (j > 0 && addresses[j - 1] > value) {
                addresses[j] = addresses[j - 1];
                --j;
            }
            addresses[j] = value;
        }
    }
}
