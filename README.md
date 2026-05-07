# XAgent Contracts

Upgradeable smart-contract package for XAgent reward points on X Layer.

## Contracts

- `XPoint` (`src/XPoint.sol`)
  - UUPS upgradeable ERC20 with `Burnable`, `Permit`, `Pausable`
  - role-based controls: `DEFAULT_ADMIN_ROLE`, `MINTER_ROLE`, `OPERATOR_ROLE`, `PAUSER_ROLE`
  - whitelist mode + blacklist transfer policy
  - configurable max supply (`0` means uncapped)

- `CheckIn` (`src/CheckIn.sol`)
  - UUPS upgradeable EIP-712 check-in verification
  - replay protection with bitmap claim IDs
  - mints `XPoint` rewards to caller after signature validation

## Trust model

`owner` (recommended: multisig/timelock) controls upgrades and keeps sole `DEFAULT_ADMIN_ROLE`:

- role assignment (`MINTER_ROLE`, `OPERATOR_ROLE`, `PAUSER_ROLE`)
- cap policy (`setMaxSupply`)
- emergency controls (`pause` / `unpause`)
- implementation upgrades (`upgradeToAndCall`)

`setMaxSupply` is admin-mutable (can be increased or set to `0`), so the cap is not immutable.

## Toolchain

- Solidity `0.8.34`
- Foundry `forge`
- Soldeer dependencies
- OpenZeppelin Contracts/Upgradeable `5.6.1`
- `forge-std` `1.15.0`

## Setup

```sh
forge soldeer install
cp .env.example .env
```

Fill required env vars:

- `PRIVATE_KEY`
- `CHECKIN_SIGNER`
- `XPOINT_NAME`
- `XPOINT_SYMBOL`
- `XPOINT_MAX_SUPPLY`
- `XLAYER_RPC_URL`
- `XLAYER_TESTNET_RPC_URL`
- `OKLINK_API_KEY`

## Build and test

```sh
forge fmt
forge build --sizes
forge test -vvv
```

## Deployment flow

1. Deploy `XPoint` proxy
2. Deploy `CheckIn` proxy
3. Wire roles (`MINTER_ROLE` to CheckIn)

### Deploy XPoint

```sh
forge script script/DeployXPoint.s.sol:DeployXPoint \
  --rpc-url $XLAYER_TESTNET_RPC_URL \
  --broadcast \
  --verify \
  --verifier oklink \
  --verifier-url https://www.oklink.com/api/v5/explorer/contract/verify-source-code-plugin/XLAYER_TESTNET \
  --api-key $OKLINK_API_KEY
```

### Deploy CheckIn

```sh
export XPOINT_ADDRESS=<xpoint_proxy_address>

forge script script/DeployCheckIn.s.sol:DeployCheckIn \
  --rpc-url $XLAYER_TESTNET_RPC_URL \
  --broadcast \
  --verify \
  --verifier oklink \
  --verifier-url https://www.oklink.com/api/v5/explorer/contract/verify-source-code-plugin/XLAYER_TESTNET \
  --api-key $OKLINK_API_KEY
```

### Wire MINTER_ROLE

```sh
export CHECKIN_ADDRESS=<checkin_proxy_address>

forge script script/Wire.s.sol:Wire \
  --rpc-url $XLAYER_TESTNET_RPC_URL \
  --broadcast
```

## X Layer network

- Mainnet: chain id `196`, RPC `https://rpc.xlayer.tech`
- Testnet: chain id `195`, RPC `https://testrpc.xlayer.tech/terigon`
- OKLink verifier chain short names: `XLAYER`, `XLAYER_TESTNET`

## EIP-1153 requirement

`CheckIn` uses transient storage for the reentrancy guard. X Layer runtime must support EIP-1153. If testnet smoke checks fail, replace with a non-transient guard before production deploy.
