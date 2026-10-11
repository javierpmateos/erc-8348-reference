// SPDX-License-Identifier: CC0-1.0
// script/DeployDemo.s.sol
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {FinancialLease} from "../src/FinancialLease.sol";
import {AttestedConversionOracle} from "../src/oracles/AttestedConversionOracle.sol";
import {MockStablecoin} from "./mocks/MockStablecoin.sol";

/// @title DeployDemo — deploy de demostracion de ERC-8348 en Base Sepolia
/// @notice Despliega tARS + oraculo UVA atestado + FinancialLease y origina
///         tres leasings de ejemplo (al dia / tasa fija / en mora).
/// @dev El script NO maneja claves: firma Foundry con el keystore, via
///      `--account <nombre> --sender <address>` por linea de comando. El
///      sender es el deployer (= lessor, owner y atestador del oraculo).
///
///      Variables de entorno:
///        LESSEE       address del tomador de los tres leasings
///        UVA_RATE     valor del UVA en ARS tal como lo publica el BCRA,
///                     en decimal: "1634.52" o "1634,52" (hasta 6
///                     decimales, SIN separador de miles)
///
///      Convencion de escalas (la misma de test/Scenarios.t.sol):
///        - unidades de cuenta: 18 decimales (1 UVA = 1e18)
///        - rate del oraculo: payment asset por unidad, en decimales del
///          asset (1634.52 ARS/UVA con tARS de 6 decimales = 1634.52e6)
///        - con oracle == address(0) el rate es 1e18 fijo, o sea que las
///          unidades SON base units del asset (caso B: 6 decimales)
contract DeployDemo is Script {
    uint256 internal constant BASE_SEPOLIA = 84532;
    uint64 internal constant PERIOD = 30 days;
    uint64 internal constant MAX_ORACLE_STALENESS = 30 days;
    uint64 internal constant TERMINATION_DELAY = 30 days;

    // A) 36 x 2.500 UVA = 90.000 UVA (equipo industrial de gama media)
    uint256 internal constant A_INSTALLMENT_UVA = 2_500e18;
    // B) 12 x 12.500.000 tARS, denominacion fija (unidades = base units)
    uint256 internal constant B_INSTALLMENT_ARS = 12_500_000e6;
    // C) 24 x 3.000 UVA = 72.000 UVA
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

        // --sender: con vm.startBroadcast() sin argumentos, es quien firma
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

        // A) Al dia: primera cuota a 30 dias del deploy, opcion = 1 cuota
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

        // B) Tasa fija: mismo bien, sin oraculo (conversion identidad)
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

        // C) En mora: el cronograma arranco hace 65 dias, asi que las
        //    cuotas 0 y 1 vencieron hace 35 y 5 dias. Sin pagos.
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
        console2.log("leaseId A (al dia, UVA):     ", idA);
        console2.log("leaseId B (tasa fija, ARS):  ", idB);
        console2.log("leaseId C (en mora, UVA):    ", idC);

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
            defaultDeclarer: address(0), // sin override: sigue a ownerOf
            terminationDelay: TERMINATION_DELAY,
            anchorChainId: 0,
            anchorRegistry: address(0),
            anchorId: bytes32(0),
            servicer: address(0), // = msg.sender (deployer)
            servicingInputs: new bytes32[](0),
            servicingMaxStaleness: new uint64[](0)
        });
    }

    /// @dev Solo lectura (post stopBroadcast): no genera transacciones.
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

    /// @dev "1634.52" / "1634,52" -> 1634520000 (6 decimales, los de tARS).
    ///      Un solo separador decimal y nada de separador de miles; el piso
    ///      de 100 ARS atrapa justamente ese error ("1,634" leido como
    ///      1.634) y un valor pasado en la escala equivocada.
    function _parseRate(string memory s) internal pure returns (uint256 r) {
        bytes memory b = bytes(s);
        uint256 fracDigits;
        bool seenSeparator;
        for (uint256 i = 0; i < b.length; i++) {
            bytes1 c = b[i];
            if (c == "." || c == ",") {
                require(!seenSeparator, "UVA_RATE: mas de un separador decimal");
                seenSeparator = true;
                continue;
            }
            require(c >= "0" && c <= "9", "UVA_RATE: caracter invalido");
            r = r * 10 + (uint8(c) - 48);
            if (seenSeparator) fracDigits++;
        }
        require(fracDigits <= 6, "UVA_RATE: mas de 6 decimales");
        r *= 10 ** (6 - fracDigits);
        require(r >= 100e6, "UVA_RATE: implausible (< 100 ARS); formato esperado 1634.52");
    }
}
