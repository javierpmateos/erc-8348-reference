// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IFinancialLease} from "../../src/IFinancialLease.sol";
import {MockUVAOracle} from "../../src/MockUVAOracle.sol";
import {HostileToken} from "../../test/mocks/HostileTokens.sol";
import {FinancialLeaseBase} from "../liveness-variants/FinancialLeaseBase.sol";
import {VariantA, VariantB, VariantBUnbounded, VariantC, VariantD} from "../liveness-variants/Variants.sol";
import {HistoricalAttestedOracle} from "../liveness-variants/HistoricalAttestedOracle.sol";

/// @title Common battery for the liveness variants — EXPERIMENT ONLY
/// @dev Every P-test asserts the DESIRED property. A failing P-test means the
///      variant does not close that case; that is the expected way to read the
///      comparison. Run with:  FOUNDRY_PROFILE=experiments forge test
abstract contract Battery is Test {
    FinancialLeaseBase internal lease;
    HostileToken internal token;
    address internal oracle;

    address internal lessor = makeAddr("lessor");
    address internal lessee = makeAddr("lessee");
    address internal thirdParty = makeAddr("thirdParty");
    uint256 internal constant UNIT = 1e18;
    uint64 internal constant STALENESS = 7 days;

    uint256 internal id;
    uint64 internal due0;

    function _deploy() internal virtual returns (FinancialLeaseBase);
    function _newOracle() internal virtual returns (address) {
        return address(new MockUVAOracle(1e18));
    }
    function _refresh() internal virtual {
        MockUVAOracle(oracle).set(1e18);
    }

    function setUp() public virtual {
        _warp(1_000_000);
        lease = _deploy();
        token = new HostileToken();
        oracle = _newOracle();
        token.mint(lessee, 1_000_000 * UNIT);
        token.mint(thirdParty, 1_000_000 * UNIT);
        vm.prank(lessee);
        token.approve(address(lease), type(uint256).max);
        vm.prank(thirdParty);
        token.approve(address(lease), type(uint256).max);
        due0 = uint64(block.timestamp + 30 days);
        id = _create(oracle);
    }

    function _create(address oracle_) internal returns (uint256 leaseId) {
        uint64[] memory dd = new uint64[](2);
        dd[0] = due0;
        dd[1] = due0 + 30 days;
        uint256[] memory ua = new uint256[](2);
        ua[0] = 100 * UNIT;
        ua[1] = 100 * UNIT;
        FinancialLeaseBase.CreateLeaseParams memory p = FinancialLeaseBase.CreateLeaseParams({
            lessee: lessee, jurisdiction: bytes2("AR"), governingLaw: "test", agreementHash: bytes32(0),
            assetRef: "asset://variant", paymentAsset: address(token), denomSymbol: "UVA", oracle: oracle_,
            maxStaleness: oracle_ == address(0) ? 0 : STALENESS, dueDates: dd, unitAmounts: ua,
            purchasePriceUnits: 1 * UNIT, penaltyBpsPerDay: 10, defaultDeclarer: address(0),
            terminationDelay: 7 days, anchorChainId: 0, anchorRegistry: address(0), anchorId: bytes32(0),
            servicer: address(0), servicingInputs: new bytes32[](0), servicingMaxStaleness: new uint64[](0)
        });
        vm.prank(lessor);
        leaseId = lease.createLease(p);
    }

    /// @dev Keeps the index fresh by attesting once a day up to `until`.
    /// @dev Time is tracked in `now_` and not re-read from block.timestamp:
    ///      under via-ir the optimizer may treat block.timestamp as constant
    ///      within a call, so a loop that re-reads it after vm.warp never ends.
    uint256 internal now_ = 1_000_000;

    function _warp(uint256 t) internal {
        now_ = t;
        vm.warp(t);
    }

    function _keepFreshUntil(uint256 until) internal {
        uint256 t = now_;
        while (t + 1 days <= until) {
            t += 1 days;
            _warp(t);
            _refresh();
        }
        _warp(until);
        _refresh();
    }

    function _tryDefault() internal returns (bool) {
        address holder = lease.ownerOf(id);
        vm.prank(holder);
        try lease.declareDefault(id) { return true; } catch { return false; }
    }

    // ─── P0: a genuine default still works (no regression) ───────────────
    function test_P0_genuineDefaultStillWorks() public {
        _keepFreshUntil(uint256(due0) + 5 days); // index fresh throughout, lessee simply did not pay
        assertTrue(_tryDefault(), "a lessee that simply did not pay can still be defaulted");
    }

    // ─── P1: index stale at the due date ─────────────────────────────────
    function test_P1_noDefaultWhileIndexStale() public {
        _warp(uint256(due0) + 1 days);
        assertFalse(_tryDefault(), "default must not succeed while the index is stale");
    }

    // ─── P2: recovery race ───────────────────────────────────────────────
    /// @dev The lessee tries to pay during the outage (pay() is called; in
    ///      variants that reject it, the attempt leaves no trace). Then the
    ///      index recovers and the holder acts in that same block.
    function test_P2_noDefaultInRecoveryBlock() public {
        _warp(uint256(due0) + 2 days);
        vm.prank(lessee);
        try lease.pay(id, 150 * UNIT) {} catch {}
        _warp(now_ + 3 days);
        _refresh();
        assertFalse(_tryDefault(), "default must not succeed in the block the index recovers");
    }

    // ─── P3: lessor-position holder blacklisted by the token ─────────────
    function test_P3_payWorksWhenHolderBlacklisted() public {
        _keepFreshUntil(uint256(due0) - 1 days);
        address sanctioned = makeAddr("sanctioned");
        vm.prank(lessor);
        lease.transferFrom(lessor, sanctioned, id);
        token.setBlacklisted(sanctioned, true);
        vm.prank(lessee);
        (bool ok,) = address(lease).call(abi.encodeWithSelector(lease.pay.selector, id, 100 * UNIT));
        assertTrue(ok, "the lessee must be able to pay even if the holder is blacklisted");
    }

    // ─── P4: payment token paused ────────────────────────────────────────
    function test_P4_noDefaultWhileTokenPaused() public {
        _keepFreshUntil(uint256(due0) + 1 days);
        token.setPaused(true);
        assertFalse(_tryDefault(), "default must not succeed while the payment token is paused");
    }

    // ─── G: gas of an ordinary on-time payment ───────────────────────────
    function test_G_gasOrdinaryPayment() public {
        _keepFreshUntil(uint256(due0) - 1 days);
        vm.prank(lessee);
        uint256 g = gasleft();
        lease.pay(id, 100 * UNIT);
        console2.log("gas, ordinary pay():", g - gasleft());
    }
}

