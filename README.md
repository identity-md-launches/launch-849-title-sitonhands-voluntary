# SitOnHands

An ownerless, non-upgradeable vault for the **existing Ethereum mainnet IMD ERC-20**. Each deposit
creates an independent, nontransferable position. There is no launch token, fee, yield, owner,
pause, upgrade, early exit, deadline change, or rescue/sweep function.

## Use

1. Approve the vault to spend the intended amount of IMD.
2. Call `lock(amount, durationSeconds)` from the account whose IMD will be locked. Amounts are
   raw token units; the vault does not assume a decimal count. Durations are inclusive:
   `MIN_DURATION = 1 days` (86,400 seconds) and `MAX_DURATION = 365 days` (31,536,000 seconds).
3. Save the returned position ID or find it in `Locked`. IDs start at zero and are never reused.
4. From that same account, call `withdraw(positionId)` when the on-chain timestamp is at least
   `unlockTime`. The exact deposited principal returns to that account. Withdrawal is not automatic
   and has no expiry; users need ETH for gas. Losing access to the depositing account loses access
   to its funds. A smart-contract depositor must itself support calling the withdrawal function.

`positions(id)` returns `(depositor, amount, unlockTime, withdrawn)` and retains paid records.
`canWithdraw(id)` checks existence, maturity and unpaid status; it does not predict token failures.
`lockedBalance(account)` and `totalLocked()` include matured but unclaimed principal. Both lock
and withdrawal emit the depositor, amount, unlock time and ID. Multiple deposits never change
one another's deadlines.

## Build and check

```sh
forge build
forge test
forge fmt --check
```

The compiler is pinned to Solidity **0.8.26**, with Cancun, optimizer 200 runs and
`bytecode_hash = "none"`. FFI and filesystem cheatcode permissions are disabled. Dependencies,
versions and licenses are vendored under `lib/`; no dependency installation, submodule, environment
configuration or RPC is needed for tests. The verifier must provide the pinned compiler.

Tests cover exact maturity, early/duplicate/foreign withdrawals, independent positions, duration
bounds, approvals, transfer failures and rollback, token fees, no-return tokens, donations,
reentrancy across both entry points, deployment validation, factory construction, runtime size and
forbidden opcodes. Two fuzz tests run 256 cases each. The stateful invariant runs 128 sequences of
64 calls across three accounts and verifies principal conservation, unchanged ownership/deadlines,
and full eventual redemption. Token minting exists only in test mocks.

## Deployment parameters and verification

**The supplied assignment contains no canonical IMD address or mainnet RPC. The live token address
and its behavior have not been verified, and no transaction has been broadcast.** Obtain the
canonical address from the project's authoritative deployment record before deployment. Do not
substitute a same-symbol token or a newly deployed mock. A symbol check cannot prove identity.

The sole application is `src/SitOnHands.sol:SitOnHands`. Its nonpayable constructor takes exactly
one static argument, `address imd_`, which becomes immutable. No owner or initialization call is
needed. Construction is independent of `msg.sender`, so it also works through the project factory.
The constructor rejects zero and deliberately makes no external token calls, supporting offline
deployment rehearsals. Deployment tooling must check the token's code and identity on mainnet;
a nonzero address without ERC-20 code cannot accept locks.

`script/DeploySitOnHands.s.sol:DeploySitOnHands` takes the address explicitly through `run(address)`.
It rejects chains other than Ethereum mainnet (chain ID 1), missing token code, and a symbol other
than `IMD`. Tests call this same entry point directly with local mocks. To simulate after setting
`IMD_ADDRESS` to the authenticated address and `MAINNET_RPC_URL` to your mainnet RPC:

```sh
forge script script/DeploySitOnHands.s.sol:DeploySitOnHands \
  --sig 'run(address)' "$IMD_ADDRESS" --rpc-url "$MAINNET_RPC_URL"
```

For the contributor-network launch, hand the same creation bytecode and constructor address to
the project factory; the separate manifest/deployment step supplies `launch.json`. Do not deploy
the script or mocks as applications. For a separately authorized direct deployment, the operator
can add `--broadcast --verify` and their own signer options to the simulated command.

After either deployment route, verify the application source with the same build configuration:

```sh
forge verify-contract "$VAULT_ADDRESS" src/SitOnHands.sol:SitOnHands \
  --chain-id 1 --watch \
  --constructor-args "$(cast abi-encode 'constructor(address)' "$IMD_ADDRESS")"
```

The operator supplies explorer credentials if required, confirms the verified runtime and immutable
`imd()` address, and publishes the confirmed vault address. This project neither reads wallet keys
nor chooses a deployer account. No post-deployment administrative responsibilities exist in the vault.

## Custody assumptions and release responsibilities

IMD must have truthful ERC-20 balances, stable units, and exact transfers. OpenZeppelin SafeERC20
checks failed/false returns and supports empty returns; balance deltas on **both sides** of each
transfer reject fees and no-op transfers. Reentrancy guards protect both mutating entry points,
and withdrawal marks the position paid before transferring. A failed transfer reverts the entire
operation, preserving the position for retry.

Rebasing, confiscation, blacklisting, pausing, or a later change in the token's own implementation
can make withdrawals impossible; the vault cannot override the token. Validate the actual IMD
implementation and any token administrator powers before release. These mock-based tests do not
establish compatibility with an unidentified live token.

Direct token donations create no position and are irretrievable, including accidental transfers
of other tokens. Donations never increase a depositor's principal. Ordinary ETH transfers revert;
any forcibly delivered ETH is also irretrievable. Time is Ethereum's `block.timestamp`, not a promise
of a particular wall-clock execution time.

Release requires a separate independent adversarial review and a mainnet token compatibility
check. Local Foundry tests and built-in linting were run; Slither, Mythril, a mainnet fork test, and
explorer verification were not run. The vault deliberately has no administrative recovery path.
