# EndsLimitHook — admin-locked range (per pool)

Date: 2026-11-11  
Status: approved

## Goal

One `PoolId` (e.g. ETH/USDT) shares one strategy range for all LPs. Different pairs are different pools. Hook gates middle swaps; does not place LP.

## Rules

1. **Admin-only `configureRange(pLow, pHigh, edgeBps)`** — once per pool (`AlreadyConfigured`).
2. **`edgeBps`**: `(0, 200]` (max 2%).
3. **Range width**: `pHigh * 10_000 >= pLow * 10_500` (≥ 5%), else revert.
4. **Pool `initialize`**: unrestricted; first caller sets initial price.
5. **`addLiquidity`**: anyone; `tickLower/Upper` must equal admin-locked range ticks, else revert. Unconfigured → revert.
6. **`swap`**: anyone; middle → `SwapNotSupported`; `tick < buyUpper` only sell-asset-in; `tick >= sellLower` only buy-asset-out (open-ended up).
7. **No** hook self-`modifyLiquidity` / `placeBuy` / `placeSell`.

## Out of scope (this change)

- Multi-decimal / inverted asset-quote pairs
- Per-user ranges on the same `PoolId`