contract BatteryReference is Battery {
    function _deploy() internal override returns (FinancialLeaseBase) {
        return new FinancialLeaseBase();
    }
}

contract BatteryA is Battery {
    function _deploy() internal override returns (FinancialLeaseBase) {
        return new VariantA();
    }
}

contract BatteryB is Battery {
    function _deploy() internal override returns (FinancialLeaseBase) {
        return new VariantB();
    }
    function _newOracle() internal override returns (address) {
        return address(new HistoricalAttestedOracle(1e18));
    }
    function _refresh() internal override {
        HistoricalAttestedOracle(oracle).attest(1e18);
    }

    /// @dev Index attested every 8 days against a 7-day tolerance: it is
    ///      stale for one day before each attestation, then fresh for 7 days.
    function _lateAttestationsUntil(uint256 until) internal returns (uint256 last) {
        last = now_;
        while (last < until) {
            last += 8 days;
            _warp(last);
            _refresh();
        }
    }

    function _defaultPossibleAt(uint256 t) internal returns (bool ok) {
        uint256 snap = vm.snapshotState();
        _warp(t);
        ok = _tryDefault();
        vm.revertToState(snap);
    }

    /// X-B1: with late attestations, default is delayed by at most GRACE after
    ///       each recovery; it is not blocked indefinitely.
    function test_XB1_lateAttestationsDelayDefaultByAtMostGrace() public {
        uint256 r = _lateAttestationsUntil(uint256(due0) + 40 days);
        uint256 g = VariantB(address(lease)).GRACE();
        assertFalse(_defaultPossibleAt(r), "blocked in the recovery block");
        assertFalse(_defaultPossibleAt(r + g - 1), "blocked until the grace period has elapsed");
        assertTrue(_defaultPossibleAt(r + g), "available once the grace period has elapsed");
    }

    /// X-B2: the bound 0 < GRACE < maxOracleStaleness is enforced at origination.
    function test_XB2_graceMustBeShorterThanStaleness() public {
        uint64[] memory dd = new uint64[](1);
        dd[0] = due0;
        uint256[] memory ua = new uint256[](1);
        ua[0] = 100 * UNIT;
        FinancialLeaseBase.CreateLeaseParams memory p = FinancialLeaseBase.CreateLeaseParams({
            lessee: lessee, jurisdiction: bytes2("AR"), governingLaw: "test", agreementHash: bytes32(0),
            assetRef: "asset://variant", paymentAsset: address(token), denomSymbol: "UVA", oracle: oracle,
            maxStaleness: 3 days, dueDates: dd, unitAmounts: ua,
            purchasePriceUnits: 1 * UNIT, penaltyBpsPerDay: 10, defaultDeclarer: address(0),
            terminationDelay: 7 days, anchorChainId: 0, anchorRegistry: address(0), anchorId: bytes32(0),
            servicer: address(0), servicingInputs: new bytes32[](0), servicingMaxStaleness: new uint64[](0)
        });
        vm.prank(lessor);
        vm.expectRevert(VariantB.GraceNotBelowStaleness.selector);
        lease.createLease(p); // GRACE (3 days) == maxStaleness: rejected
    }

    /// X-B3: why the bound matters. Without it, a grace period longer than the
    ///       tolerance never completes under late attestations, and a genuine
    ///       default stays blocked for as long as the attestations stay late.
    function test_XB3_unboundedGraceBlocksDefaultIndefinitely() public {
        lease = new VariantBUnbounded(10 days); // 10 days > 7-day tolerance
        id = _create(oracle);
        uint256 r = _lateAttestationsUntil(uint256(due0) + 40 days);
        for (uint256 k = 0; k < 8; k++) {
            assertFalse(_defaultPossibleAt(r + k * 1 days), "blocked at every point of the cycle");
        }
    }
}

