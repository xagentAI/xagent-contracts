# XAgent Contracts Design: XPoint + CheckIn

Date: 2026-05-07  
Status: Ready for implementation  
Target chain: X Layer mainnet (196) and testnet (195)

## 1. Objective

Build two production-grade contracts for XAgent:

1. `XPoint` token contract
2. `CheckIn` reward contract

The implementation follows the best-practice baseline used in `multi-token-claim` and modernizes behavior from:

- `UXUYTokenV2.sol` (token-side legacy patterns)
- `UXCheckIn.sol` (check-in + signature-side legacy patterns)

## 2. Scope and Non-Goals

### In Scope

- Upgradeable `XPoint` via UUPS proxy
- Upgradeable `CheckIn` via UUPS proxy
- Role-based minting from `CheckIn` into `XPoint`
- Whitelist + blacklist + pause controls on `XPoint`
- EIP-712 signature verification for `CheckIn` claim flow
- Foundry-based build/test/deploy/verify setup for X Layer

### Out of Scope

- Legacy UXUY 1:1 migration contract
- Governance voting checkpoints (`ERC20Votes`)
- Additional reward channels beyond CheckIn

## 3. Architecture

### 3.1 Contracts

- `src/XPoint.sol`
  - Upgradeable ERC20 with burnable + permit extensions
  - Access-control split across admin/operator/pauser/minter responsibilities
  - Transfer gating via whitelist + blacklist + pause
  - Configurable max supply (`0` means uncapped)

- `src/CheckIn.sol`
  - Upgradeable signature-authorized reward mint entrypoint
  - Claim replay protection using bitmap claim IDs
  - Calls `xpoint.mint(msg.sender, amount)` after verification

### 3.2 Integration Boundary

- `CheckIn` depends only on `IXPoint.mint(address,uint256)` and role grant wiring.
- `XPoint` does not depend on `CheckIn` internals; only role permissions matter.

This keeps each unit independently understandable and testable.

## 4. XPoint Design

### 4.1 Inheritance

`Initializable`, `UUPSUpgradeable`, `ERC20Upgradeable`, `ERC20BurnableUpgradeable`, `ERC20PermitUpgradeable`, `ERC20PausableUpgradeable`, `Ownable2StepUpgradeable`, `AccessControlUpgradeable`.

### 4.2 Role Model

- `DEFAULT_ADMIN_ROLE`: role administration + `setMaxSupply`
- `MINTER_ROLE`: `mint`, `mintBatch`
- `OPERATOR_ROLE`: whitelist/blacklist mutators + whitelist-mode toggle
- `PAUSER_ROLE`: `pause`, `unpause`

### 4.3 Ownership and Admin Synchronization

`_transferOwnership` is overridden to keep `DEFAULT_ADMIN_ROLE` aligned with current `owner`.

Reason: avoid role drift where owner and role admin diverge after `acceptOwnership`.

Admin invariant:

- owner is the sole `DEFAULT_ADMIN_ROLE` holder.
- ownership transfer revokes default admin from old owner and grants it to new owner.
- adding extra default admins is out of policy for this project.

### 4.4 State

- `_blacklist[address] => bool`
- `_whitelist[address] => bool`
- `whitelistModeEnabled`
- `maxSupply` (`0` means no cap)
- `_gap[40]`

### 4.5 Transfer Policy

Enforced in `_update(from,to,value)`:

1. Blacklist checks for `from` and `to`
2. If whitelist mode on and both sides are non-zero:
   - at least one side must be whitelisted
3. Call `super._update(...)` to apply `ERC20PausableUpgradeable`'s pause guard

`address(0)` is rejected in whitelist/blacklist mutators to prevent accidental global mint/burn freeze via blacklisting zero address.

### 4.6 Mint and Supply

- `mint(to, amount)` (`MINTER_ROLE`)
- `mintBatch(to[], amounts[])` (`MINTER_ROLE`)
- `setMaxSupply(newCap)` (`DEFAULT_ADMIN_ROLE`)
  - require `newCap == 0 || newCap >= totalSupply()`

Cap semantics: admin-controlled cap. Admin can raise cap or set uncapped (`0`).

### 4.7 Initialization

`initialize(name, symbol, owner_, operator_, pauser_, maxSupply_, whitelistMode_)`:

- `owner_` non-zero required
- if `operator_` or `pauser_` is zero, default to `owner_`
- initialize all inherited modules explicitly
- grant operator/pauser roles
- set cap and whitelist mode

### 4.8 Security Properties

- Pausable circuit breaker
- Granular roles (no monolithic super operator)
- Role/owner sync on transfer
- UUPS upgrade restricted to owner
- `renounceOwnership` disabled
- Custom errors for explicit failure semantics

## 5. CheckIn Design

### 5.1 Inheritance

`Initializable`, `UUPSUpgradeable`, `EIP712Upgradeable`, `Ownable2StepUpgradeable`, `PausableUpgradeable`.

### 5.2 State

- `IXPoint xpoint`
- `address signer`
- `BitMaps.BitMap _claimed`
- transient reentrancy lock
- `_gap[46]`

Replay scope policy: `claimId` is globally unique across all users for this contract instance.
The backend signer service must never issue the same `claimId` twice.
Backend generation may be monotonic or random, but uniqueness is mandatory.

