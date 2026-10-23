# XAgentAirdrop — Backend Integration & Operations Runbook

`XAgentAirdrop` ([`src/XAgentAirdrop.sol`](../src/XAgentAirdrop.sol)) is the non-upgradeable EIP-712 claim gate for the XAGT TGE airdrop on Ethereum mainnet. The backend that issues signatures is `xerpaai-go` (package `src/internal/xagtairdrop`, operator CLI `src/cmd/xagt-airdrop`); its launch runbook is `xerpaai-go/.scratch/xagt-tge-airdrop/runbook.md`. Self-service Claims are paid from a per-token Claim Float held by the contract; the float is topped up from a Safe v1.5.0 Treasury Safe through Safe's canonical `AllowanceModule` v1.0.0 (`0x691f59471Bfd2B7d639DCF74671a2d648ED1E331`), which caps how much can be pulled per Period Allowance.

Canonical domain terms are defined in [`GLOSSARY.md`](../GLOSSARY.md); architectural trade-offs are recorded in [`docs/adr/0003-claim-float-topped-up-by-allowance-module.md`](./adr/0003-claim-float-topped-up-by-allowance-module.md) (which supersedes [ADR 0001](./adr/0001-airdrop-custody-via-allowance-delegate.md)) and [`docs/adr/0002-non-upgradeable-airdrop.md`](./adr/0002-non-upgradeable-airdrop.md).

---

## Part 1 — Backend Integration Specification (`xerpaai-go`)

### 1.1 EIP-712 Domain & Typed Struct

Domain fields:

| Field | Value |
|---|---|
| `name` | `"XAgentAirdrop"` |
| `version` | `"1"` |
| `chainId` | Target chain ID (`1` on Ethereum mainnet) |
| `verifyingContract` | Deployed `XAgentAirdrop` address |

Typed struct (`CLAIM_TYPEHASH`):

```text
Claim(address claimant,address token,uint256 amount,uint256 fee,uint256 claimId,uint256 epoch,uint256 deadline)
```

Field mapping from `xerpaai-go` (`ClaimMessage` in `eip712.go`):

