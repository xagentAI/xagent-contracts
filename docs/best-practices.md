# Smart Contract Best Practices Mapping

This document maps key implementation choices in this repository to practical best-practice categories.

## 1) Upgradeability and lifecycle safety

- UUPS proxies with owner-gated upgrades:
  - `src/XPoint.sol`
  - `src/CheckIn.sol`
- Implementation initialization lock (`_disableInitializers`) in constructors
- Explicit initializer module setup in both contracts
- Reserved storage gaps for safe future upgrades

## 2) Access control and operations

- Granular roles in `XPoint` (`MINTER_ROLE`, `OPERATOR_ROLE`, `PAUSER_ROLE`)
- Owner-only privileged operations in `CheckIn` (`setSigner`, `setXPoint`, upgrades, rescue)
- Ownership renounce disabled in both contracts to avoid accidental governance orphaning
- Ownership transfer keeps `DEFAULT_ADMIN_ROLE` synchronized in `XPoint`

## 3) Signature security

- EIP-712 typed data flow for CheckIn claims:
  - domain bound to chain id + contract
  - caller-bound account field
  - deadline enforcement
- Global replay protection with bitmap claim IDs
- Signature recovery through OpenZeppelin `ECDSA.recoverCalldata`

## 4) Token transfer controls

- Pausable transfer path in `XPoint` via `ERC20PausableUpgradeable`
- Blacklist enforced for both sender and receiver
- Optional whitelist mode requiring sender or receiver allowlisted
- Zero-address guard for list mutators to prevent accidental mint/burn freeze effects

## 5) Failure semantics and observability

- Custom errors for core failure paths
- Explicit events for minting, cap updates, list updates, signer/token updates, and check-ins
- Deterministic revert assertions in tests

## 6) Testing and verification

- Comprehensive Foundry tests in:
  - `test/XPoint.t.sol`
  - `test/CheckIn.t.sol`
- Proxy-upgrade continuity tests for both contracts
- Signature edge-case and replay tests
- CI pipeline runs formatting, build size output, and full test suite

## 7) Deployment hygiene

- Scripted deployments:
  - `script/DeployXPoint.s.sol`
  - `script/DeployCheckIn.s.sol`
  - `script/Wire.s.sol`
- X Layer + OKLink verification command templates documented in `README.md`
