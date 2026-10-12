// SPDX-License-Identifier: CC0-1.0
// script/mocks/MockStablecoin.sol
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockStablecoin — "Test ARS Stablecoin" (tARS)
/// @notice TESTNET ONLY. Payment asset of the ERC-8348 demo deployment.
///         `mint` is PUBLIC and unrestricted: anyone can mint any amount to
///         any address, so this token has no value and MUST NOT be deployed
///         to, or relied upon in, any production network.
/// @dev 6 decimals, like a digital ARS. No owner, no cap, no pauses:
///      it exists only so that any dev can get a balance and test
///      pay() against the demo leases.
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
