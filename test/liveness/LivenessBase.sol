// SPDX-License-Identifier: CC0-1.0
// test/liveness/LivenessBase.sol
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {FinancialLease} from "../../src/FinancialLease.sol";
import {IFinancialLease} from "../../src/IFinancialLease.sol";
import {MockUVAOracle} from "../../src/MockUVAOracle.sol";
import {HostileToken} from "../mocks/HostileTokens.sol";

/// @dev Shared fixture for the liveness suite: one lease with a single
///      installment of 100 units, an index oracle with 7 days of tolerance,
///      dynamic defaultDeclarer (follows ownerOf) and a 7-day termination delay.
abstract contract LivenessBase is Test {
    FinancialLease internal lease;
    HostileToken internal token;
    MockUVAOracle internal oracle;

    address internal lessor = makeAddr("lessor");
    address internal lessee = makeAddr("lessee");
    address internal thirdParty = makeAddr("thirdParty");

    uint256 internal constant UNIT = 1e18;
    uint64 internal constant STALENESS = 7 days;
    uint64 internal constant TERMINATION_DELAY = 7 days;

    uint256 internal id;
    uint64 internal due0;

    function setUp() public virtual {
        vm.warp(1_000_000);
        lease = new FinancialLease();
        token = new HostileToken();
        oracle = new MockUVAOracle(1e18);

        token.mint(lessee, 1_000_000 * UNIT);
        token.mint(thirdParty, 1_000_000 * UNIT);
        vm.prank(lessee);
        token.approve(address(lease), type(uint256).max);
        vm.prank(thirdParty);
        token.approve(address(lease), type(uint256).max);

        due0 = uint64(block.timestamp + 30 days);
        id = _create(address(oracle));
    }

    function _create(address oracle_) internal returns (uint256 leaseId) {
        uint64[] memory dd = new uint64[](1);
        dd[0] = due0;
        uint256[] memory ua = new uint256[](1);
        ua[0] = 100 * UNIT;
        FinancialLease.CreateLeaseParams memory p = FinancialLease.CreateLeaseParams({
            lessee: lessee,
            jurisdiction: bytes2("AR"),
            governingLaw: "test",
            agreementHash: keccak256("agreement"),
            assetRef: "asset://test/1",
            paymentAsset: address(token),
            denomSymbol: "UVA",
            oracle: oracle_,
            maxStaleness: oracle_ == address(0) ? 0 : STALENESS,
            dueDates: dd,
            unitAmounts: ua,
            purchasePriceUnits: 1 * UNIT,
            penaltyBpsPerDay: 10,
            defaultDeclarer: address(0),
            terminationDelay: TERMINATION_DELAY,
            anchorChainId: 0,
            anchorRegistry: address(0),
            anchorId: bytes32(0),
            servicer: address(0),
            servicingInputs: new bytes32[](0),
            servicingMaxStaleness: new uint64[](0)
        });
        vm.prank(lessor);
        leaseId = lease.createLease(p);
    }

    function _status() internal view returns (IFinancialLease.LeaseStatus) {
        return lease.status(id);
    }

    /// @dev Declares default as the current position holder, then terminates
    ///      after the timelock. Returns true if both transitions succeeded.
    function _defaultAndTerminate() internal returns (bool) {
        address holder = lease.ownerOf(id);
        vm.prank(holder);
        try lease.declareDefault(id) {} catch { return false; }
        vm.warp(block.timestamp + TERMINATION_DELAY);
        vm.prank(holder);
        try lease.terminateForDefault(id) {} catch { return false; }
        return _status() == IFinancialLease.LeaseStatus.Terminated;
    }
}
