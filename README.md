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

| Property | Bayex Hook |
|---|---|
| Decentralized | Yes — no oracle, no keeper, fully on-chain |
| Instant execution | Yes — no auction delay, swaps settle immediately |
| Captures first arb trade | Partially — the first trade establishes the imbalance signal |
| Captures subsequent arb trades | Yes — escalating fees capture the bulk of surplus |
| Manipulation resistant | Splitting across wallets still registers as one-sided flow |

The main concession: the very first arbitrage trade in a new direction gets through at roughly `baseFee`. But this trade is also what provides price discovery — so paying for it is arguably correct. The hook captures the surplus from the **wave** of follow-on arbitrage that typically follows.

## Architecture

### Hook Entry Points

- **`beforeSwap`** — Reads current flow imbalance state, computes the dynamic fee, returns `lpFeeOverride`.
- **`afterSwap`** — Updates the directional flow tracking (net volume, timestamps, decay).

### Key Parameters

| Parameter | Description |
|---|---|
| `baseFee` | Minimum fee charged on all swaps |
| `k` | Aggressiveness of surplus capture (higher = more fee on imbalanced flow) |
| `windowSize` | Time window for flow tracking (seconds) |
| `decayRate` | How quickly the imbalance metric decays toward zero |

## Development

*Coming soon — Foundry project setup, contracts, and tests.*

## License

MIT
