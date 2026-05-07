# Dependencies Inventory

Status date: 2026-05-07

## Toolchain

- Solidity compiler: `0.8.34` (`foundry.toml`)
- Foundry: `forge` (local + CI)
- Soldeer: dependency manager (`forge soldeer install`)

## Solidity dependencies

### `@openzeppelin/contracts` `5.6.1`

- Source: OpenZeppelin contracts
- Used in:
  - `src/CheckIn.sol` (`BitMaps`, `ECDSA`, `SafeERC20`, `IERC20`)
  - test + script proxy imports (`ERC1967Proxy`)

### `@openzeppelin/contracts-upgradeable` `5.6.1`

- Used in:
  - `src/XPoint.sol`
  - `src/CheckIn.sol`

### `forge-std` `1.15.0`

- Used in:
  - `test/*.t.sol`
  - `script/*.s.sol`

### `openzeppelin-foundry-upgrades` `0.4.0`

- Local dependency directory: `dependencies/openzeppelin-foundry-upgrades-0.4.0`
- Included for upgrade workflow compatibility and future storage-layout tooling.

## Locking and reproducibility

- `soldeer.lock` pins resolved commits
- CI cache key includes `soldeer.lock`
- `foundry.toml` pins versions + tags for deterministic installs

## Runtime assumptions

- `evm_version = "cancun"` in `foundry.toml`
- EIP-1153 support required by transient reentrancy guard in `CheckIn`
