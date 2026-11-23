# Test / TEST contracts

This contribution implements the two project contracts for the approved Sepolia
launch: `LaunchToken` and `TestStaking`. It includes their source, offline
dependencies, Foundry tests, exported ABIs and a handoff for the separate manifest,
review, deployment and frontend stages.

## Build and test

Run at the repository root with Foundry and Solidity 0.8.26 installed:

```sh
forge build
FOUNDRY_FUZZ_SEED=0x21a9806d5fc082fe821fdd52ffb66ed37c0e404666c2e9864fc41c5881aaf02b forge test
forge fmt --check
python3 tools/export_abis.py --check
```

`foundry.toml` pins Solidity 0.8.26, Cancun, the optimizer at 200 runs and
`bytecode_hash = "none"`. There is no FFI, filesystem cheatcode permission, RPC,
environment-based test configuration, compiler binary or deployment script.
OpenZeppelin Contracts 5.1.0 (the required source closure) and forge-std 1.9.7
are ordinary vendored files in `lib/`, including their licenses. No installation
or network connection is required to build or test with the pinned compiler.
Source locations and SHA-256 hashes are in [docs/dependencies.json](docs/dependencies.json).

After a source/ABI change, run `python3 tools/export_abis.py` to regenerate the two
ABI arrays in [docs/abi](docs/abi). Python is only needed for ABI export/checking,
not for `forge build` or `forge test`.

## Contracts and deployment parameters

| Order | Source / Solidity name | Nonpayable constructor arguments | Purpose |
| --- | --- | --- | --- |
| 1 | `src/LaunchToken.sol:LaunchToken` | None | Fixed-supply ERC-20, Test / TEST |
| 2 | `src/TestStaking.sol:TestStaking` | `address token_ = $token`, `address owner_ = $owner` | Custody and internal points |

`$owner` resolves to the supplied launch owner
`0x047f606fd5b2baa5f5c6c4ab8958e45cb6b054b7`. The later manifest must use `$owner`
for this privileged argument. The factory is the token's initial supply recipient,
but it is **not** the staking owner. Constructors make no external calls and do
not require the token address to have code. Staking rejects an address without
code on first deposit; its immutable token binding must be the actual `$token`.

There are exactly two project deployment artifacts. Libraries are internal or
inherited; no library linking or extra reward-token deployment is needed.
Mocks and the factory probe in `test/` are test fixtures only.

### Economic settings

| Setting | Value / authority |
| --- | --- |
| Network | Sepolia, chain ID `11155111` |
| Token name / symbol / decimals | `Test` / `TEST` / `18` |
| Fixed token supply | `1_000_000_000 TEST` = `10^27` minor units, minted once to the constructor caller |
| Token transfers | Plain ERC-20; no transfer fee, extra mint, owner, pause, blocklist or upgrade |
| Initial global points rate | `DEFAULT_POINTS_PER_SECOND = 10^18` minor units/s = **1 point/s**, shared across all stakers |
| Configurable points rate | Owner may set any integer from `0` to `MAX_POINTS_PER_SECOND = 10^24` minor units/s = 1,000,000 points/s |
| Point display decimals | `POINTS_DECIMALS = 18`; points are bookkeeping, not TEST or a claim on tokens/ETH |
| Total stake cap | `MAX_TOTAL_STAKED = 10^27` TEST minor units, equal to the entire launch supply |
| Precision | `ACC_PRECISION = 10^36`, with carried global and user fractions |
| Stake/withdraw fees, lockup, minimum duration | None; minimum action is one TEST minor unit |

The points rate is a documented initial configuration chosen for this build, not
a claimed network policy default. The owner-settable rate satisfies the workflow's
requirement for unspecified emission parameters. The cap and precision are chosen
implementation bounds; the rate cap provides ample arithmetic headroom for realistic
chain lifetimes. Tests include 100 years at maximum rate with a one-wei stake.

The launch policy, administered by services, splits the initial supply: 10% to the
swarm via its MerkleDistributor, 80% to pool liquidity, and 10% to the paying wallet
(or the chain treasury when unpaid). No allocation or reserve goes to TestStaking.
Only subsequent user deposits fund principal. The factory supplies the distributor
and initialization guard; neither is an additional project artifact here.

The pool pairs TEST with native ETH (`pairedCurrency = address(0)`, the native
currency sentinel). Policy settings are fee `12500` (1.25%), tick spacing `60`,
and manifest `initialPrice = "79228162514264337593543950336"`. The service derives
the effective opening price from the policy's **20 ETH opening market cap for the
entire supply** and currency ordering. The manifest price is not a promise of a
one-ETH-per-TEST execution price. The launch's pool fee is 1% for the paying wallet
and 0.25% for IMD, implemented by launch infrastructure, not by these contracts.

## Staking behavior

1. Approve TestStaking on TEST for the exact amount to deposit, then call
   `stake(amount)`. Only the caller's tokens can be pulled. A successful deposit
   credits exactly the received amount; a short transfer, false return or revert
   rolls the entire operation back.
2. During any constant-stake, constant-rate interval, the ideal allocation is
   `rate * elapsedSeconds * userStake / totalStaked`. Timestamp differences
   determine elapsed time; this is accounting, not randomness. An empty vault
   emits no points and the next depositor receives no historical allocation.
