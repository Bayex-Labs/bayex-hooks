# Bayex Hooks

A Uniswap v4 hook that captures arbitrage surplus and redistributes it to LPs in prediction market conditional token pools.

Built for the **Atrium UHI8 Hackathon**.

## Problem

When ERC-20 wrapped prediction market conditional tokens (e.g., YES/NO tokens) are traded on AMMs, arbitrageurs extract value from LPs by trading against stale pool prices whenever the "true" probability shifts on external orderbooks. This is the **Loss-Versus-Rebalancing (LVR)** problem — and it's particularly acute in prediction markets where prices move sharply around events.

The result: LPs (prediction market traders who deposit their bet positions as liquidity) lose value to arbitrageurs who contribute nothing to price discovery beyond bridging a latency gap.

## Solution: Directional Flow Imbalance Fee

Bayex captures arbitrage surplus **without relying on external oracles or centralized keepers**. Instead, it uses an endogenous signal — the pool's own recent trading flow — to distinguish informed (arbitrage) trades from uninformed (genuine) trades and charge accordingly.

### Core Insight

Arbitrage trades have a distinct on-chain signature: they arrive in **bursts of heavy one-sided flow** right after external price movements. Genuine trades, by contrast, tend to be more balanced over time (some buying YES, some buying NO). The hook uses this directional imbalance as a proxy for "how likely is this swap to be arbitrage?" and dynamically adjusts fees.

### Mechanism

1. **Track recent net flow** — The hook maintains a sliding window of net directional volume across recent swaps. This produces an imbalance ratio: `|netDirectionalFlow| / totalFlow`.

2. **Dynamic fee scales with imbalance**:

   ```
   fee = baseFee + k * (netDirectionalFlow / totalFlow)^2
   ```

   - **Balanced flow** (imbalance ≈ 0): fee ≈ `baseFee` — cheap for genuine traders.
   - **Heavy one-sided flow** (imbalance → 1): fee spikes — captures the surplus arbitrageurs would have extracted.

3. **Time decay** — The imbalance metric decays over time so fees naturally reset after an arbitrage wave passes, ensuring the pool doesn't stay expensive during quiet periods.

4. **State update in `afterSwap`** — Each swap updates the flow tracking state, feeding the next fee calculation.

### Worked Example

```
Pool state: YES/USDC, current AMM price = 0.60
External event shifts true probability to 0.65

Arbitrageur 1 buys YES: imbalance is low → pays ~baseFee (gets through cheap)
Arbitrageur 2 buys YES: imbalance rising → pays elevated fee
Arbitrageur 3 buys YES: imbalance high → pays near-maximum fee

Net effect: The first arb corrects the price (necessary for discovery),
but subsequent arbs pay escalating fees that go to LPs instead of
being extracted as profit.
```

### Why This Works for Prediction Markets Specifically

- **Bounded prices (0–1)**: Fee curves can adapt based on proximity to the boundaries — prices near 0 or 1 have less room for arbitrage.
- **Complementary tokens**: Sudden one-sided flow in YES with opposite flow in NO is a strong arbitrage signal that the hook can detect.
- **Event-driven volatility**: The biggest LVR losses happen around news events, which are exactly when directional flow imbalance is highest — so the mechanism activates precisely when it's needed most.

### Design Trade-offs

| Property                       | Bayex Hook                                                   |
| ------------------------------ | ------------------------------------------------------------ |
| Decentralized                  | Yes — no oracle, no keeper, fully on-chain                   |
| Instant execution              | Yes — no auction delay, swaps settle immediately             |
| Captures first arb trade       | Partially — the first trade establishes the imbalance signal |
| Captures subsequent arb trades | Yes — escalating fees capture the bulk of surplus            |
| Manipulation resistant         | Splitting across wallets still registers as one-sided flow   |

The main concession: the very first arbitrage trade in a new direction gets through at roughly `baseFee`. But this trade is also what provides price discovery — so paying for it is arguably correct. The hook captures the surplus from the **wave** of follow-on arbitrage that typically follows.

## USDC-Denominated Fee Collection

LPs in prediction market pools are exposed to accumulating fees in the conditional token, which can go to zero at market resolution. Bayex solves this by letting each LP configure their preferred fee denomination split, defaulting to 100% USDC.

### How It Works

