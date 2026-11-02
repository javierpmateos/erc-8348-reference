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
///      CURRENT behaviour so the suite stays green and documents it. Rows marked
///      FIXED were known issues closed by the payment-path liveness rule
///      (A: no default actions while the index is stale; B: none until the
///      index has been continuously fresh for the recovery grace G, with
///      0 < G < tolerance). L3 and L4 (token-side failures) remain open: the
///      spec recommends pull payments for L3; L4 is a documented residual risk.
///
///      Background: https://ethereum-magicians.org/t/erc-8348-financial-lease/29076
contract LivenessMatrixTest is LivenessBase {
    // ─── L1: index oracle stale at the due date ── FIXED (rule A) ────────────
    function test_L1_FIXED_staleOracle_blocksPayAndDefault() public {
        vm.warp(uint256(due0) + 1 days); // last observation 31 days old > 7 days

        vm.prank(lessee);
        vm.expectRevert(FinancialLease.StaleOracle.selector);
        lease.pay(id, 100 * UNIT);

        vm.prank(thirdParty);
        vm.expectRevert(FinancialLease.StaleOracle.selector);
        lease.pay(id, 100 * UNIT);

        assertEq(uint8(_status()), uint8(IFinancialLease.LeaseStatus.InArrears));
        // Arrears keep accruing: the rule restricts default actions, it does
        // not waive penalties (left to the agreement, see the spec).
        uint256 a0 = lease.arrears(id);
        vm.warp(block.timestamp + 1 days);
        assertGt(lease.arrears(id), a0, "penalties accrue while nobody can pay");

        vm.prank(lessor);
        vm.expectRevert(FinancialLease.PaymentPathUnavailable.selector);
        lease.declareDefault(id);
        assertFalse(_defaultAndTerminate(), "no default or termination during the outage");
    }

    // ─── L1b: outage after a valid default blocks termination ── FIXED (A, B)
    function test_L1b_FIXED_staleOracle_blocksTerminationOfExistingDefault() public {
        _keepFresh(uint256(due0) + 1 days);
        vm.prank(lessor);
        lease.declareDefault(id); // index continuously fresh: allowed
        assertEq(uint8(_status()), uint8(IFinancialLease.LeaseStatus.InDefault));

        vm.warp(vm.getBlockTimestamp() + TERMINATION_DELAY + 1 days); // timelock elapsed, index 8 days old
        vm.prank(lessor);
        vm.expectRevert(FinancialLease.PaymentPathUnavailable.selector);
        lease.terminateForDefault(id);

        oracle.set(1e18); // recovery
        vm.prank(lessor);
        vm.expectRevert(FinancialLease.RecoveryGraceActive.selector);
        lease.terminateForDefault(id);

        vm.warp(vm.getBlockTimestamp() + lease.recoveryGrace(id));
        vm.prank(lessor);
        lease.terminateForDefault(id);
        assertEq(uint8(_status()), uint8(IFinancialLease.LeaseStatus.Terminated));
    }

    // ─── L2: oracle recovers; default in the same block ── FIXED (rule B) ────
    function test_L2_FIXED_oracleRecovery_graceLetsLesseePay() public {
        vm.warp(uint256(due0) + 10 days); // outage spans the due date
        oracle.set(1e18); // index recovers in this block

        // The holder tries to act in the same block, before the lessee's payment lands.
        address holder = lease.ownerOf(id);
        vm.prank(holder);
        vm.expectRevert(FinancialLease.RecoveryGraceActive.selector);
        lease.declareDefault(id);

        // The lessee pays in the next transaction and the lease completes.
        uint256 owed = lease.arrears(id);
        vm.prank(lessee);
        lease.pay(id, owed);
        assertEq(uint8(_status()), uint8(IFinancialLease.LeaseStatus.Completed));
    }

    // ─── L2b: the grace is bounded ── FIXED (rule B, 0 < G < tolerance) ──────
    /// @dev With no further attestation after the recovery, the index stays
    ///      fresh for `tolerance` seconds, longer than G, so default becomes
    ///      available again exactly G seconds after the recovery.
    function test_L2b_FIXED_graceIsBoundedAfterRecovery() public {
        uint64 g = lease.recoveryGrace(id);
        assertEq(g, STALENESS / 2, "reference grace = tolerance / 2");

        // Absolute instants derived from due0, never from a saved
        // block.timestamp (see the optimizer note in OracleAdapters.t.sol).
        uint256 r = uint256(due0) + 10 days;
        vm.warp(r);
        oracle.set(1e18);

        vm.warp(r + g - 1);
        vm.prank(lessor);
        vm.expectRevert(FinancialLease.RecoveryGraceActive.selector);
        lease.declareDefault(id);

        vm.warp(r + g);
        vm.prank(lessor);
        lease.declareDefault(id);
        assertEq(uint8(_status()), uint8(IFinancialLease.LeaseStatus.InDefault));
    }

    // ─── L2c: repeated outages delay default but cannot block it ── FIXED ────
    /// @dev Attestations arrive every tolerance + 1 day, so the index goes
    ///      stale in every cycle and each recovery restarts the grace. Because
    ///      G < tolerance, every cycle still opens a window [r + G, r + tolerance]
    ///      in which default is available. (Each outage restarting the grace is
    ///      the open point noted in the spec; a per-installment cap is possible.)
    function test_L2c_FIXED_repeatedOutages_defaultWindowEveryCycle() public {
        uint64 g = lease.recoveryGrace(id);
        for (uint256 c = 0; c < 4; c++) {
            // Previous attestation at r - (STALENESS + 1 days): stale before r.
            uint256 r = uint256(due0) + 1 days + (c + 1) * (STALENESS + 1 days);
            vm.warp(r);
            oracle.set(1e18);

            vm.prank(lessor);
            vm.expectRevert(FinancialLease.RecoveryGraceActive.selector);
            lease.declareDefault(id);

            // Inside [r + G, r + tolerance] default is available; check it and
            // roll back, so the next cycle starts from the same lease state.
            vm.warp(r + g);
            uint256 snap = vm.snapshotState();
            vm.prank(lessor);
            lease.declareDefault(id);
            assertEq(uint8(_status()), uint8(IFinancialLease.LeaseStatus.InDefault), "default available in every cycle");
            vm.revertToState(snap);
        }
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

    // ─── L5: chain downtime across the due date, fixed denomination ── KNOWN ISSUE
    /// @dev While the chain is down nobody can transact. When it resumes, the
    ///      due date is in the past and the first block belongs to whoever gets
    ///      in first. A fixed-denomination lease has no index, so the
    ///      payment-path liveness rule has nothing to measure and does not apply.
    function test_L5_KNOWN_ISSUE_chainDowntime_fixedDenomination_noGrace() public {
        id = _create(address(0));
        vm.warp(uint256(due0) + 2 days); // chain was down from before due0 until now
        address holder = lease.ownerOf(id);
        vm.prank(holder);
        lease.declareDefault(id);
        assertEq(uint8(_status()), uint8(IFinancialLease.LeaseStatus.InDefault), "KNOWN ISSUE: no grace after downtime");
    }

    // ─── L5b: chain downtime longer than the tolerance, indexed lease ── FIXED
    /// @dev The index feed cannot update while the chain is down either, so a
    ///      downtime longer than the tolerance leaves a gap in the oracle's
    ///      history and the recovery grace applies. A downtime shorter than the
    ///      tolerance leaves no gap and gets no grace (same as L5).
    function test_L5b_FIXED_longDowntime_indexedLeaseGetsGrace() public {
        _keepFresh(uint256(due0) - 1 days);
        vm.warp(uint256(due0) + 8 days); // down for 9 days > 7-day tolerance
        address holder = lease.ownerOf(id);

        vm.prank(holder);
        vm.expectRevert(FinancialLease.PaymentPathUnavailable.selector);
        lease.declareDefault(id); // first block, before the feed updates

        oracle.set(1e18); // feed updates in the same block
        vm.prank(holder);
        vm.expectRevert(FinancialLease.RecoveryGraceActive.selector);
        lease.declareDefault(id);

        uint256 owed = lease.arrears(id);
        vm.prank(lessee);
        lease.pay(id, owed);
        assertEq(uint8(_status()), uint8(IFinancialLease.LeaseStatus.Completed));
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
