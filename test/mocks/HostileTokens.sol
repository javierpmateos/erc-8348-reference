// SPDX-License-Identifier: CC0-1.0
// test/mocks/HostileTokens.sol
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Payment-token behaviours that real stablecoins have and that a lease
///         cannot control: issuer blacklists (USDC, USDT) and a global pause (USDC).
///         Transfers from or to a blacklisted address revert, and so does every
///         transfer while paused.
contract HostileToken is ERC20 {
    mapping(address => bool) public blacklisted;
    bool public paused;

    error Blacklisted(address account);
    error Paused();

    constructor() ERC20("Hostile USD", "hUSD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBlacklisted(address account, bool value) external {
        blacklisted[account] = value;
    }

    function setPaused(bool value) external {
        paused = value;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (paused) revert Paused();
        if (blacklisted[from]) revert Blacklisted(from);
        if (blacklisted[to]) revert Blacklisted(to);
        super._update(from, to, value);
    }
}
