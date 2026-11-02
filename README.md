# ERC-8348 Financial Lease — reference implementation

Reference implementation of [ERC-8348](https://ercs.ethereum.org/ERCS/erc-8348),
a jurisdiction-neutral interface for tokenized financial leases whose schedules
are denominated in a unit of account (an inflation index such as the UVA, UF or
IPCA, or a plain currency) and settled in an ERC-20 payment asset.

> **Status: Draft.** ERC-8348 was merged into
> [ethereum/ERCs](https://github.com/ethereum/ERCs/blob/master/ERCS/erc-8348.md)
> as a Draft ([#1907](https://github.com/ethereum/ERCs/pull/1907)) and the
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

## Payment-path liveness

When something outside the lessee's control blocks payment, the counterparty
should not be able to move the lease towards default in the meantime.
`test/liveness/` reproduces each case. The index cases are closed by the
payment-path liveness rule of the spec:

- **A.** `declareDefault` and `terminateForDefault` revert with
  `PaymentPathUnavailable` while the index is stale.
- **B.** They revert with `RecoveryGraceActive` until the index has been
  continuously fresh for the recovery grace `G = maxOracleStaleness / 2`
  (`recoveryGrace(leaseId)`). Freshness over that window is read from the
  oracle's own history (`IConversionOracleHistory`: round `updatedAt` for
  Chainlink-style feeds, recording time for attested rates), never from a
  timestamp a caller supplies. Because `G < maxOracleStaleness`, every grace
  period completes unless a further outage begins (and within the history
  limit below): an outage delays default by at most its length plus `G`.
  `G = maxOracleStaleness / 2` is this reference's policy, not a
  recommendation: a 30-day tolerance gives a 15-day grace, a 2-hour tolerance a
  1-hour grace. Whether that is a commercially reasonable time to pay is for
  the agreement to decide.

An indexed lease with a tolerance must use an oracle that implements
`IConversionOracleHistory`; `createLease` reverts with `OracleWithoutHistory`
otherwise; the Chainlink and composed adapters also refuse, at deployment, a
feed whose rounds cannot be read back (`NoRoundHistory`), even for leases
that set no tolerance. The probe only reads the latest round, so it rejects
feeds without `getRoundData` but cannot prove deeper history exists. A round with an
invalid answer counts as an outage, since `pay()` reverts while it is the
latest. Arrears and penalties keep accruing during an outage: the rule
restricts default actions, it does not waive penalties.

Costs and limits, on the lessor's side:

- The history walk examines at most 256 observations and fails closed. If a
  feed updates more than ~256 times within `G` (e.g. every 6 s with a 1-hour
  tolerance), default stays blocked for as long as that cadence lasts, even
  though the index is perfectly fresh (`test_H17`). After a phase change it
  stays blocked for `G`. This reference is therefore only suitable for feeds
  whose cadence keeps well under 256 updates per `G` (daily or hourly indices
  with tolerances of hours or days); a production version would need a walk
  that makes progress across transactions or skips provably gap-free spans.
- If the index never recovers (e.g. a retired feed), default stays blocked; the
  oracle cannot be replaced after origination in this reference, so mutual
  termination is the only exit. The spec asks implementations to document a
  replacement path.
- Gas: `declareDefault` with ~240 rounds in the grace window measured 547k gas
  against the mock feed (warm storage, `test_H12`); expect more on a real,
  proxied feed. With a 1-day feed and a tolerance of a few days the walk reads
  a handful of rounds.
- Rule B trusts the oracle's answer about its own history, just as `pay()`
  trusts its rate: an oracle chosen at origination that misreports its history
  can skip the grace. Use the adapters in `src/oracles/` or audit a custom one.
- The history walk detects stale intervals and invalid answers. Other reasons
  for `latestRate` to revert (e.g. a feed changing decimals) are only detected
  at the current instant.
- With `maxOracleStaleness = 0` the index is never stale and the grace does not
  apply; default actions still revert while the rate cannot be read.
- Release of the asset upon default (asset-bound extension) is subject to the
  same rule in the spec; this reference does not implement asset release.

| Case | Lessee can pay? | Default / termination possible? |
| --- | --- | --- |
| Index oracle stale past `maxOracleStaleness` | No (`StaleOracle`) | **No** (A) |
| Index recovers; default attempted in the same block | Yes, within `G` | **Not before `G`** (B) |
| Chain downtime longer than the tolerance, indexed lease | Yes, within `G` | **Not before `G`** (the feed's history shows the gap) |
| Chain downtime, fixed-denomination lease (or shorter than the tolerance) | Not in time | Yes, in the first block after resuming — known issue |
| Lessor position held by an address blacklisted by the payment token | No | Yes, and the holder can induce it — known issue; the spec recommends pull payments |
| Payment token paused by its issuer | No | Yes — documented residual risk |

The liveness invariant checks rules A and B against an independent model in
both directions (no default action while blocked, none rejected while allowed).
Its token-side part only reports by default; to enforce it:
`LIVENESS_STRICT=true forge test --match-contract LivenessInvariantTest`.

## Layout

| Path | Contents |
| --- | --- |
| `src/IFinancialLease.sol` | Core interface |
| `src/IFinancialLeaseAnchored.sol`, `src/IFinancialLeaseAssetBound.sol` | Optional extensions |
| `src/FinancialLease.sol` | Reference implementation |
| `src/IConversionOracle.sol` | Oracle interface used by the implementation |
| `src/IConversionOracleHistory.sol` | Oracle freshness history, used by the liveness rule |
| `src/oracles/` | Adapters: Chainlink feed, composed feeds, attested (manually published) rate; `FreshnessHistory` walks their history |
| `src/MockUVAOracle.sol` | Test oracle |
| `test/` | Unit, scenario, fuzz and invariant tests |
| `test/liveness/` | Dependency-failure matrix and liveness invariant |
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
