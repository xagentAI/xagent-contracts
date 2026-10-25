# XAgent Airdrop

Token distribution context where off-chain signed authorizations let eligible accounts collect ERC-20 tokens held in a multi-signature treasury.

## Language

**Claim**:
A single authorized collection of an ERC-20 token, funded by the Treasury Safe, by a Claimant.
_Avoid_: Withdrawal, transfer, redeem, payout

**Claim ID**:
A unique numeric identifier assigned to one Claim so it can be collected at most once.
_Avoid_: transId, transaction ID, order ID, nonce

**Claimant**:
The account authorized to submit a Claim and choose where the Net Amount is sent.
_Avoid_: tokenOwner, user, sender, caller

**Recipient**:
The destination address that receives the Net Amount of a Claim.
_Avoid_: toWallet, toAddress, receiver

**Gross Amount**:
The total token quantity authorized for a Claim before deducting the Claim Fee.
_Avoid_: tokenAmount, applyAmount

**Claim Fee**:
The portion of the Gross Amount retained in the Treasury Safe to cover distribution costs.
_Avoid_: withdrawalFee, service fee, tax

**Fee Rate**:
The per-token share of the Gross Amount, in basis points and at most 20%, that a self-service Claim's Claim Fee must equal exactly and that a Manual Settlement's Claim Fee may not exceed.
_Avoid_: maxFeeBps, fee cap, fee percentage

**Net Amount**:
The token quantity transferred to the Recipient (`Gross Amount` minus `Claim Fee`).
_Avoid_: amountAfterFee, actualAmount

**Signer**:
The off-chain authority whose signature makes a Claim valid within the current Epoch.
_Avoid_: manager, operator, relayer

**Epoch**:
A monotonically increasing generation number bound into every Claim signature; advancing it invalidates all uncollected signatures from earlier generations at once.
_Avoid_: saltCode, code, version

**Treasury Safe**:
The multi-signature wallet that holds distributable tokens, funds the Claim Float, retains Claim Fees, and exercises administrative control over the airdrop contract.
_Avoid_: vault, admin wallet, manager account, funds Safe

**Fee Safe**:
The separate multi-signature wallet that periodically receives accumulated Claim Fees swept from the Treasury Safe.
_Avoid_: revFeeWallet, fee wallet

**Guardian**:
A dedicated emergency role permitted only to pause Claims, advance the Epoch, and, while paused, return the Claim Float to the Treasury Safe; it cannot unpause, send funds anywhere else, or change configuration.
_Avoid_: emergency admin, pauser, security manager

**Period Allowance**:
The maximum cumulative amount of a given token that the airdrop contract may pull from the Treasury Safe into its Claim Float within one recurring time window.
_Avoid_: daily limit, budget, quota

**Claim Float**:
The working balance of a given token held by the airdrop contract, from which self-service Claims are paid and which is refilled from the Treasury Safe within the Period Allowance.
_Avoid_: pool, buffer, hot wallet, reserve

**Float Target**:
The per-token balance a refill tops the Claim Float back up to; it must cover at least one Per-Claim Cap, and zero means the token has no Claim Float.
_Avoid_: float size, refill amount, max balance

**Per-Claim Cap**:
The maximum Gross Amount permitted for a single self-service Claim of a given token; setting it to zero disables self-service Claims for that token.
_Avoid_: threshold, single-tx limit, max withdrawal

**Manual Settlement**:
Fulfillment of a Claim that exceeds the Per-Claim Cap via a direct Treasury Safe multi-signature transaction that atomically transfers the Net Amount and marks the Claim ID as collected.
_Avoid_: large claim queue, admin payout, manual withdrawal
