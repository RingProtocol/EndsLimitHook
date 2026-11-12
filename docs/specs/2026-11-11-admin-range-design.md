# EndsLimitHook — admin-locked range (per pool)

Date: 2026-11-11  
Status: superseded in part by `2026-11-12-init-price-and-zones.md`

## Goal

One `PoolId` shares one admin range. Hook does not place LP.

## Rules (still valid)

1. Admin-only `configureRange` once per pool; `edgeBps ∈ (0,200]`; width ≥5%.
2. No hook self-`modifyLiquidity`.

## Updated by 2026-11-12

- Init price **forced** to `pLow*(1+edge)` (not free / not mid).
- LP only on **buy or sell end bands** (not full span).
- Middle swaps **allowed** (empty of strategy LP) so price can travel.
