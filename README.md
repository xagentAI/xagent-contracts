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

- `PRIVATE_KEY` (must include `0x` prefix; `vm.envUint` parses it as hex only when prefixed)
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

## Mainnet staging deployment (X Layer)

Use dedicated staging contracts and config to avoid collision with future production labels and signatures.

- `XPointStaging` (`src/XPointStaging.sol`)
- `CheckInStaging` (`src/CheckInStaging.sol`)
- `DeployXPointStaging` (`script/DeployXPointStaging.s.sol`)
- `DeployCheckInStaging` (`script/DeployCheckInStaging.s.sol`)

Recommended staging env values:

- `XPOINT_NAME="XAgent Staging Point"`
- `XPOINT_SYMBOL="XPT-STG"`
- `CHECKIN_SIGNER=<staging signer only>`
- `XPOINT_WHITELIST_MODE=true` if you only test check-in mint flow
  - set to `false` if you must test user-to-user transfer/payment flows

### Preflight: EIP-1153 smoke check on mainnet RPC

`CheckIn` uses transient storage reentrancy lock. Verify runtime support before staging deploy:

```sh
forge script script/SmokeEIP1153.s.sol:SmokeEIP1153 \
  --rpc-url $XLAYER_RPC_URL
```

### Deploy XPointStaging

```sh
forge script script/DeployXPointStaging.s.sol:DeployXPointStaging \
  --rpc-url $XLAYER_RPC_URL \
  --broadcast \
  --verify \
  --verifier oklink \
  --verifier-url https://www.oklink.com/api/v5/explorer/contract/verify-source-code-plugin/XLAYER \
  --api-key $OKLINK_API_KEY
```

### Deploy CheckInStaging

```sh
export XPOINT_ADDRESS=<xpoint_staging_proxy_address>

forge script script/DeployCheckInStaging.s.sol:DeployCheckInStaging \
  --rpc-url $XLAYER_RPC_URL \
  --broadcast \
  --verify \
  --verifier oklink \
  --verifier-url https://www.oklink.com/api/v5/explorer/contract/verify-source-code-plugin/XLAYER \
  --api-key $OKLINK_API_KEY
```

### Wire MINTER_ROLE for staging

```sh
export CHECKIN_ADDRESS=<checkin_staging_proxy_address>

forge script script/Wire.s.sol:Wire \
  --rpc-url $XLAYER_RPC_URL \
  --broadcast
```

Record staging addresses in a dedicated section and keep them separate from production addresses.
Because both staging and production use chain id `196`, keep script names with `Staging` suffix so broadcast artifacts are clearly separated.

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

## Mainnet production deployment (X Layer)

Known issue: `forge script ... --broadcast` fails on X Layer mainnet (`chain id 196`) with
`Error: Chain 196 not supported` (reproduced on `forge 1.5.1`). `forge create` and
`forge verify-contract` both work normally against the same RPC. Until upstream resolves
this, deploy the implementation + `ERC1967Proxy(impl, initData)` pair manually with
`forge create`; the on-chain behavior is identical to the script flow.

Prerequisites:

```sh
source .env
# PRIVATE_KEY must be hex with 0x prefix for vm.envUint to parse it. If your .env stores
# the raw hex without 0x, override it for this shell:
export PRIVATE_KEY=0x<your_hex_key>

forge build --sizes
```

Run the mainnet EIP-1153 preflight first:

```sh
forge create --rpc-url $XLAYER_RPC_URL --private-key $PRIVATE_KEY --legacy --broadcast \
  script/SmokeEIP1153.s.sol:EIP1153SmokeTarget
# call probe() on the deployed address; it must return true
cast call --rpc-url $XLAYER_RPC_URL <smoke_target_address> "probe()(bool)"
```

### Deploy XPoint (implementation + proxy)