3. `withdraw(amount)` checkpoints earnings, reduces the caller's stake and returns
   that exact principal to the caller. Partial and full exits are supported at any
   time. A failed token transfer reverts the checkpoint and stake changes together,
   so the user can retry. Earned points and sub-unit fractions survive a full exit
   and later re-entry.
4. `checkpoint()` optionally saves the caller's cumulative points. It neither pays
   a reward nor resets earnings. Stake and withdrawal already do this automatically.
5. `setPointsPerSecond(newRate)` checkpoints the global accumulator at the old
   rate before installing the new rate. A zero rate stops future points but does
   not disable stake, withdrawal or access to previous points.

The immutable token is specifically the delivered LaunchToken. Fee tokens,
rebasing tokens, malicious tokens and upgradeable replacements are not supported.
SafeERC20 and ReentrancyGuard protect interactions; adversarial mocks exercise
their failure paths. Normal LaunchToken has no callback or external transfer hook.
There are no loops over stakers in production: all operations have constant cost.

Direct token transfers to TestStaking are **donations**, not deposits. They do not
create stake, change totalStaked, or change shares. There is deliberately no rescue
or administrator withdrawal function, so donated TEST and other mistakenly sent
tokens cannot be recovered. The contract rejects ordinary native-ETH transfers;
any forcibly sent ETH is also inaccessible.

## Precision and conservation

Let `Q = 10^36`, `S = totalStaked`, `E = elapsed * rate`, `A` be the global
accumulator and `r` its remainder. At each checkpoint while nonempty:

```text
A += floor((E * Q + r) / S)
r  = (E * Q + r) mod S
```

Full-precision `Math.mulDiv` and `mulmod` compute this without forming the large
intermediate product. Repeated checkpoints at an unchanged stake distribution
carry `r`; splitting an interval into many checkpoints does not destroy its dust.
Rate changes also retain it. On **each stake change**, the old distribution is
checkpointed and `r` is then discarded so a new entrant cannot receive earlier
rounding dust. Each such loss is less than `S / Q <= 10^-9` point minor units.

A user's incremental scaled entitlement is
`stake * (A - userPointsPerTokenPaid) + userPointRemainder`. Whole point minor units
are credited and the fraction modulo `Q` is retained, even after withdrawal. Users
cannot erase fractions by checkpointing, nor manufacture earnings by repeated
same-timestamp transactions.

For `M` stake changes, the aggregate loss from the ideal continuous allocation is
less than `M * 10^-9` point minor units before integer display rounding. Displayed
cumulative totals round down by less than one additional minor unit per account.
Thus, for `N` participating accounts, emitted points minus the sum of displayed
points is nonnegative and less than `N + M * 10^-9` minor units. One minor unit is
`10^-18` points. Even a sole staker can be one displayed minor unit below the ideal
after a distribution change; fractions and this explicit bound make that behavior
predictable. Principal has **no rounding**: custody always backs totalStaked
one-for-one, with any direct donations remaining surplus.

## Permissions and After launch

The only application authority is `TestStaking.owner()`. It can change the future
points rate within the cap, initiate/cancel a two-step ownership transfer, or
renounce ownership. It cannot mint TEST, move principal, remove points, change the
token, block withdrawals, pause staking or upgrade code. Users trust the owner for
future emission policy only. Ownership acceptance by the proposed new owner is
required. Renunciation irreversibly fixes the then-current rate, including zero.

After launch, the owner should inspect `token()`, `owner()` and `pointsPerSecond()`
against the approved deployment. The sole configurable setting is:

| Setter | What to set | Source of value |
| --- | --- | --- |
| `setPointsPerSecond(uint256)` | Desired global rate in point minor units/s, within the cap; initial value is already 1 point/s | Launch owner's points program policy, not an external oracle or service |

There are no unresolved subscriptions, signers, feeds, recipients or owner inputs
for these contracts. The owner need not call an initializer, fund rewards or run
periodic checkpoint transactions. Every user pays Sepolia transaction gas for
their own approvals/deposits/withdrawals. The launching service supplies launch
funding and infrastructure configuration; balances and successful liquidity
provision are not asserted by local tests.

## Verification and release handoff

See [docs/ABI.md](docs/ABI.md) for integration details,
[docs/VALIDATION.md](docs/VALIDATION.md) for local test evidence, and
[docs/REVIEW.md](docs/REVIEW.md) for trust assumptions and review targets.

This artifact is the contract implementation stage. `launch.json` belongs to the
subsequent manifest assignment; the independent contributor must review accepted
source together with its concrete constructor bindings. Services own source
publication, signed artifact/policy linkage, attestation, admission and deployment.
No transactions were signed or broadcast here.

The overall release still needs independently reviewed source/manifest, the actual
two contract addresses and receipts, the initialized and funded tradable pool with
its exact key/ID, and evidence of an executable swap. Simulations must be labeled
separately from live transactions. Existing Sepolia Uniswap v4 infrastructure must
be checked against primary sources and live chain code by the launch stage;
these contracts neither embed nor depend on a router/pool address.

The subsequent frontend stage must bind `$token` and `$contract:TestStaking` to
the actual deployment handoff, enforce chain 11155111, show TEST balances,
stakes/share/points and provide approval, stake and withdrawal with validated
amounts and transaction states. Use the exact handed-off pool key and actual
verified explorer/trade links. IPFS publication and wallet/approval/staking/
withdrawal smoke-test evidence remain subsequent-stage deliverables. No local test
constitutes deployment, pool liquidity, an independently completed audit, or a
published website.
