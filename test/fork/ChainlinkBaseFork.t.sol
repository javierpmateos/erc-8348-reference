// SPDX-License-Identifier: CC0-1.0
// test/fork/ChainlinkBaseFork.t.sol
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {FinancialLease} from "../../src/FinancialLease.sol";
import {IFinancialLease} from "../../src/IFinancialLease.sol";
import {ChainlinkConversionOracle} from "../../src/oracles/ChainlinkConversionOracle.sol";

interface IAggregatorHistory {
    function decimals() external view returns (uint8);
    function description() external view returns (string memory);
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
    function getRoundData(uint80 roundId) external view returns (uint80, int256, uint256, uint256, uint80);
}

contract ForkUSD is ERC20 {
    constructor() ERC20("Fork USD", "fUSD") {}
    function mint(address to, uint256 a) external { _mint(to, a); }
    function decimals() public pure override returns (uint8) { return 6; }
}

/// @title Fork tests against real Chainlink feeds on Base mainnet
/// @dev Skipped unless BASE_RPC_URL is set. Run with:
///
///          BASE_RPC_URL=<your Base mainnet RPC> \
///          CHAINLINK_FEED=<a Base mainnet price feed proxy, from docs.chain.link> \
///          forge test --match-path "test/fork/*" -vv
///
///      What they check:
///      F1  The L2 sequencer uptime feed exposes WHEN the sequencer last came
///          back up (startedAt). Chainlink's own guidance is a grace period
///          counted from that moment: the same shape as the "recovery race"
///          in LivenessMatrix L2/L5.
///      F2  A real feed's round history is enough to reconstruct, after the
///          fact, every window in which a lease with a given maxOracleStaleness
///          could not have been paid. This is the property that would let the
///          standard tell "didn't pay" from "couldn't pay" without anyone having
///          called the lease during the outage.
///      F3  A lease priced through ChainlinkConversionOracle settles a payment
///          against the live feed (end-to-end sanity on real data).
contract ChainlinkBaseForkTest is Test {
    /// Base mainnet L2 sequencer uptime feed (docs.chain.link/data-feeds/l2-sequencer-feeds)
    address internal constant SEQUENCER_UPTIME_FEED = 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433;
    uint256 internal constant SEQUENCER_GRACE = 3600; // Chainlink's example value

    bool internal forked;
    address internal feedAddr;

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;
        feedAddr = vm.envOr("CHAINLINK_FEED", address(0));
    }

    function test_F1_sequencerUptimeExposesRecoveryTimestamp() public {
        if (!forked) vm.skip(true);
        (, int256 answer, uint256 startedAt,,) = IAggregatorHistory(SEQUENCER_UPTIME_FEED).latestRoundData();
        console2.log("sequencer status (0 = up, 1 = down):", uint256(answer));
        console2.log("status last changed at (unix):      ", startedAt);
        console2.log("seconds since last change:          ", block.timestamp - startedAt);
        assertGt(startedAt, 0, "the recovery moment is observable on-chain");
        if (answer == 0) {
            bool inGrace = block.timestamp - startedAt <= SEQUENCER_GRACE;
            console2.log("inside Chainlink's grace period:    ", inGrace);
        }
    }

    function test_F2_reconstructOutageWindowsFromRoundHistory() public {
        if (!forked || feedAddr == address(0)) vm.skip(true);
        IAggregatorHistory feed = IAggregatorHistory(feedAddr);
        uint64 maxStaleness = uint64(vm.envOr("LEASE_MAX_STALENESS", uint256(3600)));
        uint256 depth = vm.envOr("ROUNDS_TO_SCAN", uint256(500));

        console2.log("feed:", feed.description());
        (uint80 roundId,,, uint256 updatedAt,) = feed.latestRoundData();
        uint80 phase = roundId >> 64;
        uint64 aggRound = uint64(roundId);

        uint256 windows;
        uint256 longestGap;
        uint256 prevUpdatedAt = updatedAt;
        uint256 scanned;
        // Walk back within the current phase. A round id is (phase << 64) | aggregatorRound.
        for (uint64 r = aggRound; r > 1 && scanned < depth; r--) {
            (,,, uint256 u,) = feed.getRoundData((phase << 64) | uint80(r - 1));
            if (u == 0) break;
            uint256 gap = prevUpdatedAt - u;
            if (gap > longestGap) longestGap = gap;
            if (gap > maxStaleness) {
                // From u + maxStaleness until prevUpdatedAt nobody could have paid.
                windows++;
                console2.log("unpayable window starts:", u + maxStaleness);
                console2.log("                 ends:  ", prevUpdatedAt);
            }
            prevUpdatedAt = u;
            scanned++;
        }
        console2.log("rounds scanned:                ", scanned);
        console2.log("longest gap between updates (s):", longestGap);
        console2.log("unpayable windows for this maxStaleness:", windows);
        assertGt(scanned, 0, "round history is readable");
    }

    function test_F3_leaseSettlesAgainstLiveFeed() public {
        if (!forked || feedAddr == address(0)) vm.skip(true);
        ForkUSD usd = new ForkUSD();
        ChainlinkConversionOracle adapter = new ChainlinkConversionOracle(feedAddr, 6);
        (uint256 rate, uint64 asOf) = adapter.latestRate();
        console2.log("live rate (6-dec payment units per unit):", rate);
        console2.log("asOf:", uint256(asOf));

        FinancialLease lease = new FinancialLease();
        address lessee = makeAddr("fork-lessee");
        usd.mint(lessee, 1e30);
        vm.prank(lessee);
        usd.approve(address(lease), type(uint256).max);

        uint64[] memory dd = new uint64[](1);
        dd[0] = uint64(block.timestamp + 30 days);
        uint256[] memory ua = new uint256[](1);
        ua[0] = 1e18;
        FinancialLease.CreateLeaseParams memory p = FinancialLease.CreateLeaseParams({
            lessee: lessee, jurisdiction: bytes2("US"), governingLaw: "test", agreementHash: bytes32(0),
            assetRef: "asset://fork", paymentAsset: address(usd), denomSymbol: feedDescription(), oracle: address(adapter),
            maxStaleness: uint64(block.timestamp - asOf + 1 days), dueDates: dd, unitAmounts: ua,
            purchasePriceUnits: 0, penaltyBpsPerDay: 10, defaultDeclarer: address(0), terminationDelay: 7 days,
            anchorChainId: 0, anchorRegistry: address(0), anchorId: bytes32(0), servicer: address(0),
            servicingInputs: new bytes32[](0), servicingMaxStaleness: new uint64[](0)
        });
        uint256 id = lease.createLease(p);

        (uint256 due,) = lease.nextPayment(id);
        vm.prank(lessee);
        lease.pay(id, due);
        assertEq(uint8(lease.status(id)), uint8(IFinancialLease.LeaseStatus.Completed));
    }

    function feedDescription() internal view returns (string memory) {
        return IAggregatorHistory(feedAddr).description();
    }
}
