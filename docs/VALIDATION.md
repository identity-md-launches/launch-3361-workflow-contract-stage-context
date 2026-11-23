# Local validation

The implementation was checked with Foundry 1.8.3 and the pinned Solidity 0.8.26
compiler. Tests are local EVM executions; no network fork, RPC, wallet key,
broadcast, environment cheatcodes, or deployment funding is involved.

## Commands

```sh
forge build
FOUNDRY_FUZZ_SEED=0x21a9806d5fc082fe821fdd52ffb66ed37c0e404666c2e9864fc41c5881aaf02b forge test
forge fmt --check
python3 tools/export_abis.py --check
forge build --sizes
```

## Test coverage and results

- `LaunchToken.t.sol`: 12 passing tests, including metadata, exact fixed supply,
  transfers/allowances and errors, no privileged mint/upgrade selectors,
  factory-like construction and runtime opcode/size checks.
- `TestStaking.t.sol`: 27 passing tests, including staggered entry, changing shares,
  partial/full exits, empty intervals, same-timestamp operations, saved/view point
  consistency, rate authorization and changes, two-step ownership, fractional carry,
  maximum rate/duration, full-supply stake, donations and principal conservation.
- `TestStakingSecurity.t.sol`: 8 passing tests with adversarial token fixtures,
  including failed deposit/withdrawal rollback, retries, missing return data,
  rejected short deposits and incoming/outgoing callback reentrancy.
- `TestStakingInvariant.t.sol`: one passing invariant campaign group containing
  three invariants, at 256 runs and depth 128 (**32,768 randomized calls**, zero
  reverts). Six actions cover stake, withdraw, advance time, change rate, checkpoint
  and donate across four actors. Independent interval allocations are calculated at
  10^45 precision with lower/upper bounds; final full exits verify recoverability.

Foundry 1.8.3 reports **48 tests passed, 0 failed, 0 skipped** including the grouped
invariant campaign. Three parameter fuzz tests each run 1,024 cases with the
assignment's seed. All three invariant functions are checked after each generated
action; the final-exit hook checks both principal and points again.

The production runtime sizes are 1,722 bytes for LaunchToken and 3,975 bytes for
TestStaking, comfortably under 24,576 bytes. Creation sizes are 2,603 and 4,480
bytes respectively, before staking constructor words. No library link references
are needed. The source contribution has exactly two production contracts in src/.

`forge build`, `forge test`, `forge fmt --check` and the ABI comparison pass.
A clean `forge build --force --offline` and the seeded `forge test --offline`
also pass. Every vendored dependency file matches its recorded SHA-256 hash;
both compiled ABIs match the exports and both artifacts have empty link references.
Build lint observations and their rationale are documented in
[REVIEW.md](REVIEW.md). Slither/Mythril and an independent audit were not run.

The supplied protected floor files were read to understand their requirements.
Their service-provided deployment environment and owner harness are not part of
this repository; the service runs those exact checks independently. Our local
factory, supply, owner-binding, runtime/opcode and application tests require none
of that environment and do not substitute for the service's attestation.

No local result proves a live address, deployment receipt, usable pool liquidity,
swap, source publication or hosted website. Those remain later workflow stages.
