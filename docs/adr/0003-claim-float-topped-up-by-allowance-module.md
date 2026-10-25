---
status: accepted
---

# Pay Claims From a Claim Float Topped Up by AllowanceModule

Supersedes [ADR 0001](./0001-airdrop-custody-via-allowance-delegate.md).

`XAgentAirdrop` holds a per-token Claim Float and pays every self-service Claim from it. The Treasury Safe still enables Safe's canonical `AllowanceModule` (`v1.0.0`, `0x691f59471Bfd2B7d639DCF74671a2d648ED1E331`) and registers `XAgentAirdrop` as a delegate with a per-token Period Allowance, but the delegate now only uses that allowance to refill its own float towards the token's Float Target:

- A Claim the float can cover makes no `AllowanceModule` call.
- A Claim the float cannot cover first pulls `min(floatTarget - balance, remaining Period Allowance)` into the float, then pays. If that is still not enough, it reverts with `InsufficientFloat`.
- `refill(token)` is permissionless but only runs once the float is at or below half of its Float Target.
- The Claim Fee never leaves the Treasury Safe: only Net Amounts are ever pulled.

## Why

ADR 0001 paid each Claim with one `AllowanceModule` transfer. `AllowanceModule` stores a `uint16` nonce per `(safe, delegate, token)` that starts at `1`, is never reset, and reverts at `type(uint16).max`: `65,534` transfers per delegate and token ([source](https://github.com/safe-fndn/safe-modules/blob/main/modules/allowances/contracts/AllowanceModule.sol)). Paying from a float makes nonce consumption scale with the value moved divided by the Float Target instead of with the number of Claims, and removes the `AllowanceModule` path (about 64k of the ~129k gas measured per Claim) from most Claims.

It also matches how large distributions are custodied:

- Uniswap, Arbitrum, Morpho's [Universal Rewards Distributor](https://github.com/morpho-org/universal-rewards-distributor), Merkl, EigenLayer, LayerZero, Galxe, and Layer3 all pay from tokens pre-funded into the distributor or a dedicated escrow. None pulls from a treasury allowance or through a Safe module at claim time.
- Signature-based claim platforms ([Galxe `TokenReward`](https://github.com/Galxe/galxe-contracts/blob/HEAD/contracts/TokenReward/TokenReward.sol), Layer3) fund each campaign separately, cap it, and bind nonces and expiries into signatures, as `XAgentAirdrop` does. Layer3 also takes a pro-rata fee from the reward.

## Considered Options

- **One `AllowanceModule` transfer per Claim, rotate the contract before the nonce cap (ADR 0001)**: The official use of the module, with no custom custody. At the legacy volume (about 7,000 Claims per year, peak 2,330 per month) the cap lasts several years, but every rotation changes the contract address the backend and users integrate against.
- **Payment sub-delegates**: Several small delegate contracts, each with its own nonce space. Multiplies capacity, but adds contracts, allowances, and monitoring per token.
- **Standing ERC-20 approval from the Treasury Safe**: `transferFrom(safe, recipient, amount)` with a self-written period limit. Saves about 20–25k gas per Claim, but standing approvals to spender contracts are the most common drain pattern: about a dozen incidents (Transit Swap, Socket, [LI.FI](https://li.fi/knowledge-hub/incident-report-16th-july), Seneca, SwapNet) each lost up to the approved amount, and only users with bounded approvals were unaffected. The period limit would live in our own code.
- **Zodiac Roles**: Audited per-call and periodic limits, but v2.1.0 (`0x9646fDAD06d3e24444381f44362a3B0eB343D337`) was exploited on 2026-06-01 through an ERC-1271 bypass ([post-mortem](https://engineering.gnosisguild.org/posts/zodiac-post-mortem)) and is marked "Do not use"; only v2.1.1 (`0xF2964CE6161ce0e75964Fe7927cE114cb0B283D5`) is acceptable ([security](https://docs.zodiac.eco/developers/security)). Its permission DSL is heavy for single-token payouts and every permission change needs its own review.
- **Fully funded distributor**: Industry baseline and the simplest code, but the whole allocation sits in custom contract storage with no velocity cap enforced by an audited Safe component.
- **Claim Float topped up by `AllowanceModule` (chosen)**: Keeps the audited Period Allowance as the outer velocity cap while holding only a bounded working balance in the contract.

## Consequences

- **Worst-case loss per period** (Signer compromise or a bug in `XAgentAirdrop`) is one Period Allowance plus one Float Target per configured token, until `pause()`. Size the Float Target as a small multiple of the Per-Claim Cap, not as a reserve.
- `configureToken` enforces `maxClaimAmount <= floatTarget <= type(uint96).max` so one refill always covers any single Claim and fits an `AllowanceModule` transfer. A disabled token (cap `0`) must have Float Target `0`.
- Refills consume nonces only when the float has dropped by at least half its target, or when a Claim cannot otherwise be paid. A refill that pulls only the tail of an exhausted Period Allowance can add at most one small transfer per period.
- If the Treasury Safe balance is below what a refill asks for, the module transfer reverts and so does the Claim, consuming no nonce. Operators must either top up the Safe or lower the Float Target to the remaining balance.
- The contract now holds tokens. `returnToSafe` sends any ERC-20 back to the Treasury Safe: the Safe may call it at any time, the Guardian only while paused. There is no other outbound path besides Claims.
- Safe{Wallet}'s spending-limit UI only recognizes `AllowanceModule` v0.1.x, so allowances, nonces, and float balances must be monitored off-chain. Do not enable v0.1.x from the UI.
- The nonce cap still exists. Before `getTokenAllowance(safe, airdrop, token)[4]` approaches it, rotate to a new instance as described in the runbook.
