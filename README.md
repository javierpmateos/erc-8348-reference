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

- The lessor's position is an ERC-721 token (`tokenId == leaseId`), so it can be
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

## Layout

| Path | Contents |
| --- | --- |
| `src/IFinancialLease.sol` | Core interface |
| `src/IFinancialLeaseAnchored.sol`, `src/IFinancialLeaseAssetBound.sol` | Optional extensions |
| `src/FinancialLease.sol` | Reference implementation |
| `src/IConversionOracle.sol` | Oracle interface used by the implementation |
| `src/oracles/` | Adapters: Chainlink feed, composed feeds, attested (manually published) rate |
| `src/MockUVAOracle.sol` | Test oracle |
| `test/` | Unit, scenario, fuzz and invariant tests (76) |
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

[CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/), like the ERC.
