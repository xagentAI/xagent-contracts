# Dependencies Inventory

Status date: 2026-10-23

## Toolchain

- Solidity compiler: `0.8.38` (`foundry.toml`). Bumped from `0.8.37` for [SOL-2026-7 `YulOptimizerKnowledgeBaseStaleBookkeeping`](https://blog.soliditylang.org/2026/10/22/yul-optimizer-knowledge-base-stale-bookkeeping-bug/), which affects optimized `via_ir` builds from `0.8.19` to `0.8.37`.
- Foundry: `forge` `1.8.x`; CI uses `foundry-rs/foundry-toolchain@v1` without a version pin (latest stable)
- Soldeer: dependency manager (`forge soldeer install`)

## Solidity dependencies

### `@openzeppelin/contracts` `5.7.0`

- Source: OpenZeppelin contracts
- Used in:
  - `src/CheckIn.sol` (`BitMaps`, `ECDSA`, `SafeERC20`, `IERC20`)
  - `src/UsageAttestation.sol` (`Address`, `SafeERC20`, `IERC20`)
  - `src/XAgentAirdrop.sol` (`EIP712`, `Pausable`, `ReentrancyGuardTransient`, `ECDSA`, `BitMaps`, `SafeCast`, `SafeERC20`, `Address`, `IERC20`)
  - test + script proxy imports (`ERC1967Proxy`)

### `@openzeppelin/contracts-upgradeable` `5.7.0`

- Used in:
  - `src/XPoint.sol`
  - `src/CheckIn.sol`
  - `src/UsageAttestation.sol`

### `forge-std` `1.17.0`

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
- EIP-1153 support required by transient reentrancy guard in `CheckIn` and `XAgentAirdrop`

## External on-chain dependencies (`XAgentAirdrop`)

`XAgentAirdrop` interacts with canonical Safe contracts deployed at deterministic addresses on Ethereum mainnet (and other EVM chains via `Safe Singleton Factory`):

- `safe-smart-account` `v1.5.0`:
  - `Safe` singleton: `0xFf51A5898e281Db6DfC7855790607438dF2ca44b`
  - `SafeProxyFactory`: `0x14F2982D601c9458F93bd70B218933A6f8165e7b`
  - `MultiSendCallOnly`: `0xA83c336B20401Af773B6219BA5027174338D1836`
- `safe-modules` `allowances/v1.0.0`:
  - `AllowanceModule`: `0x691f59471Bfd2B7d639DCF74671a2d648ED1E331`
