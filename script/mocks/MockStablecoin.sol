// SPDX-License-Identifier: CC0-1.0
// script/mocks/MockStablecoin.sol
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockStablecoin — "Test ARS Stablecoin" (tARS)
/// @notice TESTNET ONLY. Payment asset of the ERC-8348 demo deployment.
///         `mint` is PUBLIC and unrestricted: anyone can mint any amount to
///         any address, so this token has no value and MUST NOT be deployed
///         to, or relied upon in, any production network.
/// @dev 6 decimales, como un ARS digital. Sin owner, sin cap, sin pausas:
///      existe solo para que cualquier dev pueda conseguir saldo y probar
///      pay() contra los leasings de demostracion.
contract MockStablecoin is ERC20 {
    constructor() ERC20("Test ARS Stablecoin", "tARS") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @notice Mints `amount` (6 decimals) to `to`. Callable by anyone —
    ///         testnet faucet, not an access-controlled issuer.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
