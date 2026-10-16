// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FinancialLeaseBase} from "./FinancialLeaseBase.sol";
import {HistoricalAttestedOracle} from "./HistoricalAttestedOracle.sol";

// EXPERIMENT ONLY. Candidate fixes for payment-path liveness, each as a small
// override of FinancialLeaseBase (= the reference implementation).

/// @title Variant A — block adverse transitions while the index is stale
contract VariantA is FinancialLeaseBase {
    error PaymentPathUnavailable();

    function _indexStale(uint256 leaseId) internal view returns (bool) {
        Lease storage l = _leases[leaseId];
        if (l.oracle == address(0) || l.maxOracleStaleness == 0) return false;
        (, uint64 asOf) = conversionRateAsOf(leaseId);
        return asOf <= block.timestamp && block.timestamp - asOf > l.maxOracleStaleness;
    }

    function _guard(uint256 leaseId) internal view virtual {
        if (_indexStale(leaseId)) revert PaymentPathUnavailable();
    }

    function declareDefault(uint256 leaseId) external virtual override {
        _guard(leaseId);
        _declareDefault(leaseId, msg.sender);
    }

    function terminateForDefault(uint256 leaseId) external virtual override {
        _guard(leaseId);
        _terminateForDefault(leaseId, msg.sender);
    }
}

/// @title Variant B (unbounded) — A + grace period after the index recovers
/// @dev Requires a HistoricalAttestedOracle. Adverse transitions also revert
///      unless the index was continuously fresh during the last GRACE seconds,
///      so a recovery cannot be followed by a default in the same block.
///      Recovery is measured from the on-chain recording time of each
///      observation (HistoricalAttestedOracle stores block.timestamp), not from
///      a time claimed by the attester. This version does not bound GRACE; it
///      exists to show why the bound in VariantB is needed (X-B3).
contract VariantBUnbounded is VariantA {
    uint64 public immutable GRACE;

    constructor(uint64 grace) {
        GRACE = grace;
    }

    function _guard(uint256 leaseId) internal view override {
        super._guard(leaseId);
        Lease storage l = _leases[leaseId];
        if (l.oracle == address(0) || l.maxOracleStaleness == 0) return;
        uint64 nowTs = uint64(block.timestamp);
        bool ok = HistoricalAttestedOracle(l.oracle).continuouslyFresh(nowTs - GRACE, nowTs, l.maxOracleStaleness);
        if (!ok) revert PaymentPathUnavailable();
    }
}

/// @title Variant B — bounded recovery grace
/// @dev Same rule as VariantBUnbounded, with GRACE = 3 days and the bound
///      0 < GRACE < maxOracleStaleness enforced at origination. With the bound,
///      every recovery is followed by a fresh window long enough for the grace
///      period to elapse, so late attestations delay a genuine default by at
///      most GRACE after each recovery instead of blocking it (X-B1, X-B2).
contract VariantB is VariantBUnbounded(3 days) {
    error GraceNotBelowStaleness();

    function createLease(CreateLeaseParams calldata p) public override returns (uint256 leaseId) {
        if (p.oracle != address(0) && (p.maxStaleness == 0 || GRACE >= p.maxStaleness)) {
            revert GraceNotBelowStaleness();
        }
        return super.createLease(p);
    }
}

/// @title Variant C — pull payments
/// @dev pay() moves funds into this contract and credits the current holder of
///      the lessor position; the holder withdraws to any address. A recipient
///      blocked by the token issuer no longer blocks the payer.
contract VariantC is FinancialLeaseBase {
    using SafeERC20 for IERC20;

    mapping(address => mapping(address => uint256)) public claimable; // holder => asset => amount
    mapping(address => uint256) public totalClaimable; // asset => amount

    event Credited(uint256 indexed leaseId, address indexed holder, address asset, uint256 amount);
    event Withdrawn(address indexed holder, address indexed to, address asset, uint256 amount);

    function _collect(address asset, address from, uint256 leaseId, uint256 amount) internal override {
        IERC20(asset).safeTransferFrom(from, address(this), amount);
        address holder = ownerOf(leaseId);
        claimable[holder][asset] += amount;
        totalClaimable[asset] += amount;
        emit Credited(leaseId, holder, asset, amount);
    }

    function withdraw(address asset, address to) external nonReentrant {
        uint256 amount = claimable[msg.sender][asset];
        claimable[msg.sender][asset] = 0;
        totalClaimable[asset] -= amount;
        IERC20(asset).safeTransfer(to, amount);
        emit Withdrawn(msg.sender, to, asset, amount);
    }
}