```sh
DEPLOYER=$(cast wallet address --private-key $PRIVATE_KEY)

# 1) implementation
forge create --rpc-url $XLAYER_RPC_URL --private-key $PRIVATE_KEY --legacy --broadcast \
  src/XPoint.sol:XPoint
export XPOINT_IMPL=<address_from_previous_step>

# 2) proxy with initialize(name, symbol, owner, operator, pauser, maxSupply, whitelistMode)
INIT_DATA=$(cast calldata \
  "initialize(string,string,address,address,address,uint256,bool)" \
  "$XPOINT_NAME" "$XPOINT_SYMBOL" $DEPLOYER $DEPLOYER $DEPLOYER $XPOINT_MAX_SUPPLY false)

forge create --rpc-url $XLAYER_RPC_URL --private-key $PRIVATE_KEY --legacy --broadcast \
  dependencies/@openzeppelin-contracts-5.6.1/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy \
  --constructor-args $XPOINT_IMPL $INIT_DATA
export XPOINT_ADDRESS=<proxy_address_from_previous_step>
```

### Deploy CheckIn (implementation + proxy)

```sh
# 1) implementation
forge create --rpc-url $XLAYER_RPC_URL --private-key $PRIVATE_KEY --legacy --broadcast \
  src/CheckIn.sol:CheckIn
export CHECKIN_IMPL=<address_from_previous_step>

# 2) proxy with initialize(xpoint, signer, owner)
INIT_DATA=$(cast calldata \
  "initialize(address,address,address)" \
  $XPOINT_ADDRESS $CHECKIN_SIGNER $DEPLOYER)

forge create --rpc-url $XLAYER_RPC_URL --private-key $PRIVATE_KEY --legacy --broadcast \
  dependencies/@openzeppelin-contracts-5.6.1/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy \
  --constructor-args $CHECKIN_IMPL $INIT_DATA
export CHECKIN_ADDRESS=<proxy_address_from_previous_step>
```

### Wire MINTER_ROLE (mainnet)

```sh
MINTER_ROLE=$(cast keccak "MINTER_ROLE")
cast send --rpc-url $XLAYER_RPC_URL --private-key $PRIVATE_KEY --legacy \
  $XPOINT_ADDRESS "grantRole(bytes32,address)" $MINTER_ROLE $CHECKIN_ADDRESS

# verify
cast call --rpc-url $XLAYER_RPC_URL $XPOINT_ADDRESS \
  "hasRole(bytes32,address)(bool)" $MINTER_ROLE $CHECKIN_ADDRESS
```

### Verify on OKLink

```sh
# implementations
forge verify-contract --rpc-url $XLAYER_RPC_URL \
  --verifier oklink \
  --verifier-url https://www.oklink.com/api/v5/explorer/contract/verify-source-code-plugin/XLAYER \
  --api-key $OKLINK_API_KEY --watch \
  $XPOINT_IMPL src/XPoint.sol:XPoint

forge verify-contract --rpc-url $XLAYER_RPC_URL \
  --verifier oklink \
  --verifier-url https://www.oklink.com/api/v5/explorer/contract/verify-source-code-plugin/XLAYER \
  --api-key $OKLINK_API_KEY --watch \
  $CHECKIN_IMPL src/CheckIn.sol:CheckIn

# proxies (rebuild constructor args with the same INIT_DATA used during deploy)
XPOINT_CARGS=$(cast abi-encode "constructor(address,bytes)" $XPOINT_IMPL $XPOINT_INIT)
forge verify-contract --rpc-url $XLAYER_RPC_URL \
  --verifier oklink \
  --verifier-url https://www.oklink.com/api/v5/explorer/contract/verify-source-code-plugin/XLAYER \
  --api-key $OKLINK_API_KEY --watch --constructor-args $XPOINT_CARGS \
  $XPOINT_ADDRESS \
  dependencies/@openzeppelin-contracts-5.6.1/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy

CHECKIN_CARGS=$(cast abi-encode "constructor(address,bytes)" $CHECKIN_IMPL $CHECKIN_INIT)
forge verify-contract --rpc-url $XLAYER_RPC_URL \
  --verifier oklink \
  --verifier-url https://www.oklink.com/api/v5/explorer/contract/verify-source-code-plugin/XLAYER \
  --api-key $OKLINK_API_KEY --watch --constructor-args $CHECKIN_CARGS \
  $CHECKIN_ADDRESS \
  dependencies/@openzeppelin-contracts-5.6.1/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy
```

