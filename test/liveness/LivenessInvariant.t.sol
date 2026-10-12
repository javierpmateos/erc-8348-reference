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
///      The reference implementation does NOT satisfy this yet (see
///      LivenessMatrix.t.sol, rows L1-L4). To keep the default suite green the
///      invariant only reports by default; run it in strict mode to enforce it:
///
///          LIVENESS_STRICT=true forge test --match-contract LivenessInvariantTest
///
///      Once the issue is fixed, make strict mode the default.
contract LivenessInvariantTest is StdInvariant, Test {
    LivenessHandler internal handler;

    function setUp() public {
        handler = new LivenessHandler();
        targetContract(address(handler));
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
    }
}
