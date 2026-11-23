# ABI and integration reference

The exact compiler-exported ABI arrays are
[`abi/LaunchToken.json`](abi/LaunchToken.json) and
[`abi/TestStaking.json`](abi/TestStaking.json). Regenerate with
`python3 tools/export_abis.py`; validate with its `--check` option.

## LaunchToken

Constructor: `constructor()` (nonpayable). The name is `Test`, symbol `TEST`,
decimals 18 and fixed supply `10^27` minor units. The constructor mints everything
to its caller, the launch factory. There is no owner or post-construction mint.

| Method | Meaning |
| --- | --- |
| `name()`, `symbol()`, `decimals()` | Display metadata |
| `totalSupply()` | Constant lifetime supply |
| `balanceOf(address)` | TEST balance in minor units |
| `allowance(address,address)` | Remaining transferFrom allowance |
| `approve(address,uint256)` | Set a spender allowance; returns bool |
| `transfer(address,uint256)` | Send the exact amount; returns bool |
| `transferFrom(address,address,uint256)` | Send on allowance; returns bool |

Standard `Transfer` and `Approval` events and ERC-6093 errors are present.
Infinite allowances have standard OpenZeppelin semantics (not decremented);
the frontend should request exact deposit amounts. Replacing an existing allowance
has ordinary ERC-20 allowance race semantics; do not rely on `approve` to revoke a
pending transfer in a particular transaction order.

## TestStaking

Constructor: `constructor(address token_, address owner_)` (nonpayable).
Binding order is **`[$token, $owner]`**. The owner's role is rate control only.
Every mutating method is nonpayable and there is no receive/fallback function.
Token quantities and point quantities both use 18 decimals, but they are different
units: points have no redemption or token balance.

### State-changing methods

| Signature | Caller | Result |
| --- | --- | --- |
| `stake(uint256 amount)` | Any holder, with allowance/balance | Pull caller's TEST, checkpoint, add to their stake |
| `withdraw(uint256 amount)` | Staker, up to their own stake | Checkpoint, return principal to caller |
| `checkpoint() returns (uint256 points)` | Any account | Save and return caller's cumulative lifetime points |
| `setPointsPerSecond(uint256 newRate)` | Owner | Checkpoint old rate, then set future global emission |
| `transferOwnership(address newOwner)` | Owner | Begin two-step transfer, or cancel with address(0) |
| `acceptOwnership()` | Pending owner | Complete ownership transfer |
| `renounceOwnership()` | Owner | Permanently relinquish rate control and clear pending owner |

`stake` and `withdraw` require nonzero amounts. There is no deposit-on-behalf,
withdraw-to-another-address, claim, reward funding, emergency withdrawal or rescue
function. Points cannot be spent, transferred or reset.

### Reads

| Signature | Meaning |
| --- | --- |
| `token() returns (address)` | Immutable TEST contract |
| `owner()`, `pendingOwner()` | Application rate authority and pending successor |
| `stakes(address)`, `totalStaked()` | Current user and total TEST principal |
| `pointsPerSecond()` | Global point minor units emitted per nonempty second |
| `earnedPoints(address)` | Lifetime whole point minor units **saved at the last user checkpoint** |
| `pendingPoints(address)` | **Current lifetime total, already including earnedPoints**, through the current block timestamp |
| `currentTotalPointsEmitted()` | All nonempty-interval point emission including the current interval |
| `totalPointsEmitted()` | Emission saved through lastUpdateTime |
| `currentPointsPerToken()` | Current global scaled accumulator including unsaved accrual |
| `accPointsPerToken()`, `lastUpdateTime()` | Saved global accumulator and its timestamp |
| `userPointsPerTokenPaid(address)` | Accumulator used by the last user checkpoint |
| `userPointRemainder(address)` | Saved user fraction of a point minor unit, denominator ACC_PRECISION |
| `globalRemainder()` | Saved division remainder for the current stake distribution |

