# Additional SitOnHands tests

These suites supplement the existing unit, deployment, and invariant tests without
changing the application or its configuration. They reuse the existing test-only
`MockIMD`; no token is deployed as an application and no network is required.

| Suite | Additional coverage |
| --- | --- |
| `SitOnHands.edges.t.sol` | One-unit and full `uint256` principal; aggregate debt at the integer limit; both invalid duration ranges; unknown IDs while real funds are held; revoked approvals; token-spender and transaction-origin isolation; long-unclaimed positions; accounting during a transfer callback; repeated full-balance relocking and replay rejection. |
| `SitOnHands.failure-invariant.t.sol` | Three actors with fixed initial inventories; random approvals, deposits, donations, time advances, boundary withdrawals, unauthorized/unknown/repeated withdrawals, invalid locks, and incoming/outgoing token failures. |

Each new stateless fuzz property runs 1,000 cases. The new invariant runs 256
sequences of 96 calls, with unexpected handler reverts treated as failures. Its
oracle records successful call inputs independently of vault storage and checks:

- Every actor's cash, allowance, outstanding debt, and cumulative payouts.
- Vault backing equals outstanding principal plus tracked donations.
- The fixed token supply equals the sum held by the actors and vault.
- IDs, owners, principal, deadlines, paid status, and withdrawal eligibility agree
  with the recorded claims after every handler call.
- Failed operations preserve all claims, balances, and allowances, including
  rollback of token fees and burns.
- Once transfers operate normally and all deadlines pass, every remaining claim
  returns its exact principal and only donations remain in the vault.

Three positions are seeded before each invariant sequence so rejection handlers
can operate immediately. A deterministic handler test additionally exercises all
five transfer failure modes (false return, revert, no-op, recipient fee, sender
fee), recovery, and relocking; counters verify these branches actually ran.
Expected reverts are checked explicitly rather than swallowed. Donations spend
actor inventory, and no handler mints during a random sequence.

Run from the repository root:

```sh
forge build --offline --out test/scratch/out --cache-path test/scratch/cache
forge test --offline --out test/scratch/out --cache-path test/scratch/cache
```

The supplied compiler and vendored libraries are sufficient. Output paths keep
generated artifacts within the disposable scratch area; delivered tests do not
import anything from that area. Plain `forge build` and `forge test` use the same
tests with the repository's default artifact locations.

These are offline behavioral tests. The extreme supply cases are arithmetic stress
inputs, not claims about IMD's live supply. The assignment does not identify a
canonical mainnet IMD address, so this suite does not establish compatibility with
the live token or validate its administrator powers. No implementation defect was
reproduced by these added cases.