### 5.3 Signature and Replay

Typehash:

`keccak256("CheckIn(address account,uint256 amount,uint256 claimId,uint256 deadline)")`

Properties:

- caller-bound (`account = msg.sender`)
- deadline-bound
- replay-protected by bitmap on `claimId`

### 5.4 CheckIn Flow

`checkIn(amount, claimId, deadline, signature)`:

1. not paused
2. non-reentrant
3. amount > 0
4. not expired
5. claimId not used
6. recover signer from EIP-712 digest
7. mark claimId used
8. mint XPoint to caller
9. emit `CheckedIn` (after successful mint, no event on failed mint)

Expected critical custom errors include:

- `ZeroAddress`, `ZeroAmount`
- `CheckInExpired`, `AlreadyCheckedIn`, `InvalidSignature`
- reentrancy guard error on nested entry

### 5.5 Admin Surface

- `setSigner`
- `setXPoint`
- `pause` / `unpause`
- `rescueTokens`
- `rescueETH`
- owner-only upgrades
- `renounceOwnership` disabled

Method invariants:

- `setSigner(newSigner)` reverts on zero address and emits `SignerUpdated(old,new)`.
- `setXPoint(newXPoint)` reverts on zero address and emits `XPointUpdated(old,new)`.
- same-address updates are allowed and still emit events for explicit operational traceability.
- after `setXPoint`, check-in is expected to fail until `MINTER_ROLE` is granted to CheckIn on the new token.
- runbook requirement: `setXPoint` must be followed by role wiring in the same maintenance window.

### 5.6 Initialization and Upgrade Safety

`initialize(address xpoint_, address signer_, address owner_)`:

- require `xpoint_`, `signer_`, `owner_` are non-zero
- initialize modules in order:
  - `__EIP712_init("XAgentCheckIn", "1")`
  - `__Pausable_init()`
  - `__Ownable_init(owner_)`
  - `__UUPSUpgradeable_init()`
- set `xpoint` and `signer`
- constructor disables initializers
- `_authorizeUpgrade` is owner-only
- `renounceOwnership` reverts

## 6. Testing Strategy

### 6.1 Base Fixture

- Deploy implementation + proxy for both contracts
- Deterministic signer key helpers
- Wire `MINTER_ROLE` from XPoint to CheckIn

### 6.2 XPoint Tests

- Initialization, role grants, zero/default behavior
- Minting and cap enforcement
- Batch validation and role checks
- Whitelist and blacklist transfer constraints
- Zero-address guard in list mutators
- Pause behavior and pauser-role enforcement
- Ownership/admin role sync on ownership transfer
- Permit flow and replay/deadline failures
- Upgrade continuity with storage checks

### 6.3 CheckIn Tests

- Happy path check-in and mint
- Signature mismatch permutations
- Replay protection
- Deadline expiry
- Signer rotation:
  - old signer signature fails after rotation
  - new signer signature succeeds after rotation
- Pause and admin methods
- XPoint switch behavior:
  - check-in fails after `setXPoint(new)` before role wiring
  - check-in succeeds after new token grants `MINTER_ROLE` to CheckIn
- Reentrancy guard behavior
- Upgrade continuity

## 7. Deployment and Operations

### 7.1 Toolchain

- Solidity 0.8.34
- Foundry + Soldeer
- OZ v5.6.1 dependencies
- OpenZeppelin Foundry upgrades plugin

### 7.2 EVM Version

Pin `evm_version = "cancun"` by default for X Layer compatibility and EIP-1153 support.

Transient lock policy:

- EIP-1153 support on X Layer testnet is a hard pre-deploy gate.
- If EIP-1153 check fails, switch CheckIn to non-transient `ReentrancyGuardUpgradeable` before release.
- Acceptance criteria:
  - run a testnet smoke script that deploys CheckIn and executes a successful `checkIn`.
  - if transient behavior breaks deploy/runtime, fallback is mandatory.
  - fallback branch must pass full test suite with unchanged external behavior.

### 7.3 Verification

Use OKLink verifier in Foundry with:

- chain short names: `XLAYER`, `XLAYER_TESTNET`
- `--api-key` flag

### 7.4 Trust Model

Admin/owner can:

- manage roles
- mutate cap (`>= totalSupply`, or uncapped)
- pause/unpause
- upgrade implementation

Production recommendation: owner should be multisig or timelock.

## 8. Risks and Mitigations

1. **Role misconfiguration risk**
   - Mitigation: explicit wiring script + tests for role gates
2. **Upgrade governance risk**
   - Mitigation: Ownable2Step + production multisig owner
3. **Signature backend operational risk**
   - Mitigation: signer rotation path + deterministic signing tests
4. **Chain feature mismatch (EIP-1153)**
   - Mitigation: testnet smoke check before merge/deploy

## 9. Deliverables

- Contracts: `src/XPoint.sol`, `src/CheckIn.sol`
- Tests: `test/Base.t.sol`, `test/XPoint.t.sol`, `test/CheckIn.t.sol`
- Scripts: `script/DeployXPoint.s.sol`, `script/DeployCheckIn.s.sol`, `script/Wire.s.sol`
- Docs: `README.md`, `docs/dependencies.md`, `docs/best-practices.md`

This spec is ready for direct implementation.
