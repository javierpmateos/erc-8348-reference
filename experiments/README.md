# Liveness variants (experiment)

Not part of the reference implementation and not part of ERC-8348. These are
candidate fixes for the payment-path liveness issues documented in
`test/liveness/`, each written as a small override of a copy of the reference
contract (`liveness-variants/FinancialLeaseBase.sol`), and run against the same
battery of tests.

```sh
FOUNDRY_PROFILE=experiments forge test -vv
```

Every `P` test asserts the desired property, so a failing `P` test means that
variant does not close that case. `X` tests probe new risks each variant opens.

| Test | Reference | A: block while stale | B: A + bounded grace after recovery | C: pull payments | D: tender |
| --- | --- | --- | --- | --- | --- |
| P0 genuine default still works | yes | yes | yes | yes | yes |
| P1 no default while index stale | no | **yes** | **yes** | no | **yes** |
| P2 no default in the recovery block | no | no | **yes** | no | **yes**, if the lessee tendered |
| P3 lessee can pay with holder blacklisted | no | no | no | **yes** | no |
| P4 no default while token paused | no | no | no | no | no |
| Gas, ordinary `pay()` | 159,595 | 159,595 | 160,015 | 206,244 | 165,978 |

New risks found:

- **B**: recovery is measured from the on-chain recording time of each
  observation, not from a time claimed by the attester. With late attestations,
  a genuine default is delayed by at most the grace period after each recovery
  (X-B1). That only holds if the grace period is shorter than the staleness
  tolerance, so B enforces `0 < GRACE < maxOracleStaleness` at origination
  (X-B2). Without the bound, a grace period longer than the tolerance never
  completes under late attestations and a genuine default stays blocked (X-B3,
  `VariantBUnbounded`). B also needs verifiable oracle history: Chainlink-style
  feeds expose it through round data; an attested oracle has to store it.
  Open point: each new outage restarts the grace period. That is intended when
  the outage really blocked payment, but an attester aligned with the lessee
  could use it to delay default; a cap on cumulative grace per installment is a
  possible answer.
- **C**: the lease contract now holds funds, so solvency becomes an invariant
  (X-C1 checks it) and the contract becomes a custody target.
- **D**: a dust tender is rejected (X-D1) and the tender is applied as of the
  tender time (X-D2), but if the index never returns the funds stay in escrow
  and default stays blocked indefinitely (X-D3): it needs a timeout or fallback.
- **P4** (issuer pauses the token) is not closed by any variant: the contract
  cannot observe a pause generically. It can only be documented.

Correction (October 2026): an earlier version of this file said that late
attestations block a genuine default under B indefinitely. The original X-B1
test only checked the instant right after each late attestation. The current
X-B1 checks the whole cycle and shows the delay is bounded by the grace period;
the indefinite case only arises without the bound (X-B3).

Current proposal for the standard: A and bounded B as MUST, C as SHOULD, D as
an optional extension with a mandatory timeout, and P4 documented as residual
risk.