| Struct field | Solidity type | Source in `xerpaai-go` |
|---|---|---|
| `claimant` | `address` | Wallet the user locks for the round (`msg.sender` of `claim`) |
| `token` | `address` | XAGT token address from the round row |
| `amount` | `uint256` | Gross Amount in token wei (the user's allocation) |
| `fee` | `uint256` | Claim Fee in token wei, `SplitFee(gross, round.fee_bps)` = `floor(amount * fee_bps / 10_000)`. Must equal `amount * feeBps[token] / 10_000` (rounded down) at execution time, so the round `fee_bps` must equal the on-chain `feeBps(token)` |
| `claimId` | `uint256` | `round_no << 64 \| claim_seq` |
| `epoch` | `uint256` | Current `airdrop.epoch()` value (starts at `0`) |
| `deadline` | `uint256` | Unix timestamp in seconds: `now + signatureTtlSeconds` (default 30 minutes), capped at the round's `claim_end_at` |

Note on `recipient`: `recipient` is **not** part of the EIP-712 struct. The signature binds `claimant` (`msg.sender`), and `claimant` chooses `recipient` when submitting the transaction. The XAGT frontend always passes `recipient = claimant`; the backend reconciles against the `recipient` in the `Claimed` event.

For off-chain verification or test tooling, `airdrop.hashClaim(claimant, token, amount, fee, claimId, deadline)` computes the exact EIP-712 digest for the contract's current `epoch`.

### 1.2 Contract Entry Points & Views

```solidity
function claim(
    address token,
    uint256 amount,
    uint256 fee,
    uint256 claimId,
    uint256 deadline,
    address payable recipient,
    bytes calldata signature
) external;

function isClaimed(uint256 claimId) external view returns (bool);

function quoteFee(address token, uint256 amount) external view returns (uint256 fee, uint256 netAmount);

function hashClaim(
    address claimant,
    address token,
    uint256 amount,
    uint256 fee,
    uint256 claimId,
    uint256 deadline
) external view returns (bytes32);

function epoch() external view returns (uint256);
function maxClaimAmount(address token) external view returns (uint256); // Per-Claim Cap; 0 = disabled
function feeBps(address token) external view returns (uint256);         // Fee Rate, at most FEE_BPS_LIMIT = 2000
function floatTarget(address token) external view returns (uint256);    // Float Target

function refill(address token) external returns (uint256 pulled);      // permissionless, see Section 2.2
```

### 1.3 Call Flows in `xerpaai-go`

Routes are defined in `src/api/xagent-airdrop.api` under `/user/xagent/airdrop`; the UID always comes from the JWT.

1. **Chain state**: one Multicall3 `aggregate3` call (`Chain.GlobalState` in `chain.go`) reads `epoch`, `signer`, `paused`, `maxClaimAmount(token)`, `feeBps(token)`, `floatTarget(token)`, `SAFE`, the float balance `balanceOf(airdrop)`, the Safe balance, `getTokenAllowance(safe, airdrop, token)`, and the block timestamp. Redis caches it for 15 seconds, shared by all instances.
2. **Self-service signature (`POST /claim/prepare`)**, before calling KMS (`service.go`):
   - Not paused; configured signer = `signer()`; configured Safe = `SAFE()`; Gross ≤ `maxClaimAmount(token)`; round `fee_bps` = `feeBps(token)`; `floatTarget(token)` > 0.
   - Funding mirrors `claim` (`GlobalState.ClaimCapacity`): if the float covers Net, nothing is pulled. Otherwise the Claim first pulls `min(floatTarget − float, remaining Period Allowance)` from the Safe. The backend refuses with "allowance exhausted" (plus minutes to the next reset) when float + pull < Net, and with "unavailable" when the Safe holds less than the pull.
   - A stored signature is handed out again only while `epoch`, `paused` and the on-chain fee rate are unchanged.
   - The response carries `(chainId, contract, token, claimant, recipient, gross, fee, net, claimId, epoch, deadline, signature)`; the user's wallet calls `claim(token, amount, fee, claimId, deadline, recipient, signature)`. Gas varies: a Claim the float covers is cheaper than one that refills the float first, so wallets must estimate.
3. **Confirmation (`POST /claim/report` + scanner)**: the scanner reads `Claimed` / `ManualClaimSettled` logs from the airdrop address (`topics[1] == bytes32(claimId)`) and moves rows to `CLAIMED` / `PAID`. The same receipt may also contain `FloatRefilled` and `AllowanceModule` / Safe events; ignore them.
4. **Claims above the large-claim threshold** (≤ `maxClaimAmount[token]`): imported as `claim_mode = MANUAL`, never self-signed. The user proves wallet ownership via `POST /manual/challenge` → `POST /manual/submit` (SIWE); operations settle through Section 2.5.
5. **Import (`xagt-airdrop import`)**: refuses a manifest whose `feeBps` differs from `feeBps(token)`, whose large-claim threshold exceeds `maxClaimAmount(token)`, or when `floatTarget(token)` is 0.
6. **Monitor (every 5 minutes)**: alerts on signer mismatch, paused-while-open, round `fee_bps` ≠ `feeBps(token)`, remaining Period Allowance below the configured percentage, nonce approaching the limit, and Safe + float balance below the unclaimed Net total.
7. **Fee Rate changes**: a `configureToken` fee change invalidates every outstanding signature (`FeeMismatch`) and makes the backend refuse to sign until the round `fee_bps` matches again. A round's `fee_bps` is fixed at import, so do not change the on-chain Fee Rate while a round is open.
8. **Temporarily unpayable Claims**:
   - `InsufficientFloat` means the float plus what is left of this period's allowance cannot cover the Net Amount. The signature stays valid until its `deadline`; the user retries after the next allowance reset.
   - `Could not execute token transfer` (raised by `AllowanceModule`) means the Treasury Safe itself holds less than the refill asks for. Alert operations (Section 2.2, tail end).

### 1.4 Custom Errors

| Error | Cause |
|---|---|
| `ZeroAddress()` | `token`, `recipient`, `claimant`, `safe`, `allowanceModule`, or `signer` is `address(0)` |
| `ZeroAmount()` | `amount == 0` |
| `ClaimExpired(uint256 deadline, uint256 timestamp)` | `block.timestamp > deadline` |
| `TokenNotEnabled(address token)` | `maxClaimAmount[token] == 0` (for `refill`: `floatTarget[token] == 0`) |
| `ExceedsMaxClaimAmount(uint256 amount, uint256 maxClaimAmount)` | `amount > maxClaimAmount[token]` (must use Manual Settlement) |
| `FeeMismatch(uint256 fee, uint256 expectedFee)` | Signed `fee` differs from `quoteFee(token, amount)`; re-sign with the current Fee Rate |
| `FeeExceedsMax(uint256 fee, uint256 maxAllowedFee)` | Manual Settlement only: `fee > quoteFee(token, amount)` |
| `ZeroNetAmount()` | `amount - fee == 0` (defensive; unreachable while the Fee Rate is at most 20%) |
| `AlreadyClaimed(uint256 claimId)` | `claimId` was already collected via `claim` or `settleManualClaim` |
| `InvalidSignature()` | Signer mismatch, wrong `msg.sender`, wrong `chainId`/`verifyingContract`, or stale `epoch` |
| `InsufficientFloat(uint256 needed, uint256 available)` | Float plus remaining Period Allowance cannot cover the Net Amount |
| `FloatAboveRefillThreshold(uint256 balance, uint256 threshold)` | `refill` called while the float is above half its Float Target |
| `NothingToRefill()` | `refill` found nothing to pull (float at target, or Period Allowance used up) |
| `EnforcedPause()` | Contract is paused by `SAFE` or `guardian` |

### 1.5 Events

| Event | Emitted by |
|---|---|
| `Claimed(claimId, claimant, recipient, token, grossAmount, fee, netAmount)` | `claim` |
| `ManualClaimSettled(claimId, claimant, recipient, token, grossAmount, fee, netAmount)` | `settleManualClaim` |
| `FloatRefilled(token, amount, newBalance, triggeredBy)` | `refill`, or `claim` when it refills first |
| `FloatReturned(token, amount, triggeredBy)` | `returnToSafe` |
| `TokenConfigured(token, maxClaimAmount, feeBps, floatTarget)` | `configureToken` |
| `SignerUpdated`, `GuardianUpdated`, `EpochAdvanced`, `Paused`, `Unpaused`, `ETHRescued` | Admin and emergency functions |

---

## Part 2 — Operations Runbook

### 2.1 Initial Deployment & Treasury Safe Setup

1. **Create the Treasury Safe (Safe v1.5.0)**:
   - Deploy a new Safe v1.5.0 on Ethereum mainnet with at least a `2-of-3` threshold using hardware wallets that never touch the payout servers.
   - Decide where Claim Fees are swept (Section 2.4); it can be a separate Fee Safe.
2. **Deploy `XAgentAirdrop`**:
   ```bash
   forge script script/DeployXAgentAirdrop.s.sol:DeployXAgentAirdrop \
     --rpc-url mainnet --broadcast --verify
   ```
   This deploys `XAgentAirdrop` and writes `broadcast/xagent-airdrop-safe-setup.json`. With `XAGENT_AIRDROP_TOKEN` set, the script also needs `XAGENT_AIRDROP_PERIOD_ALLOWANCE`, `XAGENT_AIRDROP_MAX_CLAIM_AMOUNT`, and `XAGENT_AIRDROP_FLOAT_TARGET`; `XAGENT_AIRDROP_FEE_BPS` defaults to `100` (1%) and must match the round `fee_bps` in `xerpaai-go`. For XAGT the allowance and token configuration are usually set after the allocation import, because the Period Allowance is sized from the self-service total; deploy without `XAGENT_AIRDROP_TOKEN` and add the token calls later.
   - **Target chain requirement**: the contract is compiled for the `cancun` EVM target and `ReentrancyGuardTransient` relies on transient storage (`TSTORE`/`TLOAD`, EIP-1153); the bytecode also uses `PUSH0` and `MCOPY`. Before deploying to any chain other than Ethereum mainnet, confirm it supports the Cancun opcodes. Otherwise deployment fails, or every `nonReentrant` call (`claim`, `refill`, `returnToSafe`, `settleManualClaim`) reverts.
3. **Execute the Safe setup batch**:
   - Open the Treasury Safe in Safe{Wallet} → Apps → Transaction Builder, upload `broadcast/xagent-airdrop-safe-setup.json`, review the four calls (`enableModule`, `addDelegate`, `setAllowance`, `configureToken`), collect owner signatures, and execute.
   - XAGT uses a 60-minute Period Allowance: set `XAGENT_AIRDROP_RESET_TIME_MIN=60` (the script default is `1440`) and `XAGENT_AIRDROP_RESET_BASE_MIN` to `uint32((block.timestamp / 3600) * 60)` so periods reset on the hour.
   - Safe{Wallet}'s spending-limit page only recognizes `AllowanceModule` v0.1.x, so it will not show this v1.0.0 allowance. Do not enable v0.1.x from the UI; monitor with `getTokenAllowance` instead (Section 2.2).
4. **Seed the Claim Float**: call `airdrop.refill(token)` from any account (for example `cast send <airdrop> "refill(address)" <token>`). Otherwise the first Claim seeds it and pays the extra gas.

### 2.2 Operating the Claim Float

- **Sizing**:
  - Worst-case loss per period, if the Signer is compromised or the contract has a bug, is one Period Allowance plus one Float Target per token, until someone pauses. Size both with that in mind.
  - Set the Float Target to at least twice the Per-Claim Cap, so every refill moves at least half the target. `AllowanceModule` transfers (and its nonce) then grow with the value distributed divided by half the Float Target, not with the number of Claims. `configureToken` only enforces `maxClaimAmount <= floatTarget <= type(uint96).max`.
  - The Period Allowance must cover the expected payout per period, including the initial seeding. The XAGT launch plan is 10% of the self-service total per hour for the first 48 hours, then 2% per hour.
- **Refills**:
  - Claims refill the float themselves whenever it cannot cover them. To keep that extra gas off user transactions, run an optional keeper that calls `refill(token)` whenever `balanceOf(airdrop) <= floatTarget / 2`.
  - `refill` is permissionless and safe to retry: it reverts with `FloatAboveRefillThreshold` above the threshold and `NothingToRefill` when the Period Allowance is used up.
- **Monitoring** (alert on each):
  - Float balance `IERC20(token).balanceOf(airdrop)` versus `floatTarget(token)`.
  - Remaining allowance `amount - spent` from `AllowanceModule.getTokenAllowance(safe, airdrop, token)`; `[0]` = amount, `[1]` = spent, `[4]` = nonce. `spent` may exceed `amount` after the Safe lowers an allowance mid-period.
  - Nonce `[4]` approaching `60,000` (Section 2.7).
  - Treasury Safe token balance below `floatTarget(token)`: the next refill will fail.
  - `FloatRefilled`, `FloatReturned`, and `TokenConfigured` events, and `paused()`.
- **Tail end** (Treasury Safe balance below the Float Target): a refill asks for the full gap and reverts if the Safe holds less. Either top up the Safe, or lower the Float Target (and, if needed, the Per-Claim Cap) with `configureToken` to at most the remaining balance, or pay the remaining Claims by Manual Settlement.
- **Recalling the float**: `returnToSafe(token, amount)` from the Treasury Safe returns float or any mistakenly sent ERC-20. Tokens can only go back to the Safe.

### 2.3 Changing the Fee Rate or Token Configuration

All per-token settings change in one Treasury Safe call: `configureToken(token, maxClaimAmount, feeBps, floatTarget)`.

- `feeBps <= FEE_BPS_LIMIT` (`2000` = 20%). The limit is a constant and cannot be raised without redeploying.
- `maxClaimAmount = 0` disables self-service Claims and requires `floatTarget = 0`; then call `returnToSafe` for the remaining float. The Fee Rate still caps Manual Settlement fees.
- A Fee Rate change takes effect immediately and invalidates every outstanding signature that carries the old fee (`FeeMismatch`). `xerpaai-go` then stops signing for the round until its `fee_bps` matches again (Section 1.3), so change the Fee Rate only between rounds.

### 2.4 Sweeping Accumulated Claim Fees

Only Net Amounts are ever pulled into the float, so every Claim Fee stays inside the Treasury Safe. Periodically:

1. Sum `fee` from emitted `Claimed` and `ManualClaimSettled` events over the accounting period.
2. Propose a standard Treasury Safe ERC-20 `transfer` of that sum to the fee destination, leaving enough balance for upcoming refills and unpaid Manual Settlements.

### 2.5 Manual Settlement for Large Claims

For XAGT, `MANUAL` allocations are settled with the `xerpaai-go` CLI: `xagt-airdrop manual approve` → `manual export` (Transaction Builder JSON of up to 20 Claims plus a review sheet) → Safe owners execute → `manual reconcile --tx`. The exported batch has the same shape as below. For a one-off Claim outside that flow (or above `maxClaimAmount[token]`):

1. Generate the atomic two-step batch (the script checks `fee <= quoteFee(token, grossAmount)`; the fee may be waived):
   ```bash
   XAGENT_AIRDROP_ADDRESS=0x... \
   MANUAL_CLAIM_ID=123456 \
   MANUAL_CLAIMANT=0x... \
   MANUAL_RECIPIENT=0x... \
   MANUAL_TOKEN=<XAGT token> \
   MANUAL_GROSS_AMOUNT=50000000000000000000000 \
   MANUAL_FEE=500000000000000000000 \
   forge script script/ManualClaimBatch.s.sol:ManualClaimBatch --rpc-url mainnet
   ```
2. Import `broadcast/xagent-airdrop-manual-claim.json` into Safe{Wallet} Transaction Builder on the Treasury Safe.
3. The batch executes `IERC20(token).transfer(recipient, netAmount)` from the Treasury Safe (not from the float) and `XAgentAirdrop.settleManualClaim(...)` atomically via `MultiSendCallOnly`. If `claimId` was already collected, `settleManualClaim` reverts with `AlreadyClaimed` and rolls back the token transfer.

### 2.6 Incident Response (Guardian & Treasury Safe)

- **Immediate containment (Guardian or Treasury Safe)**, in this order:
  1. `airdrop.pause()` stops all self-service `claim` and `refill` calls.
  2. `airdrop.advanceEpoch()` invalidates every uncollected signature issued under the old `epoch` without rotating the KMS key.
  3. `airdrop.returnToSafe(token, balanceOf(airdrop))` for each token moves the float back to the Treasury Safe. The Guardian can only do this while paused.
- **Cutting off refills (Treasury Safe only)**: `AllowanceModule.deleteAllowance(airdrop, token)` or `removeDelegate(airdrop, true)` if the contract itself is suspect.
- **Key rotation & recovery (Treasury Safe only)**:
  - If the Signer was compromised, call `airdrop.setSigner(newSigner)` from the Treasury Safe, re-seed the float with `refill`, then `airdrop.unpause()`.

### 2.7 Rotating Before the 65,534-Transfer `AllowanceModule` Nonce Limit

`AllowanceModule` stores a `uint16` nonce per `(safe, delegate, token)` and reverts once `nonce == 65,535` (`65,534` transfers). With the Claim Float, only refills consume it (Section 2.2, sizing). Monitor `AllowanceModule.getTokenAllowance(safe, airdrop, token)[4]`. Before it approaches `60,000`:

1. Deploy a fresh `XAgentAirdrop` instance.
2. Execute a Treasury Safe batch that calls `oldAirdrop.pause()`, `oldAirdrop.returnToSafe(token, balance)` for each token, `AllowanceModule.removeDelegate(oldAirdrop, true)`, and then the new instance's `broadcast/xagent-airdrop-safe-setup.json` calls.
3. In `xerpaai-go`, a round is bound to one contract address (`xagt_airdrop_round.contract_address`), so new Claims go through a new round imported against the new instance. Claims of rounds on the old instance stay on it; the `claimId` bitmap is per instance.

### 2.8 Sepolia Test Environment (deployed 2026-10-23)

Ethereum Sepolia (`chainId 11155111`) only. Arbitrum Sepolia has no canonical `AllowanceModule` deployment. `XAgentAirdrop` (solc `0.8.38`) is verified on Etherscan and Sourcify (`exact_match`); the Treasury Safe is linked on Etherscan as a proxy of the SafeL2 v1.5.0 singleton (`0xEdd160fEBBD92E350D4D398fb636302fccd67C7e`). `XAgentTestToken` was compiled with solc `0.8.37`; the [SOL-2026-7](https://blog.soliditylang.org/2026/10/22/yul-optimizer-knowledge-base-stale-bookkeeping-bug/) fix leaves its bytecode unchanged, so Etherscan's compiler-bug notice for it does not reflect a miscompilation.

| Item | Address |
| --- | --- |
| `XAgentAirdrop` | [`0xdAaEb5317C8e6f08Dc30030bD61ED1f60e23bf29`](https://sepolia.etherscan.io/address/0xdAaEb5317C8e6f08Dc30030bD61ED1f60e23bf29) |
| Treasury Safe "XAgent Sepolia Safe" (SafeL2 v1.5.0, 1-of-2) | [`0x80d1Bfafc1E0f25D40f46AD0014558E87ea88406`](https://app.safe.global/home?safe=sep:0x80d1Bfafc1E0f25D40f46AD0014558E87ea88406) |
| Safe owners | `0xb2a743BD6B52fdDf52B07539241Aaa6F343CB039`, `0xa3F34aC3aE960cd7F4781d0029Fd643A89Da4Bd1` |
| Test token `tXAGENT` (`XAgentTestToken` "XAgent Test Token", 18 decimals) | [`0xe2D6b2366733CcA24355e91e0679F0988D410f52`](https://sepolia.etherscan.io/address/0xe2D6b2366733CcA24355e91e0679F0988D410f52) |
| `AllowanceModule` v1.0.0 | `0x691f59471Bfd2B7d639DCF74671a2d648ED1E331` |
| Guardian / deployer | `0xb2a743BD6B52fdDf52B07539241Aaa6F343CB039` |
| Signer (`xerpaai-go` test KMS key `xagt-airdrop-sepolia-signer`) | `0x5f82e75C7F3D17FA0982D22BEEecA0529f310801` |
| Former signer for the smoke Claims (throwaway test key; never reuse on mainnet) | `0x863b7c0cDbfbf76220720A19373701139A7114e9` |

Configuration for `tXAGENT`: Fee Rate `100` bps (1%), Per-Claim Cap `5,000`, Float Target `10,000`, Period Allowance `20,000` per `60` minutes. The Treasury Safe was funded with `1,000,000 tXAGENT`. The `xerpaai-go` test config (`src/internal/sql/xagt_airdrop_config_test.sql`) points at this Safe; test rounds must use this contract and `fee_bps = 100`.

| Step | Transaction | Result |
| --- | --- | --- |
| Deploy | [`0x2cf1…7ae5`](https://sepolia.etherscan.io/tx/0x2cf1241e9386d1d6eac90d9a377511421ec1ef5c1819ba51ccaebf610c8e7ae5) | |
| Mint 1,000,000 tXAGENT to the Safe | [`0x36b1…725a`](https://sepolia.etherscan.io/tx/0x36b1be0defe9d4623672650f4a037e6d0c8df9d10337a9afa2fca6e73513725a) | |
| Safe batch `enableModule` + `addDelegate` + `setAllowance` + `configureToken` | [`0x4d81…aa04`](https://sepolia.etherscan.io/tx/0x4d81605f0d6952a989698b67b18a61699695a903de380b64d9c4947818a1aa04) | |
| `refill` (seed the float) | [`0x8a36…6c2f`](https://sepolia.etherscan.io/tx/0x8a364ace66906a465e4d49fac1b666b423fdc4ca24f50e8571c74ed5d8506c2f) | Float 10,000; nonce 1 → 2; 203,779 gas |
| Claim `1001` (1,000) | [`0x9b99…ac6a`](https://sepolia.etherscan.io/tx/0x9b990cde3db8c0ab249e68712dbc0084aac8d67e722106bfd0b42872e2abac6a) | Paid from float; 177,234 gas (first Claim, cold storage) |
| Claim `1002` (5,000) | [`0x90f4…8258`](https://sepolia.etherscan.io/tx/0x90f4db899a4b40bfd01dc7df11fc4b5b332dc7a027487eb8bdeae5c8293e8258) | Paid from float; 79,326 gas |
| Claim `1003` (5,000) | [`0xc222…fbdb8`](https://sepolia.etherscan.io/tx/0xc222f9c58fc4c14a0cc1790b75d418d2732f4c661fdc4a5dcb0b65824b1fbdb8) | Automatic refill of 5,940; nonce 2 → 3; 150,609 gas |
| Safe batch `setSigner(KMS)` + `setAllowance(…, 20,000, 60, 0)` | [`0x820d…d3d1`](https://sepolia.etherscan.io/tx/0x820ded61d611c276045afd16d56677b3a0e9c3aab5734d0750f8f8c345bdd3d1) | Signer → `0x5f82…0801`; 60-minute period |

- Anyone can top up test balances with `tXAGENT.mint(to, amount)` (at most `1e9` tokens per call). The token constructor refuses non-test chains.
- Claim IDs `1001`–`1003` are used by the smoke Claims; do not reuse them in backend tests. A Claim signed with fee `9` for `1,000` reverts with `FeeMismatch(9e18, 10e18)`.
- Superseded and paused; do not integrate against them:
  - `XAgentAirdrop` `0xC06f2e4757c3298BDFd929d25773D3c9Dd62F216` (solc `0.8.37`, `MAX_FEE_BPS`, per-Claim `AllowanceModule` transfers, Safe `0x6278A2f06cD05f8E10d72FCb40fe56B6AFFc9722`; the earlier `xerpaai-go` test target), paused in [`0x4983…5829`](https://sepolia.etherscan.io/tx/0x4983a07bb4677888ad8f81226412d7649b81413770c30394d8efd18965db5829).
  - `XAgentAirdrop` `0x5256094641e7A7B5380E6B2406b404B85b344080` (Safe `0x532C…0a5D`, token `tUXLINK` `0x01f9…8111`), paused in [`0x88b6…e7b6`](https://sepolia.etherscan.io/tx/0x88b60d6df5ff0a65e88bd5896ac4a834c870be761659dd96829ab62eaaaae7b6).
