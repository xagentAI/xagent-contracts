# Dependencies Inventory

Status date: 2026-09-29

## Toolchain

- Solidity compiler: `0.8.37` (`foundry.toml`)
- Foundry: `forge` `1.8.3` locally; CI uses `foundry-rs/foundry-toolchain@v1` without a version pin (latest stable)
- Soldeer: dependency manager (`forge soldeer install`)

## Solidity dependencies

### `@openzeppelin/contracts` `5.7.0`

- Source: OpenZeppelin contracts
- Used in:
  - `src/CheckIn.sol` (`BitMaps`, `ECDSA`, `SafeERC20`, `IERC20`)
  - `src/UsageAttestation.sol` (`Address`, `SafeERC20`, `IERC20`)
  - test + script proxy imports (`ERC1967Proxy`)

### `@openzeppelin/contracts-upgradeable` `5.7.0`

- Used in:
  - `src/XPoint.sol`
  - `src/CheckIn.sol`
  - `src/UsageAttestation.sol`

### `forge-std` `1.16.2`

- Used in:
  - `test/*.t.sol`
  - `script/*.s.sol`

### `openzeppelin-foundry-upgrades` `0.4.1`

- Local dependency directory: `dependencies/openzeppelin-foundry-upgrades-0.4.1`
- Used in `script/DeployUsageAttestation.s.sol` (`Upgrades.deployUUPSProxy`).
- Upgrade-safety validation shells out to `npx @openzeppelin/upgrades-core`, so it needs Node.js and `--ffi` on the
  command line. `ffi` stays `false` in `foundry.toml`; the test suite does not use FFI.
- Reads build artifacts from `out/` (`fs_permissions` read access) and needs a clean build (`--force`).

## Locking and reproducibility

- `soldeer.lock` pins resolved commits
- CI cache key includes `soldeer.lock`
- `foundry.toml` pins versions + tags for deterministic installs

## Runtime assumptions

- `evm_version = "cancun"` in `foundry.toml`
- EIP-1153 support required by transient reentrancy guard in `CheckIn`
