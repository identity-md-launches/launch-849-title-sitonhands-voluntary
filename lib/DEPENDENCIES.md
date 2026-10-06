# Vendored dependencies

All required Solidity sources and upstream licenses are ordinary repository files. No install step,
submodules, or network access is needed to build or test with the pinned compiler available.

- `forge-std`: upstream `foundry-rs/forge-std`, tag `v1.9.7`, full `src/` plus MIT and Apache licenses.
  Source: https://github.com/foundry-rs/forge-std/tree/v1.9.7
- OpenZeppelin Contracts: upstream `OpenZeppelin/openzeppelin-contracts`, tag `v5.0.2`, MIT license.
  Only `IERC20`, `IERC20Permit`, `SafeERC20`, `Address`, and `ReentrancyGuard` are needed and vendored.
  Source: https://github.com/OpenZeppelin/openzeppelin-contracts/tree/v5.0.2

Upstream Solidity source files are unmodified.
