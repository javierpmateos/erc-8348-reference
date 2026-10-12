// SPDX-License-Identifier: CC0-1.0
// test/liveness/LivenessMatrix.t.sol
pragma solidity ^0.8.24;

import {FinancialLease} from "../../src/FinancialLease.sol";
import {IFinancialLease, INPUT_COLLECTIONS} from "../../src/IFinancialLease.sol";
import {HostileToken} from "../mocks/HostileTokens.sol";
import {LivenessBase} from "./LivenessBase.sol";

/// @title Liveness matrix: external dependency failures vs. adverse transitions
/// @dev Each test takes one dependency the lessee's payment path relies on,
///      makes it fail, and checks two things: can the lessee (or anyone on its
///      behalf) still pay, and can the counterparty still move the lease towards
///      default and termination?
///
///      A row is SAFE when either the payment path stays available or the
///      blocked party suffers nothing irreversible. A row is a KNOWN ISSUE when
///      the payment path is unavailable while declareDefault/terminateForDefault
///      still succeed ("asymmetric liveness"). KNOWN ISSUE tests assert the
///      CURRENT behaviour so the suite stays green and documents it; when the
///      issue is fixed, flip the final assertion and rename the test.
///
///      Background: https://ethereum-magicians.org/t/erc-8348-financial-lease/29076
contract LivenessMatrixTest is LivenessBase {
    // ─── L1: index oracle stale at the due date ── KNOWN ISSUE ───────────────
    function test_L1_KNOWN_ISSUE_staleOracle_blocksPay_defaultProceeds() public {
        vm.warp(uint256(due0) + 1 days); // last observation 31 days old > 7 days

        vm.prank(lessee);
        vm.expectRevert(FinancialLease.StaleOracle.selector);
        lease.pay(id, 100 * UNIT);

        vm.prank(thirdParty);
        vm.expectRevert(FinancialLease.StaleOracle.selector);
        lease.pay(id, 100 * UNIT);

        assertEq(uint8(_status()), uint8(IFinancialLease.LeaseStatus.InArrears));
        uint256 a0 = lease.arrears(id);
        vm.warp(block.timestamp + 1 days);
        assertGt(lease.arrears(id), a0, "penalties accrue while nobody can pay");

        assertTrue(_defaultAndTerminate(), "KNOWN ISSUE: default and termination succeed during the outage");
    }

    // ─── L2: oracle recovers; default in the same block ── KNOWN ISSUE ──────
    function test_L2_KNOWN_ISSUE_oracleRecovery_defaultBeforeLesseeCanPay() public {
        vm.warp(uint256(due0) + 10 days); // outage spans the due date
        oracle.set(1e18); // index recovers in this block

        // The holder acts in the same block, before the lessee's payment lands.
        address holder = lease.ownerOf(id);
        vm.prank(holder);
        lease.declareDefault(id);
        assertEq(uint8(_status()), uint8(IFinancialLease.LeaseStatus.InDefault), "KNOWN ISSUE: no grace after recovery");

        // The lessee's payment in the next transaction cures arrears, but the
        // default declaration (and its timelock anchor) already happened.
        uint256 owed = lease.arrears(id);
        vm.prank(lessee);
        lease.pay(id, owed);
        assertEq(uint8(_status()), uint8(IFinancialLease.LeaseStatus.Completed));
    }

    // ─── L3: lessor-position holder blacklisted by the token ── KNOWN ISSUE ─
    /// @dev The worst row: the counterparty can induce it. Transferring the
    ///      position to an address already blacklisted by the token issuer is
    ///      enough, and the blacklisted holder can still call the lease.
    function test_L3_KNOWN_ISSUE_holderBlacklisted_blocksPay_defaultProceeds() public {
        id = _create(address(0)); // fixed denomination: isolate the token from the oracle
        address blacklistedHolder = makeAddr("blacklistedHolder");
        vm.prank(lessor);
        lease.transferFrom(lessor, blacklistedHolder, id);
        token.setBlacklisted(blacklistedHolder, true);

        vm.warp(uint256(due0) + 1 days);

        vm.prank(lessee);
        vm.expectRevert(abi.encodeWithSelector(HostileToken.Blacklisted.selector, blacklistedHolder));
        lease.pay(id, 100 * UNIT);

        vm.prank(thirdParty);
        vm.expectRevert(abi.encodeWithSelector(HostileToken.Blacklisted.selector, blacklistedHolder));
        lease.pay(id, 100 * UNIT);

        assertTrue(_defaultAndTerminate(), "KNOWN ISSUE: blacklisted holder can default and terminate");
    }

    // ─── L4: payment token globally paused ── KNOWN ISSUE ────────────────────
    function test_L4_KNOWN_ISSUE_tokenPaused_blocksPay_defaultProceeds() public {
        id = _create(address(0));
        vm.warp(uint256(due0) + 1 days);
        token.setPaused(true);

        vm.prank(lessee);
        vm.expectRevert(HostileToken.Paused.selector);
        lease.pay(id, 100 * UNIT);

        assertTrue(_defaultAndTerminate(), "KNOWN ISSUE: default and termination succeed while the token is paused");
    }

    // ─── L5: chain downtime (e.g. L2 sequencer) across the due date ── KNOWN ISSUE
    /// @dev While the chain is down nobody can transact. When it resumes, the
    ///      due date is in the past and the first block belongs to whoever gets
    ///      in first: same shape as L2, with no oracle involved.
    function test_L5_KNOWN_ISSUE_chainDowntime_defaultInFirstBlockAfterResume() public {
        id = _create(address(0));
        vm.warp(uint256(due0) + 2 days); // chain was down from before due0 until now
        address holder = lease.ownerOf(id);
        vm.prank(holder);
        lease.declareDefault(id);
        assertEq(uint8(_status()), uint8(IFinancialLease.LeaseStatus.InDefault), "KNOWN ISSUE: no grace after downtime");
    }

    // ─── L6: lessee itself blacklisted ── SAFE ───────────────────────────────
    /// @dev pay() is permissionless, so anyone not blacklisted can pay on the
    ///      lessee's behalf. Whether that discharges the obligation legally is
    ///      outside the contract.
    function test_L6_SAFE_lesseeBlacklisted_thirdPartyCanPay() public {
        id = _create(address(0));
        token.setBlacklisted(lessee, true);
        vm.warp(uint256(due0) - 1 days);

        vm.prank(lessee);
        vm.expectRevert(abi.encodeWithSelector(HostileToken.Blacklisted.selector, lessee));
        lease.pay(id, 100 * UNIT);

        vm.prank(thirdParty);
        lease.pay(id, 100 * UNIT);
        assertEq(uint8(_status()), uint8(IFinancialLease.LeaseStatus.Completed));
    }

    // ─── L7: stale oracle at purchase-option time ── SAFE ────────────────────
    /// @dev Exercise reverts, but the option has no expiry in the reference
    ///      implementation and Completed is not adverse to the lessee: once the
    ///      index is fresh, the option can be exercised.
    function test_L7_SAFE_staleOracle_purchaseOptionDelayedNotLost() public {
        vm.warp(uint256(due0) - 1 days);
        oracle.set(1e18);
        vm.prank(lessee);
        lease.pay(id, 100 * UNIT);
        assertEq(uint8(_status()), uint8(IFinancialLease.LeaseStatus.Completed));

        vm.warp(block.timestamp + 30 days); // index now stale
        vm.prank(lessee);
        vm.expectRevert(FinancialLease.StaleOracle.selector);
        lease.exercisePurchaseOption(id);

        oracle.set(1e18);
        vm.prank(lessee);
        lease.exercisePurchaseOption(id);
        assertEq(uint8(_status()), uint8(IFinancialLease.LeaseStatus.PurchaseExercised));
    }

    // ─── L8: servicer stops attesting ── SAFE ────────────────────────────────
    /// @dev Servicing inputs are isolated from lease state: a silent servicer
    ///      degrades freshness signals but blocks nothing.
    function test_L8_SAFE_servicerAbsent_noEffectOnPayOrStatus() public {
        (uint64 observedAt, uint64 reportedAt,) = lease.inputFreshness(id, INPUT_COLLECTIONS);
        assertEq(observedAt, 0, "never attested");
        assertEq(reportedAt, 0, "never attested");

        vm.warp(uint256(due0) - 1 days);
        oracle.set(1e18);
        vm.prank(lessee);
        lease.pay(id, 100 * UNIT);
        assertEq(uint8(_status()), uint8(IFinancialLease.LeaseStatus.Completed));
    }
}