contract BatteryC is Battery {
    function _deploy() internal override returns (FinancialLeaseBase) {
        return new VariantC();
    }

    /// X-C1: the contract now holds funds; it must stay solvent.
    function test_XC1_solventAfterPaymentsAndWithdrawals() public {
        _keepFreshUntil(uint256(due0) - 1 days);
        vm.prank(lessee);
        lease.pay(id, 100 * UNIT);
        address fund = makeAddr("fund");
        vm.prank(lessor);
        lease.transferFrom(lessor, fund, id);
        vm.prank(lessee);
        lease.pay(id, 100 * UNIT);
        VariantC c = VariantC(address(lease));
        assertEq(token.balanceOf(address(lease)), c.totalClaimable(address(token)));
        assertEq(c.claimable(lessor, address(token)), 100 * UNIT, "first payment credited to the holder at that time");
        assertEq(c.claimable(fund, address(token)), 100 * UNIT, "second payment credited to the new holder");
        vm.prank(fund);
        c.withdraw(address(token), fund);
        assertEq(token.balanceOf(address(lease)), c.totalClaimable(address(token)));
    }
}

contract BatteryD is Battery {
    function _deploy() internal override returns (FinancialLeaseBase) {
        return new VariantD();
    }

    /// X-D1: a dust tender must not block default.
    function test_XD1_dustTenderRejected() public {
        _warp(uint256(due0) + 2 days);
        vm.prank(lessee);
        vm.expectRevert(VariantD.InsufficientTender.selector);
        lease.pay(id, 1);
    }

    /// X-D2: a tender is applied as of the tender time: penalties on the
    ///       tendered amount stop at tender, not at settlement.
    function test_XD2_tenderAppliedAsOfTenderTime() public {
        _warp(uint256(due0) + 2 days); // stale since setUp
        vm.prank(lessee);
        lease.pay(id, 101 * UNIT); // covers installment 0 + 2 days of penalty
        _warp(now_ + 20 days); // outage continues
        _refresh();
        VariantD(address(lease)).settleTender(id);
        assertEq(uint8(lease.status(id)), uint8(IFinancialLease.LeaseStatus.Active), "cured as of tender time");
        assertEq(lease.arrears(id), 0, "no penalty accrued after the tender on the tendered amount");
    }

    /// X-D3: lessor-side edge. If the index never returns, the tender stays
    ///       in escrow and default stays blocked indefinitely.
    function test_XD3_indexNeverReturns_tenderStuck() public {
        _warp(uint256(due0) + 2 days);
        vm.prank(lessee);
        lease.pay(id, 101 * UNIT);
        _warp(now_ + 365 days);
        bool ok = _tryDefault();
        console2.log("X-D3 default possible a year later with index never back:", ok);
        assertEq(token.balanceOf(address(lease)), 101 * UNIT, "funds stuck in escrow");
    }
}
