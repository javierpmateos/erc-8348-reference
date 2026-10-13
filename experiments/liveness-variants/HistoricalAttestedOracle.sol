// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {IConversionOracle} from "../../src/IConversionOracle.sol";

/// @title HistoricalAttestedOracle — EXPERIMENT ONLY
/// @notice Attested rate (as for indices with no on-chain feed, e.g. UVA) that
///         keeps every observation, so a consumer can answer after the fact
///         "was the index fresh at time t for tolerance tol?". Chainlink feeds
///         expose the same information through getRoundData.
contract HistoricalAttestedOracle is IConversionOracle {
    struct Observation {
        uint256 rate;
        uint64 asOf;
    }

    Observation[] public observations;
    address public immutable attester;

    error NotAttester();
    error ZeroRate();

    constructor(uint256 initialRate) {
        attester = msg.sender;
        attest(initialRate);
    }

    function attest(uint256 rate) public {
        if (msg.sender != attester) revert NotAttester();
        if (rate == 0) revert ZeroRate();
        observations.push(Observation(rate, uint64(block.timestamp)));
    }

    function count() external view returns (uint256) {
        return observations.length;
    }

    function latestRate() external view returns (uint256, uint64) {
        Observation storage o = observations[observations.length - 1];
        return (o.rate, o.asOf);
    }

    /// @notice True if, at every instant of [from, to], some observation was
    ///         no older than `tol`. Walks back from the latest observation; cost
    ///         grows with the number of observations inside the window.
    function continuouslyFresh(uint64 from, uint64 to, uint64 tol) external view returns (bool) {
        uint256 n = observations.length;
        uint64 cursor = to;
        for (uint256 k = n; k > 0; k--) {
            uint64 a = observations[k - 1].asOf;
            if (a > to) continue;
            if (cursor - a > tol) return false; // gap: some instant in (a + tol, cursor] was stale
            if (a <= from) return true; // this observation covers back to `from`
            cursor = a;
        }
        return false; // history does not reach back to `from`
    }
}