Public constants are `POINTS_DECIMALS() = 18`, `ACC_PRECISION() = 10^36`,
`DEFAULT_POINTS_PER_SECOND() = 10^18`, `MAX_POINTS_PER_SECOND() = 10^24`, and
`MAX_TOTAL_STAKED() = 10^27`.

Use `pendingPoints` directly as the displayed cumulative points. Do **not** add
`earnedPoints` to it. If separate saved/unsaved rows are desired, unsaved whole
minor units are `pendingPoints - earnedPoints`. Share is `stakes / totalStaked`,
or zero when totalStaked is zero. Read quantities together at one block tag to
avoid displaying inconsistent shares or a moving timestamp across calls.

### Events and errors

| Event | Meaning |
| --- | --- |
| `Staked(address indexed account,uint256 amount)` | Principal added |
| `Withdrawn(address indexed account,uint256 amount)` | Principal returned |
| `PointsCheckpointed(address indexed account,uint256 earnedPoints)` | Saved **cumulative** whole point minor units |
| `PointsRateUpdated(uint256 previousRate,uint256 newRate)` | Global emission changed; also emitted at construction |
| `OwnershipTransferStarted(address indexed previousOwner,address indexed newOwner)` | Transfer initiated/cancelled |
| `OwnershipTransferred(address indexed previousOwner,address indexed newOwner)` | Owner installed, accepted, or renounced |

Failed transactions retain neither state changes nor logs. Event consumers should
wait for receipts and handle chain reorgs. Checkpoint events occur automatically
on deposits and withdrawals as well as explicit `checkpoint()` calls.

| Error | Interpretation |
| --- | --- |
| `InvalidToken()` | Zero or self token address in constructor |
| `TokenHasNoCode()` | Deposit attempted before a real token exists at the binding |
| `ZeroAmount()` | Zero stake or withdrawal |
| `StakeLimitExceeded()` | Deposit would exceed the launch supply cap |
| `InsufficientStake(uint256 available,uint256 requested)` | Withdrawal above caller's principal |
| `UnexpectedTokenBalance()` | Incoming transfer did not increase custody by exactly amount |
| `RateTooHigh(uint256 requested,uint256 maximum)` | Requested points emission exceeds cap |
| `OwnableUnauthorizedAccount(address)` | Caller lacks the required owner/pending-owner role |
| `OwnableInvalidOwner(address)` | Constructor owner is zero |
| `ReentrancyGuardReentrantCall()` | Nested accounting mutation rejected |
| `SafeERC20FailedOperation(address)` | Token returned failure or was not a contract |

Token errors (for example insufficient allowance/balance) and token reverts are
bubbled. Arithmetic/library errors are included in the exported ABI where emitted
by the compiler. Such a failure should be displayed as a failed transaction, never
as a completed deposit/withdrawal.

## Frontend transaction flow

1. Resolve both addresses from the actual Sepolia deployment handoff and verify
   `staking.token() == tokenAddress`. Use wallet chain 11155111 and bigint minor
   units; do not use JavaScript floating point for transaction amounts.
2. Read balance, allowance, stakes, totalStaked, pendingPoints and pointsPerSecond.
   Show network, exact addresses and pool data from that same deployment.
3. For stake, validate a strictly positive decimal TEST amount with at most
   18 fractional digits and sufficient wallet balance. If allowance is too small,
   approve the exact desired amount and await a successful receipt before staking.
   Re-read balance/allowance after approval and account/network changes.
4. For withdrawal, validate amount against `stakes(account)` and call withdraw.
   No allowance is needed and points remain earned after exit.
5. Distinguish awaiting wallet signature, transaction submitted, confirmed,
   rejected, replaced/cancelled and reverted. Re-read state following a successful
   receipt. A points animation may estimate between blocks but should reconcile
   with `pendingPoints` and never promise a payout.

The actual website, live addresses, trading links and pool key are supplied in
later stages. They are not guessed in this contract artifact.
