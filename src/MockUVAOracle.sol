// SPDX-License-Identifier: CC0-1.0
// src/MockUVAOracle.sol
pragma solidity ^0.8.24;

import {IConversionOracle} from "./IConversionOracle.sol";
import {IConversionOracleHistory} from "./IConversionOracleHistory.sol";
import {FreshnessHistory} from "./oracles/FreshnessHistory.sol";

contract MockUVAOracle is IConversionOracle, IConversionOracleHistory {
    uint256 public rate;
    uint64 public asOf;
    uint64[] public observationTimes;

    constructor(uint256 initialRate) {
        set(initialRate);
    }

    function set(uint256 newRate) public {
        rate = newRate;
        asOf = uint64(block.timestamp);
        observationTimes.push(asOf);
    }

    function latestRate() external view returns (uint256, uint64) {
        return (rate, asOf);
    }

    function continuouslyFresh(uint64 from, uint64 to, uint64 tolerance) external view returns (bool) {
        return FreshnessHistory.walkStored(observationTimes, from, to, tolerance);
    }
}
