---
marp: true
theme: uncover
paginate: true
backgroundColor: #0a0a0a
color: #e0e0e0
style: |
  section {
    font-family: 'Inter', 'Helvetica Neue', sans-serif;
  }
  h1 {
    color: #7c3aed;
    font-size: 2.2em;
  }
  h2 {
    color: #a78bfa;
    font-size: 1.6em;
  }
  strong {
    color: #c4b5fd;
  }
  code {
    background: #1e1e2e;
    color: #a78bfa;
    padding: 2px 8px;
    border-radius: 4px;
  }
  table {
    font-size: 0.75em;
  }
  th {
    background: #7c3aed;
    color: white;
  }
  td {
    background: #1e1e2e;
  }
  blockquote {
    border-left: 4px solid #7c3aed;
    background: #1e1e2e;
    padding: 12px 20px;
    font-style: italic;
  }
  a {
    color: #a78bfa;
  }
  .columns {
    display: flex;
    gap: 40px;
  }
  .col {
    flex: 1;
  }
---

# Bayex

### Arbitrage-Resistant Fees for Prediction Market AMMs

A Uniswap v4 Hook

**Atrium UHI8 Hackathon**

---

# The Problem

LPs in prediction market pools **lose money to arbitrageurs**.

When external odds shift (news, orderbook movement), arbs trade against stale AMM prices and extract value before the pool can adjust.

This is **Loss-Versus-Rebalancing (LVR)** — and it's worse in prediction markets:

- Prices move **sharply** around events
- Conditional tokens can go to **zero** at resolution
- LPs accumulate fees in a token that might become **worthless**

> LPs subsidize arbitrageurs who contribute nothing beyond bridging a latency gap.

---

# The Insight

Arbitrage has an **on-chain signature**:

**Bursts of heavy one-sided flow** right after external price movements.

Genuine trades are balanced over time. Arb trades cluster directionally.

We can use **the pool's own trading flow** as a signal — no oracle, no keeper, no off-chain infra.

---

# The Mechanism

### Dynamic Fee Formula

```
fee = baseFee + k * (netDirectionalFlow / totalFlow)^2
```

| Pool State | Imbalance | Fee |
|---|---|---|
| Quiet period, balanced trading | ~0 | baseFee (cheap) |
| Moderate one-sided flow | 0.3–0.7 | Elevated |
| Arb wave (heavy one-sided) | ~1.0 | baseFee + k (max surcharge) |

**Time decay** resets imbalance after the arb wave passes — the pool doesn't stay expensive.

---

# Worked Example

```
Pool: YES/USDC,  AMM price = 0.60
News breaks → true probability shifts to 0.65

Arb 1 buys YES:  imbalance = 1.0  → pays baseFee + k
Arb 2 buys YES:  imbalance = 1.0  → pays baseFee + k
Arb 3 buys YES:  imbalance = 1.0  → pays baseFee + k

                  ⏳ 5 minutes pass, decay kicks in

Trader buys NO:   imbalance ≈ 0   → pays baseFee (cheap)
```

Every arb in the wave pays the surcharge. Genuine traders after the wave pay base fee.

**The surplus goes to LPs, not arb bots.**

---

# USDC-Denominated Fee Collection

Fees in a conditional token that goes to zero at resolution are **worthless**.

### Our Solution

Each LP configures a **fee denomination split** (default: 100% USDC).

The hook **bypasses** v4's built-in fee mechanism and collects fees directly:

| Swap Direction | USDC fee taken via | Token fee taken via |
|---|---|---|
| USDC → YES | `beforeSwap` delta | `afterSwap` return |
| YES → USDC | `afterSwap` return | `beforeSwap` delta |

The aggregate LP preference determines the actual USDC/token split that swappers pay.

---

# LP Lifecycle

```
1. Add Liquidity       LP address passed via hookData
                       Default: 100% fees in USDC
                       ↓
2. Configure Split     LP calls configureFeeSplit()
                       e.g. 70% USDC / 30% token
                       Existing fees snapshotted
                       ↓
3. Earn Fees           Fee-per-liquidity accumulators
                       track each LP's share
                       ↓
4. Claim Fees          LP calls claimFees()
                       Receives USDC + token
                       ↓
5. Remove Liquidity    Accrued fees preserved
                       Still claimable after removal
```

---

# Architecture

### v4 Hook Entry Points

| Hook | Role |
|---|---|
| `afterInitialize` | Init flow state |
| `beforeAddLiquidity` | Validate trusted router + hookData |
| `afterAddLiquidity` | Track LP position, update weights |
| `beforeSwap` | Compute dynamic fee, take input-side fee |
| `afterSwap` | Take output-side fee, update flow state + accumulators |
| `afterRemoveLiquidity` | Snapshot fees, reduce position |

### Security

**Ownable2Step** admin | **Trusted router** pattern | **ReentrancyGuard** on claims | **Safe ERC20 transfers** | Zero-weight fee protection

---

# Design Tradeoffs

| Property | Bayex |
|---|---|
| Decentralized | Yes — no oracle, no keeper, fully on-chain |
| Instant execution | Yes — no auction delay |
| Captures first arb | Partially — first trade creates the signal |
| Captures arb wave | Yes — escalating fees on sustained one-sided flow |
| Manipulation resistant | Splitting across wallets still registers as one-sided |
| Fee denomination | Configurable per-LP, default 100% USDC |

### Known Limitations

- Fee distribution doesn't scope to in-range ticks (planned upgrade)
- WAD-precision accumulators (sufficient for most pool sizes)
- First arb trade pays elevated fee but also provides price discovery

---

# Demo

### Test Results: 37/37 passing

```
forge test -v

test_swapCollectsFeesInUSDC          ✓  USDC fees collected
test_multipleLPsWithDifferentSplits  ✓  Aggregate ratio correct
test_claimFeesAfterSwap              ✓  LP claims USDC
test_arbitrageScenario               ✓  Escalating fees on arb wave
test_feeDecaysOverTime               ✓  Fees reset after window
test_configureFeeSplitSnapshotsFees  ✓  Split change preserves earned fees
test_revertAddLiquidityFromUntrusted ✓  Router auth enforced
test_ownershipTransfer               ✓  2-step ownership works
test_zeroTokenWeightSkipsTake        ✓  No stuck fees
... +28 more
```

---

# Thank You

### Bayex — Arbitrage-Resistant Fees for Prediction Markets

Built on Uniswap v4 Hooks

**github.com** — Atrium UHI8 Hackathon