## X Layer network

- Mainnet: chain id `196`, RPC `https://rpc.xlayer.tech`
- Testnet: chain id `1952`, RPC `https://testrpc.xlayer.tech/terigon`
- Mainnet explorer: `https://web3.okx.com/explorer/x-layer`
- Testnet explorer: `https://web3.okx.com/explorer/x-layer-testnet`
- OKLink verifier chain short names: `XLAYER`, `XLAYER_TESTNET`

## Deployed addresses

X Layer testnet (`chain id 1952`) deployment:

- `XPoint` implementation: `0x59C75f6D283835b0Cb62E9C4A816B4Cb1033D36c`
- `XPoint` proxy (integration address): `0x578E4ae5CeB1F5F8D12e83628B93001c14a9529C`
- `CheckIn` implementation: `0xC5aA1dCCa8c05Bee7d80e32ebd489c1BDe779057`
- `CheckIn` proxy (integration address): `0xFf7A5d7769614891953Ef1774048dEFC681Ae624`

Both `CheckIn` implementation and proxy contracts are OKLink verified.

X Layer mainnet staging (`chain id 196`) deployment:

- `XPointStaging` implementation: `0xC5aA1dCCa8c05Bee7d80e32ebd489c1BDe779057`
- `XPointStaging` proxy (integration address): `0xFf7A5d7769614891953Ef1774048dEFC681Ae624`
- `CheckInStaging` implementation: `0x0cc1432484aea6dc8E0f36febbd668234414b7fA`
- `CheckInStaging` proxy (integration address): `0x4AD62d394402d775e9053333608AA5f0696A36E8`
- ERC20 metadata: `name="XAgent Staging Point"`, `symbol="XPT-STG"`, `maxSupply=0` (uncapped), `whitelistMode=false`
- EIP-712 domain: `name="XAgentCheckInStaging"`, `version="1"`, `chainId=196`, `verifyingContract=0x4AD62d394402d775e9053333608AA5f0696A36E8`
- Owner / operator / pauser / signer: `0xc593e54A2016ea8FD71a4F62974BeC65f74C909C` (staging EOA; rotate before broader use)
- OKLink verification: `Pass - Verified` for both implementations and proxies.

X Layer mainnet production (`chain id 196`) deployment (2026-05-18):

- `XPoint` implementation: `0x5F4Fa5357261c7EC2122423596277A91b1C92ef7`
- `XPoint` proxy (integration address): `0xbd6981FD12a1AE3858337c667d4284FDB0811F58`
- `CheckIn` implementation: `0x6dFD7CFACdD922Bd9d386e6E32274a3815d00230`
- `CheckIn` proxy (integration address): `0x41311059795E81eB4b177ff049091de55FbD5bb5`
- ERC20 metadata: `name="XPoint"`, `symbol="XPoint"`, `decimals=18`, `maxSupply=0` (uncapped), `whitelistMode=false`
- EIP-712 domain: `name="XAgentCheckIn"`, `version="1"`, `chainId=196`, `verifyingContract=0x41311059795E81eB4b177ff049091de55FbD5bb5`
- Owner / DEFAULT_ADMIN / operator / pauser / signer: `0x8fef397e2B97B9a9734b20c6319515a94b1Daab3` (deployer EOA; rotate to multisig before broader use)
- `MINTER_ROLE` granted to `CheckIn` proxy: `true`
- OKLink verification: `Pass - Verified` for both implementations and proxies.

## EIP-1153 requirement

`CheckIn` uses transient storage for the reentrancy guard. X Layer runtime must support EIP-1153. If testnet smoke checks fail, replace with a non-transient guard before production deploy.

## Staging retirement checklist

Mainnet staging contracts cannot be deleted. After integration testing is complete:

1. Pause `CheckInStaging`.
2. Pause `XPointStaging`.
3. Revoke `MINTER_ROLE` from `CheckInStaging`.
4. Mark staging addresses as deprecated in this README (keep records for audit/debug traceability).
5. Do not reuse staging owner/operator/pauser or staging signer for production.
