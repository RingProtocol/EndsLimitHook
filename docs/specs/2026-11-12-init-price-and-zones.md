# EndsLimitHook — init price, zones, arb

Date: 2026-11-12  
Status: implementing

## Problem

1. Midpoint init `(pLow+pHigh)/2` puts the pool in the **middle**. With middle `SwapNotSupported`, **no swap can run** → price is frozen; strategy never starts.
2. Even with ends open: **directional gates that only push away from mid make buy↔sell unreachable** if middle also reverts (absorbing barriers).
3. Full-range LP `[pLow,pHigh]` + middle block ⇒ buy zone `<pLow` has **inactive** LP; sell zone works; buy-low funding does not.

## Target geometry (range 2500–3500, edge 2%)

| Zone | Price / tick | Swap | LP |
|---|---|---|---|
| Buy | below `buyUpper` ≈ 2550 | **both** | band `[pLow, pLow*(1+edge)]` |
| Middle | `buyUpper .. sellLower` | **both** (empty → cheap cross) | none |
| Sell | at/above `sellLower` ≈ 3430 | **both** | band `[pHigh*(1-edge), pHigh]` |

**Naming (LP perspective):** low/buy band = user sells ETH, LP buys ETH; high/sell band = user buys ETH, LP sells ETH.

**Forced init**: `sqrtPrice = atTick(buyUpper)` ≡ `pLow*(1+edge)` (e.g. 2550).  
At init, buy-band LP is ~100% USDT. As users sell ETH into the band, price falls toward `pLow` (2500). When the band’s USDT is exhausted, price is at/below **buyLower ≈ 2500** and the position is ~100% ETH (dust USDT only) — **not** stuck at 2550.

**Why no end directional gates:** one-way rules re-deadlock after a partial fill. Geometry (ends-only + empty middle) bounds fill prices; reverse fill ≤ edge. Optional ops: after buy-band fills, withdraw ETH and move it to the sell band.

## Lifecycle

1. Admin `configureRange` **before** `initialize`.
2. `initialize` must use locked init sqrt (`BadInitPrice` otherwise).
3. Users add LP only on buy **or** sell band ticks.

## Arb / drift notes

- Stale mid init is impossible (forced buy-anchor).
- CEX below buy band → arb sells ETH into bid; exposure capped by band width.
- Crossing middle fills nothing (no LP).
- Reverse fill if price revisits a filled band: lose the strategy leg inside ≤2% edge, not unbounded IL across the whole range.
