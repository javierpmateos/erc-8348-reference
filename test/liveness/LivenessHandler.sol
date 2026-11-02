// SPDX-License-Identifier: CC0-1.0
// test/liveness/LivenessHandler.sol
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {FinancialLease} from "../../src/FinancialLease.sol";
import {IFinancialLease} from "../../src/IFinancialLease.sol";
import {MockUVAOracle} from "../../src/MockUVAOracle.sol";
import {HostileToken} from "../mocks/HostileTokens.sol";

/// @dev Fuzz handler that mixes ordinary lease activity with failures of the
///      dependencies the lessee's payment path relies on (stale index, token
///      pause, blacklisted position holder). It counts every adverse transition
///      (declareDefault, terminateForDefault) that succeeds while that path is
///      unavailable. See LivenessInvariant.t.sol.
contract LivenessHandler is Test {
    FinancialLease public lease;
    HostileToken public token;
    MockUVAOracle public oracle;

    address public lessor = makeAddr("lv-lessor");
    address public lessee = makeAddr("lv-lessee");
    address[] internal holders;

    uint256 public id;
    uint64 internal constant STALENESS = 7 days;

    uint256 public ghost_adverseWhileBlocked;
    uint256 public ghost_adverseTotal;

    // Independent model of rule A + B (does not call the oracle's history):
    // a recovery happens when an attestation lands on a stale index. Default
    // actions are allowed iff the index is fresh now and now >= lastRecovery + G.
    uint256 public lastRecovery;
    uint256 public ghost_adverseWhileIndexBlocked; // must stay 0 (strict)
    uint256 public ghost_overBlocked; // index-liveness revert while the model allows: must stay 0

    FinancialLease.CreateLeaseParams internal params;

    constructor() {
        lease = new FinancialLease();
        token = new HostileToken();
        oracle = new MockUVAOracle(1e18);

        holders.push(lessor);
        holders.push(makeAddr("lv-fund"));
        holders.push(makeAddr("lv-sanctioned"));

        token.mint(lessee, 1e30);
        vm.prank(lessee);
        token.approve(address(lease), type(uint256).max);

        uint64[] memory dd = new uint64[](6);
        uint256[] memory ua = new uint256[](6);
        for (uint256 i = 0; i < 6; i++) {
            dd[i] = uint64(block.timestamp + (i + 1) * 30 days);
            ua[i] = 100e18;
        }
        FinancialLease.CreateLeaseParams memory p = FinancialLease.CreateLeaseParams({
            lessee: lessee,
            jurisdiction: bytes2("AR"),
            governingLaw: "test",
            agreementHash: keccak256("agreement"),
            assetRef: "asset://test/liveness",
            paymentAsset: address(token),
            denomSymbol: "UVA",
            oracle: address(oracle),
            maxStaleness: STALENESS,
            dueDates: dd,
            unitAmounts: ua,
            purchasePriceUnits: 1e18,
            penaltyBpsPerDay: 10,
            defaultDeclarer: address(0),
            terminationDelay: 7 days,
            anchorChainId: 0,
            anchorRegistry: address(0),
            anchorId: bytes32(0),
            servicer: address(0),
            servicingInputs: new bytes32[](0),
            servicingMaxStaleness: new uint64[](0)
        });
        params = p;
        vm.prank(lessor);
        id = lease.createLease(p);
        lastRecovery = block.timestamp; // oracle history starts here
    }

    /// @dev Coverage: once the lease is terminal, originate a fresh one (same
    ///      oracle, so the recovery model carries over), with due dates
    ///      relative to now, so default actions keep being exercised.
    function newLeaseIfTerminal() external {
        IFinancialLease.LeaseStatus st = lease.status(id);
        if (
            st != IFinancialLease.LeaseStatus.Terminated && st != IFinancialLease.LeaseStatus.Completed
                && st != IFinancialLease.LeaseStatus.PurchaseExercised
        ) return;
        uint256 nowTs = vm.getBlockTimestamp();
        for (uint256 i = 0; i < 6; i++) {
            params.dueDates[i] = uint64(nowTs + (i + 1) * 30 days);
        }
        address owner = holders[0];
        vm.prank(owner);
        id = lease.createLease(params);
    }

    function indexStale() public view returns (bool) {
        (, uint64 asOf) = oracle.latestRate();
        return block.timestamp > asOf && block.timestamp - asOf > STALENESS;
    }

    /// @dev Model of rule A + bounded B for this lease.
    function indexBlocked() public view returns (bool) {
        return indexStale() || block.timestamp < lastRecovery + STALENESS / 2;
    }

    function _record(bool blocked, bool indexBlocked_, bool ok, bytes memory err) internal {
        if (ok) {
            ghost_adverseTotal++;
            if (blocked) ghost_adverseWhileBlocked++;
            if (indexBlocked_) ghost_adverseWhileIndexBlocked++;
        } else if (!indexBlocked_ && err.length >= 4) {
            bytes4 sel = bytes4(err);
            if (sel == FinancialLease.PaymentPathUnavailable.selector || sel == FinancialLease.RecoveryGraceActive.selector) {
                ghost_overBlocked++;
            }
        }
    }

    /// @dev True when neither the lessee nor anyone else can pay right now
    ///      because of a dependency outside the lessee's control.
    function paymentPathBlocked() public view returns (bool) {
        return indexStale() || token.paused() || token.blacklisted(lease.ownerOf(id));
    }

    // ─── ordinary activity ─────────────────────────────────────────────
    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 1 hours, 20 days));
    }

    function refreshOracle() external {
        if (indexStale()) lastRecovery = block.timestamp;
        oracle.set(1e18);
    }

    function lesseePays(uint256 amount) external {
        amount = bound(amount, 1, 200e18);
        vm.prank(lessee);
        try lease.pay(id, amount) {} catch {}
    }

    function transferPosition(uint256 seed) external {
        address from = lease.ownerOf(id);
        address to = holders[bound(seed, 0, holders.length - 1)];
        if (to == from) return;
        vm.prank(from);
        lease.transferFrom(from, to, id);
    }

    // ─── dependency failures ───────────────────────────────────────────
    function togglePause() external {
        token.setPaused(!token.paused());
    }

    function toggleSanctions() external {
        address s = holders[2];
        token.setBlacklisted(s, !token.blacklisted(s));
    }

    // ─── adverse transitions by the current holder ─────────────────────
    function declareDefault() external {
        bool blocked = paymentPathBlocked();
        bool ib = indexBlocked();
        address holder = lease.ownerOf(id);
        vm.prank(holder);
        try lease.declareDefault(id) {
            _record(blocked, ib, true, "");
        } catch (bytes memory err) {
            _record(blocked, ib, false, err);
        }
    }

    function terminateForDefault() external {
        bool blocked = paymentPathBlocked();
        bool ib = indexBlocked();
        address holder = lease.ownerOf(id);
        vm.prank(holder);
        try lease.terminateForDefault(id) {
            _record(blocked, ib, true, "");
        } catch (bytes memory err) {
            _record(blocked, ib, false, err);
        }
    }
}
