---
status: superseded by ADR 0003
---

> Superseded by [ADR 0003](./0003-claim-float-topped-up-by-allowance-module.md): Claims are now paid from a Claim Float that `AllowanceModule` tops up, instead of one `AllowanceModule` transfer per Claim.

# Custody Airdrop Funds in a Safe via AllowanceModule Delegate

Distributable ERC-20 tokens stay in the Treasury Safe. `XAgentAirdrop` is not installed as a Safe module and does not hold token balances; instead, the Treasury Safe enables Safe's canonical `AllowanceModule` (`v1.0.0`, `0x691f59471Bfd2B7d639DCF74671a2d648ED1E331`) and registers `XAgentAirdrop` as a delegate with a per-token Period Allowance.

## Considered Options

- **AllowanceModule delegate (`XAgentAirdrop`)**: Self-written code only verifies EIP-712 signatures, enforces Per-Claim Caps, marks Claim IDs, and asks `AllowanceModule` to transfer the Net Amount. Even a total compromise of the Signer or a bug in `XAgentAirdrop` cannot move more than the current Period Allowance for configured tokens, and cannot touch other assets or owners of the Treasury Safe.
- **Custom Safe module (`ShortClaim` style)**: A custom module calls `execTransactionFromModule` directly on the Safe. Any bug in the module exposes every asset and owner setting of the Safe, requiring a full external audit before mainnet use.
- **Contract holds working capital**: Simplest code, but the entire working balance sits in custom contract storage without an on-chain velocity cap enforced by an audited Safe component.
- **Zodiac Roles v2**: Enforces both per-call and periodic limits in audited contracts, but introduces a separate permission DSL and operational toolchain that is heavier than needed for single-method ERC-20 payouts.

## Consequences

- `AllowanceModule` stores a `uint16` transfer nonce per `(safe, delegate, token)` tuple and reverts after `65,534` transfers. Because `XAgentAirdrop` retains the Claim Fee inside the Treasury Safe instead of making a second transfer to the Fee Safe on every Claim, each Claim consumes exactly one `AllowanceModule` transfer.
- Before a token's transfer count approaches `65,534`, operators deploy a new `XAgentAirdrop` instance and rotate the `AllowanceModule` delegate from the old instance to the new one via a Treasury Safe transaction.
- Claims above the Per-Claim Cap are rejected on the self-service path and fulfilled by a Treasury Safe `MultiSendCallOnly` batch that pairs `IERC20.transfer` with `XAgentAirdrop.settleManualClaim`.
