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

| Test | Reference | A: block while stale | B: A + grace after recovery | C: pull payments | D: tender |
| --- | --- | --- | --- | --- | --- |
| P0 genuine default still works | yes | yes | yes | yes | yes |
| P1 no default while index stale | no | **yes** | **yes** | no | **yes** |
| P2 no default in the recovery block | no | no | **yes** | no | **yes**, if the lessee tendered |
| P3 lessee can pay with holder blacklisted | no | no | no | **yes** | no |
| P4 no default while token paused | no | no | no | no | no |
| Gas, ordinary `pay()` | 159,595 | 159,595 | 160,015 | 206,244 | 165,978 |

New risks found:

- **B**: if attestations keep arriving later than the tolerance, the grace
  window never completes and a genuine default is blocked indefinitely (X-B1).
  B also needs an oracle that keeps history.
- **C**: the lease contract now holds funds, so solvency becomes an invariant
  (X-C1 checks it) and the contract becomes a custody target.
- **D**: a dust tender is rejected (X-D1) and the tender is applied as of the
  tender time (X-D2), but if the index never returns the funds stay in escrow
  and default stays blocked indefinitely (X-D3): it needs a timeout or fallback.
- **P4** (issuer pauses the token) is not closed by any variant: the contract
  cannot observe a pause generically. It can only be documented.
