// SPDX-License-Identifier: CC0-1.0
// script/DeployDemo.s.sol
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {FinancialLease} from "../src/FinancialLease.sol";
import {AttestedConversionOracle} from "../src/oracles/AttestedConversionOracle.sol";
import {MockStablecoin} from "./mocks/MockStablecoin.sol";

/// @title DeployDemo — ERC-8348 demo deployment on Base Sepolia
/// @notice Deploys tARS + an attested UVA oracle + FinancialLease and originates
///         three example leases (current / fixed rate / in arrears).
/// @dev The script does NOT handle keys: Foundry signs with the keystore, via
///      `--account <name> --sender <address>` on the command line. The
///      sender is the deployer (= lessor, owner and attester of the oracle).
///
///      Environment variables:
///        LESSEE       address of the lessee of all three leases
///        UVA_RATE     UVA value in ARS as published by the BCRA,
///                     in decimal: "1634.52" or "1634,52" (up to 6
///                     decimals, NO thousands separator)
///
///      Scale conventions (the same as test/Scenarios.t.sol):
///        - units of account: 18 decimals (1 UVA = 1e18)
///        - oracle rate: payment asset per unit, in the asset's
///          decimals (1634.52 ARS/UVA with 6-decimal tARS = 1634.52e6)
///        - with oracle == address(0) the rate is a fixed 1e18, i.e. the
///          units ARE base units of the asset (case B: 6 decimals)
contract DeployDemo is Script {
    uint256 internal constant BASE_SEPOLIA = 84532;
    uint64 internal constant PERIOD = 30 days;
    uint64 internal constant MAX_ORACLE_STALENESS = 30 days;
    uint64 internal constant TERMINATION_DELAY = 30 days;

    // A) 36 x 2,500 UVA = 90,000 UVA (mid-range industrial equipment)
    uint256 internal constant A_INSTALLMENT_UVA = 2_500e18;
    // B) 12 x 12,500,000 tARS, fixed denomination (units = base units)
    uint256 internal constant B_INSTALLMENT_ARS = 12_500_000e6;
    // C) 24 x 3,000 UVA = 72,000 UVA
    uint256 internal constant C_INSTALLMENT_UVA = 3_000e18;
    uint16 internal constant C_PENALTY_BPS_PER_DAY = 10;

    string internal constant GOVERNING_LAW =
        "Republica Argentina - Codigo Civil y Comercial de la Nacion, arts. 1227-1250 (leasing)";
    string internal constant ASSET_CNC =
        "DEMO: Centro de mecanizado CNC vertical 3 ejes, modelo VMC-850, serie DEMO-0001, planta San Martin (Buenos Aires)";
    string internal constant ASSET_TRACTOR =
        "DEMO: Tractor agricola 140 HP doble traccion, serie DEMO-0002, establecimiento Pergamino (Buenos Aires)";

    function run() external {
        require(block.chainid == BASE_SEPOLIA, "DeployDemo: solo Base Sepolia (84532)");

        // --sender: with vm.startBroadcast() and no arguments, this is the signer
        address deployer = msg.sender;
        address lesseeAddr = vm.envAddress("LESSEE");
        require(lesseeAddr != address(0), "DeployDemo: LESSEE es address(0)");
        uint256 uvaRate = _parseRate(vm.envString("UVA_RATE"));

        uint64 t0 = uint64(block.timestamp);

        vm.startBroadcast();

        MockStablecoin tars = new MockStablecoin();
        AttestedConversionOracle oracle = new AttestedConversionOracle(deployer, deployer);
        oracle.attest(uvaRate);
        FinancialLease lease = new FinancialLease();

        // A) Current: first installment 30 days after deploy, option = 1 installment
        uint256 idA = lease.createLease(
            _params(
                lesseeAddr,
                ASSET_CNC,
                address(tars),
                "UVA",
                address(oracle),
                t0 + PERIOD,
                36,
                A_INSTALLMENT_UVA,
                A_INSTALLMENT_UVA,
                0
            )
        );

        // B) Fixed rate: same asset, no oracle (identity conversion)
        uint256 idB = lease.createLease(
            _params(
                lesseeAddr,
                ASSET_CNC,
                address(tars),
                "ARS",
                address(0),
                t0 + PERIOD,
                12,
                B_INSTALLMENT_ARS,
                B_INSTALLMENT_ARS,
                0
            )
        );

        // C) In arrears: the schedule started 65 days ago, so
        //    installments 0 and 1 fell due 35 and 5 days ago. No payments.
        uint256 idC = lease.createLease(
            _params(
                lesseeAddr,
                ASSET_TRACTOR,
                address(tars),
                "UVA",
                address(oracle),
                t0 - 65 days + PERIOD,
                24,
                C_INSTALLMENT_UVA,
                C_INSTALLMENT_UVA,
                C_PENALTY_BPS_PER_DAY
            )
        );

        vm.stopBroadcast();

        console2.log("=== ERC-8348 demo - Base Sepolia (84532) ===");
        console2.log("deployer / lessor / attester:", deployer);
        console2.log("lessee:                      ", lesseeAddr);
        console2.log("UVA_RATE (ARS x 1e6):        ", uvaRate);
        console2.log("MockStablecoin (tARS):       ", address(tars));
        console2.log("AttestedConversionOracle:    ", address(oracle));
        console2.log("FinancialLease:              ", address(lease));
        console2.log("leaseId A (current, UVA):    ", idA);
        console2.log("leaseId B (fixed rate, ARS): ", idB);
        console2.log("leaseId C (in arrears, UVA): ", idC);

        _logLease(lease, "A", idA);
        _logLease(lease, "B", idB);
        _logLease(lease, "C", idC);
    }

    function _params(
        address lesseeAddr,
        string memory assetRef,
        address paymentAsset,
        string memory denomSymbol,
        address oracle,
        uint64 firstDueDate,
        uint256 n,
        uint256 installmentUnits,
        uint256 purchasePriceUnits,
        uint16 penaltyBpsPerDay
    ) internal pure returns (FinancialLease.CreateLeaseParams memory p) {
        uint64[] memory dueDates = new uint64[](n);
        uint256[] memory unitAmounts = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            dueDates[i] = firstDueDate + uint64(i) * PERIOD;
            unitAmounts[i] = installmentUnits;
        }

        p = FinancialLease.CreateLeaseParams({
            lessee: lesseeAddr,
            jurisdiction: bytes2("AR"),
            governingLaw: GOVERNING_LAW,
            agreementHash: keccak256(bytes(unicode"DEMO — not a real agreement")),
            assetRef: assetRef,
            paymentAsset: paymentAsset,
            denomSymbol: denomSymbol,
            oracle: oracle,
            maxStaleness: MAX_ORACLE_STALENESS,
            dueDates: dueDates,
            unitAmounts: unitAmounts,
            purchasePriceUnits: purchasePriceUnits,
            penaltyBpsPerDay: penaltyBpsPerDay,
            defaultDeclarer: address(0), // no override: follows ownerOf
            terminationDelay: TERMINATION_DELAY,
            anchorChainId: 0,
            anchorRegistry: address(0),
            anchorId: bytes32(0),
            servicer: address(0), // = msg.sender (deployer)
            servicingInputs: new bytes32[](0),
            servicingMaxStaleness: new uint64[](0)
        });
    }

    /// @dev Read-only (after stopBroadcast): sends no transactions.
    function _logLease(FinancialLease lease, string memory label, uint256 id) internal view {
        (uint256 nextAssets, uint64 nextDue) = lease.nextPayment(id);
        console2.log(string.concat("--- lease ", label, " ---"));
        console2.log("  status (0=Active,1=InArrears):", uint256(lease.status(id)));
        console2.log("  paymentCount:                 ", lease.paymentCount(id));
        console2.log("  outstandingBalance (tARS 1e6):", lease.outstandingBalance(id));
        console2.log("  arrears (tARS 1e6):           ", lease.arrears(id));
        console2.log("  nextPayment assets (tARS 1e6):", nextAssets);
        console2.log("  nextPayment dueDate:          ", uint256(nextDue));
    }

    /// @dev "1634.52" / "1634,52" -> 1634520000 (6 decimals, those of tARS).
    ///      A single decimal separator and no thousands separator; the floor
    ///      of 100 ARS catches exactly that mistake ("1,634" read as
    ///      1.634) and a value passed in the wrong scale.
    function _parseRate(string memory s) internal pure returns (uint256 r) {
        bytes memory b = bytes(s);
        uint256 fracDigits;
        bool seenSeparator;
        for (uint256 i = 0; i < b.length; i++) {
            bytes1 c = b[i];
            if (c == "." || c == ",") {
                require(!seenSeparator, "UVA_RATE: more than one decimal separator");
                seenSeparator = true;
                continue;
            }
            require(c >= "0" && c <= "9", "UVA_RATE: invalid character");
            r = r * 10 + (uint8(c) - 48);
            if (seenSeparator) fracDigits++;
        }
        require(fracDigits <= 6, "UVA_RATE: more than 6 decimals");
        r *= 10 ** (6 - fracDigits);
        require(r >= 100e6, "UVA_RATE: implausible (< 100 ARS); expected format 1634.52");
    }
}
