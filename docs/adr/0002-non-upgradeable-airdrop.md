---
status: accepted
---

# Make XAgentAirdrop Non-Upgradeable

Unlike `XPoint`, `CheckIn`, and `UsageAttestation` in this repository, which use UUPS proxies, `XAgentAirdrop` is deployed as a plain non-upgradeable contract with `SAFE` and `ALLOWANCE_MODULE` fixed in `immutable` bytecode and the Fee Rate ceiling fixed as the `FEE_BPS_LIMIT` constant (`2_000` = 20%).

Why: `XAgentAirdrop` holds no user balances, and its only token custody is a bounded per-token Claim Float ([ADR 0003](./0003-claim-float-topped-up-by-allowance-module.md)) that the Treasury Safe can recall at any time with `returnToSafe`. Replacing contract logic only requires pausing the old instance, returning its float, and executing a Treasury Safe transaction to remove the old `AllowanceModule` delegate and add a new instance. Removing proxy upgradeability eliminates the upgrade authority attack surface, prevents any post-deployment redirection of the Treasury Safe address, and automatically invalidates signatures targeting the retired contract address because the EIP-712 `verifyingContract` changes.
