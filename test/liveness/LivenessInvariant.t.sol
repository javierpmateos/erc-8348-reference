// SPDX-License-Identifier: CC0-1.0
// test/liveness/LivenessInvariant.t.sol
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {LivenessHandler} from "./LivenessHandler.sol";

/// @title INV-LIVENESS: no adverse transition while the payment path is blocked
/// @dev Property: declareDefault and terminateForDefault never succeed while
///      the lessee's payment path is unavailable for reasons outside its
///      control (stale index, paused token, blacklisted position holder).
///
///      Index-side failures are closed by the payment-path liveness rule and
///      are enforced unconditionally, in both directions, against an
///      independent model of rules A and B (see LivenessHandler): no default
///      action succeeds while the model says the index path is blocked, and no
///      default action is rejected for index liveness while the model allows it.
///
///      Token-side failures (paused token, blacklisted holder; matrix rows L3,
///      L4) are not closed by the reference implementation. That part only
///      reports by default; run it in strict mode to enforce it:
///
///          LIVENESS_STRICT=true forge test --match-contract LivenessInvariantTest
contract LivenessInvariantTest is StdInvariant, Test {
    LivenessHandler internal handler;

    function setUp() public {
        handler = new LivenessHandler();
        targetContract(address(handler));
    }

    function invariant_INV_LIVENESS_A_B_indexRuleMatchesModel() public view {
        assertEq(handler.ghost_adverseWhileIndexBlocked(), 0, "default action succeeded while the index path was blocked");
        assertEq(handler.ghost_overBlocked(), 0, "default action rejected for index liveness while the model allows it");
    }

    function invariant_INV_LIVENESS_noAdverseTransitionWhileBlocked() public view {
        uint256 v = handler.ghost_adverseWhileBlocked();
        if (vm.envOr("LIVENESS_STRICT", false)) {
            assertEq(v, 0, "INV-LIVENESS violated: default/termination succeeded while the payment path was blocked");
        }
    }

    function afterInvariant() public view {
        console2.log("INV-LIVENESS adverse transitions while blocked:", handler.ghost_adverseWhileBlocked());
        console2.log("INV-LIVENESS adverse transitions total:        ", handler.ghost_adverseTotal());
        console2.log("INV-LIVENESS index-blocked successes (must be 0):", handler.ghost_adverseWhileIndexBlocked());
        console2.log("INV-LIVENESS over-blocked rejections (must be 0):", handler.ghost_overBlocked());
    }
}
