# Review handoff and trust boundaries

This is the implementation author's local adversarial review record, not an
independent security audit. The separate reviewer must assess the accepted source
and completed manifest before deployment. No independent review, Slither run,
Mythril run, deployment or on-chain verification is claimed here.

## Scope and assumptions

Production consists of `src/LaunchToken.sol` and `src/TestStaking.sol` with their
vendored OpenZeppelin dependencies. LaunchToken has a fixed 10^27 supply and no
administrator. TestStaking must bind that token and the supplied `$owner`; token
behavior beyond this fixed ERC-20 is outside the design. Token construction mints
to the factory by policy, but application ownership never derives from the factory
or `tx.origin`. Constructors are nonpayable and call no outside contracts.

The owner's configurable points policy is intentional. It can stop future points
or raise emission to the documented cap without a timelock, but it has no custody,
upgrade, principal confiscation or withdrawal pause power. Points are an internal
record, with no redemption promise or future reward allocation. Direct token
donations and other mistakenly sent assets cannot be recovered.

## Local adversarial checks

| Area | Design and evidence |
| --- | --- |
| Reentrancy | OpenZeppelin guard on all four accounting mutations. Hostile token callbacks target stake, withdraw, checkpoint and even owner-authorized rate changes on both incoming and outgoing transfers. All nested calls fail. |
| Token transfer safety | SafeERC20 checks failures and bubbles reverts. Incoming balance delta must equal the credited principal. Tests cover false/no return, revert, true without movement, transfer fee and later retry. |
| Checks/effects/interactions | User and global checkpoints and principal changes precede the mutating token call. Failure restores principal and checkpoint state atomically. |
| Unauthorized principal movement | Transfers into staking can pull only msg.sender; withdrawals return only msg.sender's recorded stake. Tests include stranger withdrawal, over-withdrawal and duplicate full withdrawal. |
| Rate boundary | Old global accrual is saved before any new rate; empty intervals advance the timestamp without points. Zero and maximum rates, authorization and an excessive rate are tested. |
| Rounding manipulation | Global fractions carry across checkpoints/rate changes, user fractions survive exits, and distribution changes discard only bounded old dust. Checkpoint spam cannot erase users' fractions or give new entrants past emission. |
| Donation attacks | Shares use recorded stake, never token balance or a share-token price. Direct donation changes neither points nor principal claims. |
| Point conservation | Random sequences are compared to an independent high-precision interval model with upper/lower rounding bounds. Sum of point totals never exceeds eligible global emission. |
| Principal conservation | Stateful tests verify per-user initial balance equals wallet plus stake, custody equals totalStaked plus donations, and every actor can fully exit at each campaign's end. |
| Factory constraints | Local factory-like deployment creates both contracts in one call and verifies supply stays with it, token reference is correct and owner is separate. Runtime-size and forbidden-opcode checks cover both artifacts. |
| Arithmetic | Full-precision mulDiv/mulmod with named precision, rate and stake bounds; both tiny stake and full supply are tested. No unchecked project arithmetic or value-bearing randomness. |

No material defect remained identified in these local checks. This does not replace
an independent attempt to break the system.

## Build lint observations

Foundry's build lint reports `incorrect-strict-equality` on the deposit balance
delta check. The equality is intentional: only exact incoming TEST is credited;
unrelated donations before a transaction do not affect its measured delta.
The fixed LaunchToken has no transfer callback and cannot rebase.

It also reports `reentrancy-events` on accounting events. State-changing external
token interactions are guarded, and callback tests verify failed re-entry.
There is no externally callable unchecked accounting mutation. Rate and checkpoint
paths do not make an external token call; no events can survive a reverted call.
The warnings are documented rather than suppressed.

## Independent reviewer and manifest checks

Review the actual accepted source and ABI, not just the test outcome. Confirm:

- The only project deployment records are `LaunchToken` and `TestStaking`, with
  zero and two constructor arguments respectively; staking binding order is
  `[$token, $owner]`, and `$owner` is the supplied launch owner.
- Constructor bytecode, compiler settings and source artifact linkage agree.
  Policy attestations/signatures and service admission belong to services; absence
  of a later signed artifact is not a source-constructor finding.
- Any concrete token, constructor, permission, pool-policy or authorization conflict
  is still a finding and must be resolved before deployment.
- No staking allocation is taken from the launch supply. Pool/distributor/guard
  behavior is supplied by the supported launch mechanism.
- Pool policy remains native ETH, fee 12500, tick spacing 60 and the supplied
  manifest price; effective initialization uses the launch policy opening cap.
- Custody and lifetime points continue to satisfy the interval model under
  adversarial operation sequences and realistic maximum elapsed times/rates.

Services must independently verify the selected Sepolia infrastructure, publish
and attest source, obtain review/admission, fund/deploy, initialize and seed usable
liquidity, and record receipts and executable swap evidence. Only actual deployment
outputs may bind the later website. None of these later outcomes is fabricated or
treated as a prerequisite for completing this source contribution.
