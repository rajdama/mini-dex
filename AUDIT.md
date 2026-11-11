# Self-Audit: Mini DEX

An internal security review of the contracts in `contracts/src`. This is a self-review for a learning
and portfolio project, **not** a third-party audit. Don't use these contracts with real funds.

## Summary

| Severity | Found | Fixed | Mitigated by design | Acknowledged |
|---|---|---|---|---|
| High | 0 | – | – | – |
| Medium | 2 | 1 | 1 | – |
| Low | 3 | 2 | – | 1 |
| Informational | 5 | – | – | 5 |

## Scope and method

| Item | Detail |
|---|---|
| Contracts | `core/Pair.sol`, `core/Factory.sol`, `periphery/Router.sol`, `periphery/DexLibrary.sol`, `periphery/FlashArbitrage.sol`, `farm/StakingRewards.sol` (reviewed separately in [staking-rewards](https://github.com/rajdama/staking-rewards/blob/main/AUDIT.md)), `tokens/FaucetToken.sol` |
| Libraries | OpenZeppelin v5.1.0: ERC20, SafeERC20, ReentrancyGuard, Math |
| Compiler | Solidity 0.8.24, optimizer 200 runs |
| Tests | 115 tests: unit, fuzz, invariant, attack scenarios and deploy scripts |
| Coverage | 100% lines, statements, branches and functions for every contract |
| Invariants | 4 DEX properties over 25,600 random calls per run (swaps, multi-hop swaps, liquidity adds and removes, donations, arbitrage, time jumps), `fail_on_revert` on |
| Static analysis | Slither on every push; CI fails on any medium or high finding |
| End-to-end | Deploy script, a real swap and a farm renewal run on a local chain on every push; a full-stack run with the indexer and arbitrage bot runs on demand |

### Invariants

1. **Reserves match balances:** every pair's stored reserves equal its real token balances.
2. **LP value never decreases:** `k / totalSupply²` (the value behind one LP token) never goes down,
   whatever anyone does. Swaps only add fees, and mints and burns round in the pool's favor.
3. **Minimum liquidity stays locked:** no pool can ever be fully drained.
4. **Periphery holds no funds:** the Router and the arbitrage contract never keep anyone's tokens.

## Attack scenarios tested

| Attack | Result | Test |
|---|---|---|
| **Sandwich attack**: front-run a victim's swap, let it fill at a worse price, back-run | Blocked by the Router's `amountOutMin`; without it the victim loses 29% and the attacker gains 3 ETH | `test/Attacks.t.sol` |
| **First-depositor inflation**: seed a pool with dust, donate to inflate the LP price | Uneconomical: the attacker recovers under 0.1% of the donation because 1,000 LP are locked forever | `test_InflationAttackIsUneconomical` |
| **Reentrancy during a flash swap**: call back into the pair mid-swap | Reverts (`ReentrancyGuard`) | `test_RevertWhen_ReenteringDuringFlashSwap` |
| **Read-only reentrancy**: read the pair's stale reserves mid-swap and use them as a price | Reverts: `getReserves()` refuses to answer while the pair is locked | `test_RevertWhen_ReadingReservesDuringFlashSwap` |
| **Underpaid flash swap** | Reverts with `K()` | `test_RevertWhen_FlashSwapUnderpaid` |
| **Swap without the fee**: take the no-fee `x*y=k` output | Reverts with `K()` | `test_RevertWhen_SwapWithoutFee` |
| **Spoofed arbitrage callback**: call `flashSwapCall` directly or from a swap someone else started | Reverts with `UnauthorizedCallback` | `test_RevertWhen_CallbackNotFromOwnFlashSwap` |
| **Round-trip extraction**: swap there and back, or add and remove liquidity, for profit | Never profitable (fuzzed) | `testFuzz_RoundTripNeverProfits`, `testFuzz_AddRemoveNeverProfits` |

## Findings

### M-1: Read-only reentrancy through `getReserves()` (Fixed)

**Where:** `Pair.swap` during a flash swap.
**Issue:** during a flash swap, the pair has sent tokens out but hasn't updated its reserves yet. In the
classic Uniswap V2 design, `getReserves()` still answers during that window. Another protocol that uses
the pair's reserves as a price could be called from the flash-swap callback and act on a stale price.
This class of bug has caused real losses in lending protocols.
**Fix:** `getReserves()` reverts with `Locked()` while the pair's reentrancy guard is entered. Internal
code reads the reserve variables directly. Slither flags the callback as `reentrancy-no-eth`; that line
is marked as reviewed and points to the test proving the protection.

### M-2: Sandwich attacks and stale transactions (Mitigated by design)

**Issue:** pairs execute at whatever the price is when the transaction lands. A pending swap can be
sandwiched, or sit in the mempool and execute much later at a bad price.
**Mitigation:** the Router requires `amountOutMin` / `amountInMax` and a `deadline` on every swap and
liquidity change, and the frontend sets them from the user's slippage setting (0.5% by default) and a
20-minute deadline. Users calling the pair directly get no protection; that's by design, as in Uniswap V2.

### L-1: Gas estimates can be too low for the first trade in a block (Fixed in the frontend)

**Issue:** found during the end-to-end run. A pair's TWAP accumulators update only on the first state
change in a new block. A gas estimate simulated in the same block as an earlier trade skips those two
storage writes (about 10k gas), so the real transaction can run out of gas.
**Fix:** the frontend estimates gas itself and adds a 30% margin before sending.

### L-2: Slither findings resolved in code (Fixed)

- `weak-prng` on `block.timestamp % 2**32`: rewritten as a plain truncation (`uint32(block.timestamp)`).
- `unused-return` on token sorting: replaced `sortTokens` with `isToken0`, which returns only what's used.
- `missing-zero-check`: the Router and FlashArbitrage constructors reject the zero address.
- Stack-too-deep in `swap`, `addLiquidity` and `execute`: split into helpers instead of enabling `via_ir`,
  so coverage builds keep working.

### L-3: Fee-on-transfer and rebasing tokens are not supported (Acknowledged)

The pair measures input by balance differences, so a fee-on-transfer token works for swaps into the pool
but the Router's quotes will be wrong, and rebasing tokens break the reserves. Like Uniswap V2's base
router, this DEX assumes standard ERC20 tokens.

### I-1: `incorrect-equality` on `amount == 0` checks (Acknowledged, false positive)

Comparisons such as `liquidity == 0` and `amount0In == 0 && amount1In == 0` are intended exact checks on
amounts, not on balances an attacker can nudge. Marked as reviewed inline.

### I-2: TWAP accumulator arithmetic (Acknowledged, intended)

`(reserve << 112) / reserve * elapsed` is flagged as divide-before-multiply; it's the standard UQ112x112
encoding, and the accumulators are designed to overflow (consumers take differences).

### I-3: Timestamp use (Acknowledged)

Deadlines, oracle accumulators, faucet cooldowns and farm periods use `block.timestamp`. Validators can
shift it by seconds, which is negligible at these time scales.

### I-4: Loops over paths (Acknowledged)

The Router and FlashArbitrage loop over the swap path. Paths are chosen by the caller, so only the caller
pays for a long one.

### I-5: No protocol fee or admin (Acknowledged)

Pairs and the Router have no owner and no admin functions: nobody can pause trading, change fees or move
funds. Farms have an owner who can fund rewards and recover rewards that accrued while nobody was staked,
but cannot touch staked LP tokens.

## Slither results

Latest run: **0 high, 0 medium**. Remaining results are low or informational: `timestamp`, `calls-loop`,
`reentrancy-benign`, `reentrancy-events` (all on calls protected by the reentrancy guard or to trusted
pairs) and `too-many-digits` (constants such as `10_000`).