/// @title Variant D — tender during an index outage
/// @dev While the index is stale, pay() escrows the assets instead of
///      reverting and records the tender time. A tender must cover the arrears
///      at the last known rate (no dust tenders). While a tender is pending,
///      default and termination for default revert. Once the index is fresh,
///      anyone calls settleTender(): the assets are converted at the fresh rate
///      and applied AS OF the tender time, so penalties stop accruing on the
///      tendered amount from that moment; any excess is refunded.
contract VariantD is VariantA {
    using SafeERC20 for IERC20;
    using Math for uint256;

    struct Tender {
        address payer;
        uint256 assets;
        uint64 at;
    }

    mapping(uint256 => Tender) public tenders;
    uint64 private _asOfOverride;

    error TenderPending();
    error NoTender();
    error InsufficientTender();
    error IndexStillStale();

    event Tendered(uint256 indexed leaseId, address indexed payer, uint256 assets, uint64 at);
    event TenderSettled(uint256 indexed leaseId, uint256 applied, uint256 refunded);

    function _effectiveNow(Lease storage l) internal view override returns (uint64) {
        if (_asOfOverride != 0) return _asOfOverride;
        return super._effectiveNow(l);
    }

    function _guard(uint256 leaseId) internal view override {
        if (tenders[leaseId].assets != 0) revert TenderPending();
        // Without a tender, a stale index still blocks adverse transitions (A).
        super._guard(leaseId);
    }

    function pay(uint256 leaseId, uint256 assets) external override nonReentrant {
        if (tenders[leaseId].assets != 0) revert TenderPending();
        if (!_indexStale(leaseId)) {
            _payCore(leaseId, assets, _freshRate(leaseId), msg.sender);
            return;
        }
        Lease storage l = _leases[leaseId];
        if (_isTerminal(l.status)) revert WrongStatus();
        (uint256 lastRate,) = conversionRateAsOf(leaseId);
        (uint256 principalArrears, uint256 penaltyGrossNow,,) = _computeState(l);
        uint256 dueUnits = principalArrears + _penaltyOwed(l, penaltyGrossNow);
        uint256 minAssets = dueUnits.mulDiv(lastRate, 1e18, Math.Rounding.Ceil);
        if (assets < minAssets || assets == 0) revert InsufficientTender();

        IERC20(l.paymentAsset).safeTransferFrom(msg.sender, address(this), assets);
        tenders[leaseId] = Tender(msg.sender, assets, uint64(block.timestamp));
        emit Tendered(leaseId, msg.sender, assets, uint64(block.timestamp));
    }

    function settleTender(uint256 leaseId) external nonReentrant {
        Tender memory t = tenders[leaseId];
        if (t.assets == 0) revert NoTender();
        if (_indexStale(leaseId)) revert IndexStillStale();
        delete tenders[leaseId];

        uint256 rate = _freshRate(leaseId);
        Lease storage l = _leases[leaseId];
        uint256 settledBefore = l.settledUnits;
        uint256 penaltyPaidBefore = l.penaltyPaidUnits;

        _asOfOverride = t.at; // apply the payment as of the tender time
        _payCore(leaseId, t.assets, rate, address(this));
        _asOfOverride = 0;

        uint256 unitsApplied = (l.settledUnits - settledBefore) + (l.penaltyPaidUnits - penaltyPaidBefore);
        uint256 used = unitsApplied.mulDiv(rate, 1e18, Math.Rounding.Ceil);
        if (used > t.assets) used = t.assets;
        uint256 refund = t.assets - used;
        if (refund > 0) IERC20(l.paymentAsset).safeTransfer(t.payer, refund);
        emit TenderSettled(leaseId, used, refund);
    }

    /// @dev Escrowed tenders are paid out from this contract, not pulled.
    function _collect(address asset, address from, uint256 leaseId, uint256 amount) internal override {
        if (from == address(this)) {
            IERC20(asset).safeTransfer(ownerOf(leaseId), amount);
        } else {
            super._collect(asset, from, leaseId, amount);
        }
    }
}