1. **Hook-managed fees** — The pool's built-in LP fee is set to 0. Instead, the hook collects fees directly from both sides of each swap using v4's delta return system.
2. **Per-LP fee split** — Each LP sets a `feeSplitUSDC` value (0–100%). This controls what fraction of their earned fees are denominated in USDC vs. the conditional token.
3. **Aggregate split** — The pool-wide USDC/token fee ratio is the liquidity-weighted average of all LP preferences. This determines how much of each swap's fee is taken in USDC vs. token.
4. **Two-sided collection** — `beforeSwap` takes the fee from the specified (input) side, `afterSwap` takes from the unspecified (output) side. Which currency maps to which side depends on swap direction.

### Fee Split Mapping by Swap Direction

| Swap Direction        | Specified (input) | Unspecified (output) | USDC fee via       | Token fee via      |
| --------------------- | ----------------- | -------------------- | ------------------ | ------------------ |
| USDC → YES (zeroForOne) | currency0 (USDC)  | currency1 (YES)      | beforeSwap delta   | afterSwap return   |
| YES → USDC (oneForZero) | currency1 (YES)   | currency0 (USDC)     | afterSwap return   | beforeSwap delta   |

### Fee Distribution Math

Each LP earns from two buckets based on their weighted contribution:

- **USDC bucket**: LP earns proportional to `LP_liquidity * LP_feeSplitUSDC / totalUSDCWeight`
- **Token bucket**: LP earns proportional to `LP_liquidity * (1 - LP_feeSplitUSDC) / totalTokenWeight`

Fee-per-liquidity accumulators (similar to Uniswap's `feeGrowthGlobal`) track cumulative fees. When an LP modifies their position or changes their split, pending fees are snapshotted into their accrued balance.

### LP Lifecycle

1. **Add liquidity** — LP address is passed via `hookData` (since `sender` in v4 callbacks is the router, not the user). New positions default to 100% USDC.
2. **Configure split** — LP calls `configureFeeSplit()` to change their USDC/token preference. Existing fees are snapshotted at the old split.
3. **Claim fees** — LP calls `claimFees()` to withdraw accrued USDC and token fees.
4. **Remove liquidity** — Accrued fees are preserved and remain claimable after removal.

## Architecture

### Hook Entry Points

| Hook                    | Purpose                                                                 |
| ----------------------- | ----------------------------------------------------------------------- |
| `afterInitialize`       | Initialize flow state for the pool                                      |
| `beforeAddLiquidity`    | Validate that `hookData` contains LP address                            |
| `afterAddLiquidity`     | Track LP position, update pool weights                                  |
| `beforeRemoveLiquidity` | Validate `hookData`                                                     |
| `afterRemoveLiquidity`  | Snapshot fees, reduce LP position, update pool weights                  |
| `beforeSwap`            | Compute dynamic fee, take specified-side fee, store transient data      |
| `afterSwap`             | Take unspecified-side fee, update flow state and fee accumulators       |

### External Functions

| Function             | Description                                                        |
| -------------------- | ------------------------------------------------------------------ |
| `configurePool`      | Set pool parameters (baseFee, k, windowSize, decayRate)            |
| `configureFeeSplit`  | LP sets their USDC/token fee preference for a position             |
| `claimFees`          | LP withdraws accrued USDC and token fees                           |
| `getPendingFees`     | View pending (unclaimed) fees for an LP position                   |
| `getAggregateUSDCSplit` | View the pool's current aggregate USDC fee split                |
| `getCurrentFee`      | View the current dynamic fee for the pool                          |
| `getImbalanceRatio`  | View the current flow imbalance ratio                              |

### Key Parameters

| Parameter    | Description                                                              |
| ------------ | ------------------------------------------------------------------------ |
| `baseFee`    | Minimum fee charged on all swaps                                         |
| `k`          | Aggressiveness of surplus capture (higher = more fee on imbalanced flow) |
| `windowSize` | Time window for flow tracking (seconds)                                  |
| `decayRate`  | How quickly the imbalance metric decays toward zero                      |

## Development

```bash
forge build    # compile
forge test -vv # run tests
```

### Test Coverage

- LP registration and fee state tracking
- USDC-only and mixed-split fee collection
- Fee claiming flow
- Fee split configuration with snapshotting
- Multiple LPs with different splits and correct aggregate ratio
- Partial liquidity removal preserving accrued fees
- Flow imbalance escalation, balanced flow, and time decay
- Arbitrage scenario (escalating fees on one-sided flow)
- Access control and input validation

## License

MIT
