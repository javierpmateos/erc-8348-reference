# ERC-8348 Financial Lease — reference implementation

Reference implementation of [ERC-8348](https://github.com/ethereum/ERCs/pull/1907),
a jurisdiction-neutral interface for tokenized financial leases whose schedules
are denominated in a unit of account (an inflation index such as the UVA, UF or
IPCA, or a plain currency) and settled in an ERC-20 payment asset.

> **Status: Draft.** The ERC is under review in
> [ethereum/ERCs#1907](https://github.com/ethereum/ERCs/pull/1907) and the
> interface may still change. This code is for study and testnet use; it has not
> been externally audited. Do not use it with real funds.

**Want to try it without compiling anything?** A live demo with three example
leases is deployed on Base Sepolia — see [DEPLOYMENTS.md](./DEPLOYMENTS.md).

## What the standard covers

- The lessor's position is an ERC-721 token (`tokenId == leaseId`). Payments made
  through the contract go to its current holder, so the position can be
  transferred, pledged or securitized with existing tooling.
- The schedule is immutable and expressed in units of account; each payment is
  converted at the rate in force when it is made, with directional rounding that
  never favours the payer.
- Two-tier delinquency: `InArrears` (objective, derived from the clock) and
  `InDefault` (a formal declaration that can be cured).
- Early termination by mutual agreement or for default after a non-zero delay,
  purchase option, and terminal statuses that freeze the lease.
- Views report the accrued state at `block.timestamp`, and accrual is invariant
  to how often, or in how many pieces, anyone transacts.
- `inputFreshness` lets consumers check how old every off-chain input is (index
  observation, servicing data, appraisals) before relying on it.
- Optional extensions: anchoring the lease to a registry entry on another chain,
  and binding it to an on-chain asset.

## What it does not do

- **It assumes on-chain settlement.** `pay()` moves an ERC-20 from the payer to
  the holder of the lessor position. Anyone can call it, so a servicer that
  collects off-chain can settle on the lessee's behalf, but the contract only
  sees the on-chain payment.
- **It does not create legal title.** The signed agreement stays off-chain,
  bound by its hash. Whether a token transfer is a valid assignment depends on
  the jurisdiction and the agreement.
- **It is not an accounting classification.** "Financial lease" refers to the
  contractual financing instrument, not to a classification under IFRS 16 or
  ASC 842.

## Known issues

When something outside the lessee's control blocks payment, the counterparty
can still move the lease towards default. `test/liveness/` reproduces each case:

| Case | Lessee can pay? | Default / termination possible? |
| --- | --- | --- |
| Index oracle stale past `maxOracleStaleness` | No (`StaleOracle`) | Yes |
| Index recovers; default declared in the same block | Not in time | Yes |
| Lessor position held by an address blacklisted by the payment token | No | Yes, and the holder can induce it |
| Payment token paused by its issuer | No | Yes |
| Chain downtime across a due date | Not in time | Yes, in the first block after resuming |

These are under discussion in the
[Magicians thread](https://ethereum-magicians.org/t/erc-8348-financial-lease/29076)
and will be addressed in the next spec revision. To run the liveness invariant
in enforcing mode: `LIVENESS_STRICT=true forge test --match-contract LivenessInvariantTest`.

## Layout

| Path | Contents |
| --- | --- |
| `src/IFinancialLease.sol` | Core interface |
| `src/IFinancialLeaseAnchored.sol`, `src/IFinancialLeaseAssetBound.sol` | Optional extensions |
| `src/FinancialLease.sol` | Reference implementation |
| `src/IConversionOracle.sol` | Oracle interface used by the implementation |
| `src/oracles/` | Adapters: Chainlink feed, composed feeds, attested (manually published) rate |
| `src/MockUVAOracle.sol` | Test oracle |
| `test/` | Unit, scenario, fuzz and invariant tests |
| `test/liveness/` | Dependency-failure matrix and liveness invariant (documents known issues) |
| `test/fork/` | Optional fork tests against live Chainlink feeds on Base (need `BASE_RPC_URL`) |
| `script/DeployDemo.s.sol` | Base Sepolia demo deployment |

## Build and test

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation).

```sh
git clone --recursive https://github.com/javierpmateos/erc-8348-reference.git
cd erc-8348-reference
forge test
```

If you cloned without `--recursive`, run `git submodule update --init --recursive`
first. The project compiles with `via_ir`; the first build takes about a minute,
and the invariant suites take about two more.

## Feedback

Comments on the standard itself are most useful in the
[Ethereum Magicians discussion](https://ethereum-magicians.org/t/erc-8348-financial-lease/29076)
or on the pull request. Bugs in this code: open an issue here.

## License

[CC0 1.0](./LICENSE), like the ERC.
