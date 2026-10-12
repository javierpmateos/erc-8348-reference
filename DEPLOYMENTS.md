# Deployments

## ERC-8348 demo — Base Sepolia (chainId 84532)

A live, throwaway deployment of the reference implementation with three example
leases, so you can read and pay real leases with `cast` without compiling
anything. **Testnet only**: the payment token has a public `mint()` and the
agreements are not real (`agreementHash = keccak256("DEMO — not a real agreement")`).

> **Status: live.** Deployed on 2026-10-11 (20:14 UTC) with the UVA attested at
> 2,150.53 ARS (BCRA value for 11/10/2026). The three contracts are
> source-verified on Blockscout.

| Contract | Address | Explorer |
| --- | --- | --- |
| `FinancialLease` | `0x63619da0eCf942eA756D35bBAFe206c1Fc8fEf53` | [verified source](https://base-sepolia.blockscout.com/address/0x63619da0eCf942eA756D35bBAFe206c1Fc8fEf53?tab=contract) |
| `AttestedConversionOracle` (UVA → tARS) | `0x2925dbD907a5822948FdEb4502747f795229BdF8` | [verified source](https://base-sepolia.blockscout.com/address/0x2925dbD907a5822948FdEb4502747f795229BdF8?tab=contract) |
| `MockStablecoin` (tARS, 6 decimals, public mint) | `0xfd43485fdE48fac755160206fAeF1f4284C8Fc49` | [verified source](https://base-sepolia.blockscout.com/address/0xfd43485fdE48fac755160206fAeF1f4284C8Fc49?tab=contract) |
| Deployer = lessor = oracle owner and attester | `0x9B9f2D952ec5D7E1C2Aa962c4B06ee1D52E562d6` | [address](https://base-sepolia.blockscout.com/address/0x9B9f2D952ec5D7E1C2Aa962c4B06ee1D52E562d6) |
| Lessee (all three leases) | `0x155b44f92eFC765913F129586E06035C8D16cAF0` | [address](https://base-sepolia.blockscout.com/address/0x155b44f92eFC765913F129586E06035C8D16cAF0) |

| leaseId | Case | Denomination | Schedule | Notes |
| --- | --- | --- | --- | --- |
| `1` | A — current | UVA (attested oracle) | 36 × 2,500 UVA, monthly, first due 30 days after deploy | Purchase option = 1 installment (2,500 UVA) |
| `2` | B — fixed rate | ARS (`oracle = address(0)`, identity conversion) | 12 × 12,500,000 tARS, monthly, first due 30 days after deploy | Same asset as A |
| `3` | C — in arrears | UVA (attested oracle) | 24 × 3,000 UVA, monthly, schedule started ~65 days before deploy | First two due dates already past, nothing paid, `penaltyBpsPerDay = 10` |

Common parameters: `jurisdiction = "AR"`, `terminationDelay = 30 days`,
`maxOracleStaleness = 30 days`, "monthly" = every 30 days.

Scales: units of account have 18 decimals (1 UVA = `1e18`); tARS has 6
decimals; the oracle rate is tARS per UVA in tARS decimals (2,150.53 ARS/UVA =
`2150530000`). Lease B has no oracle, so its units *are* tARS base units.

### ⚠️ The UVA oracle goes stale after 30 days — on purpose

The UVA has no on-chain feed, so the demo uses `AttestedConversionOracle`: the
attester (the deployer) publishes the rate by hand. Leases 1 and 3 were created
with `maxOracleStaleness = 30 days`, so **if nobody re-attests the UVA within 30
days, `pay()` on leases 1 and 3 starts reverting with `StaleOracle()`**. The
deploy-time attestation (2026-10-11 20:15 UTC) runs out on 2026-11-10 20:15 UTC.

That is the correct behaviour of the standard, not a bug: a lease must not
settle payments against an index observation older than its declared tolerance.
It is worth watching:

- views (`arrears`, `outstandingBalance`, `nextPayment`, `conversionRateAsOf`)
  keep answering with the last attested rate — they report, they don't enforce;
- `inputFreshness(leaseId, INPUT_INDEX_OBSERVATION)` is how a consumer detects
  it: stale when `block.timestamp - observedAt > maxStaleness`;
- lease 2 (no oracle) is never affected.
- **Known issue:** while the index is stale, arrears and penalties keep
  accruing and the lessor can still call `declareDefault` and, after the
  timelock, `terminateForDefault`, even though the lessee cannot pay. This is
  under discussion in the
  [Magicians thread](https://ethereum-magicians.org/t/erc-8348-financial-lease/29076)
  and will be addressed in the next spec revision.

Only the attester can fix it (see [Re-attesting the UVA](#re-attesting-the-uva)).

## Try it

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation)
(`cast`). Set these once:

```sh
export RPC=https://sepolia.base.org
export LEASE=0x63619da0eCf942eA756D35bBAFe206c1Fc8fEf53
export ORACLE=0x2925dbD907a5822948FdEb4502747f795229BdF8
export TARS=0xfd43485fdE48fac755160206fAeF1f4284C8Fc49
```

### Read the three leases

`status` returns the `LeaseStatus` enum: `0` Active, `1` InArrears, `2`
InDefault, `3` Terminated, `4` Completed, `5` PurchaseExercised. Amounts are in
tARS base units (divide by `1e6`).

```sh
for ID in 1 2 3; do
  echo "== lease $ID =="
  cast call $LEASE "status(uint256)(uint8)" $ID --rpc-url $RPC
  cast call $LEASE "outstandingBalance(uint256)(uint256)" $ID --rpc-url $RPC
  cast call $LEASE "arrears(uint256)(uint256)" $ID --rpc-url $RPC
  cast call $LEASE "nextPayment(uint256)(uint256,uint64)" $ID --rpc-url $RPC
done
```

Lease 3 reports `status = 1` and a non-zero `arrears` that grows by 0.10% of the
overdue principal per full day late — run it again tomorrow and it will be
higher, with no transaction in between.

### Denomination and conversion rate (UVA lease)

```sh
# ("UVA", oracle address)
cast call $LEASE "denomination(uint256)(string,address)" 1 --rpc-url $RPC

# (rate in tARS base units per UVA, asOf timestamp of the last attestation)
cast call $LEASE "conversionRateAsOf(uint256)(uint256,uint64)" 1 --rpc-url $RPC

# compare with the fixed-rate lease: ("ARS", 0x0) and (1e18, block.timestamp)
cast call $LEASE "denomination(uint256)(string,address)" 2 --rpc-url $RPC
cast call $LEASE "conversionRateAsOf(uint256)(uint256,uint64)" 2 --rpc-url $RPC
```

### An overdue installment (lease 3)

```sh
# (units, dueDate, paid) -> 3000000000000000000000, 1788725690, false
cast call $LEASE "paymentAt(uint256,uint256)(uint256,uint64,bool)" 3 0 --rpc-url $RPC
```

### Index freshness

`INPUT_INDEX_OBSERVATION = keccak256("erc8348.input.indexObservation")`. Returns
`(observedAt, reportedAt, maxStaleness)`; for this input both timestamps are the
oracle's `asOf` and `maxStaleness` is the lease's `maxOracleStaleness`
(`2592000` = 30 days).

```sh
cast call $LEASE "inputFreshness(uint256,bytes32)(uint64,uint64,uint64)" \
  1 $(cast keccak "erc8348.input.indexObservation") --rpc-url $RPC
```

### Mint tARS, approve and pay

`pay()` is permissionless — any address can pay any lease, and the funds go to
the current holder of the lessor position (the owner of the lease NFT) — so you
can use your own account even though you are not the lessee.
You need a little Base Sepolia ETH for gas. The commands sign with a Foundry
keystore account, so no key ever touches your shell history or a file in the
repo. Create one once (it prompts for the private key and a password); if you
already have a keystore account, skip this and put its name in `ACCOUNT` below:

```sh
cast wallet import demo-user --interactive
```

```sh
export ACCOUNT=demo-user
export ME=$(cast wallet address --account $ACCOUNT)

# 1. mint yourself 100,000,000 tARS (public mint, testnet only)
cast send $TARS "mint(address,uint256)" $ME 100000000000000 --rpc-url $RPC --account $ACCOUNT

# 2. let the lease contract pull tARS
cast send $TARS "approve(address,uint256)" $LEASE 100000000000000 --rpc-url $RPC --account $ACCOUNT

# 3. pay 1,000,000 tARS towards lease 1 (prepays part of the first installment)
cast send $LEASE "pay(uint256,uint256)" 1 1000000000000 --rpc-url $RPC --account $ACCOUNT

# 4. see the effect
cast call $LEASE "outstandingBalance(uint256)(uint256)" 1 --rpc-url $RPC
```

`pay()` converts tARS to units at the current rate, applies them to penalties
first, then overdue principal, then future installments, and never pulls more
than what is owed. If it reverts with `StaleOracle()`, see the warning above.

Please be gentle with lease 3: paying its full `arrears` cures it and it stops
being the "in arrears" example for everyone else. Small partial payments are
fine and show the penalty-first allocation.

### Re-attesting the UVA

Attester only (the deployer's keystore account). Take the value published by the BCRA and scale
it to 6 decimals:

```sh
cast send $ORACLE "attest(uint256)" $(cast parse-units 2150.53 6) \
  --rpc-url $RPC --account demo-deployer
```

## Reproducing the deployment

The script never reads a key. Foundry signs with an encrypted keystore account
(created once with `cast wallet import demo-deployer --interactive`), selected
on the command line; `--sender` must be that account's address.

```sh
export LESSEE=0x155b44f92eFC765913F129586E06035C8D16cAF0
export UVA_RATE=2150.53               # ARS per UVA as published by the BCRA
export ETHERSCAN_API_KEY=<key>        # only needed for --verify

# dry run against a fork (sends nothing)
forge script script/DeployDemo.s.sol --rpc-url https://sepolia.base.org \
  --account demo-deployer --sender 0x9B9f2D952ec5D7E1C2Aa962c4B06ee1D52E562d6

# real thing
forge script script/DeployDemo.s.sol --rpc-url https://sepolia.base.org \
  --account demo-deployer --sender 0x9B9f2D952ec5D7E1C2Aa962c4B06ee1D52E562d6 --broadcast --verify
```

- `UVA_RATE` accepts `2150.53` or `2150,53`, up to 6 decimals, no thousands
  separator.
- `--verify` uses Etherscan's API V2, which serves Basescan: one
  `ETHERSCAN_API_KEY` from <https://etherscan.io/apidashboard> works for
  chain 84532 (the old Basescan-specific keys no longer do). To verify without
  a key, use Blockscout instead:
  `--verify --verifier blockscout --verifier-url https://base-sepolia.blockscout.com/api/`.
  That is how the live deployment above was verified (after the fact, with
  `forge verify-contract`).
- The script refuses to run on any chain other than 84532.
