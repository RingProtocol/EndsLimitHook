# EndsLimitHook — flash loan considerations

Date: 2026-11-12

## What flash changes

v4 `unlock` + `take` lets an attacker use **uncollateralized inventory for one transaction**.  
It does **not** create new price trajectories: fills still only happen where LP exists (buy/sell bands). Empty middle still crosses with ≈0 fill.

## Attack sketches

| Path | What they try | Outcome |
|---|---|---|
| Flash USDT → buy ETH from 2550 | Grab sell-band ETH “at 2550” | Empty middle → price jumps; fills start ≈**sellLower (3430+)**. No cheap ETH. |
| Flash ETH → dump into buy band → buy back | Drain USDT bid then reverse | Classic round-trip; pay bid/ask + fees inside ≤edge; **no free lunch**. |
| Flash → add middle LP | Bypass geometry | `beforeAddLiquidity` → `RangeLocked`. |
| Flash → sandwich LP add/remove | Standard AMM sandwich | Same as any CL pool; not unique to this hook. Hook does not mint LP for them. |
| Same-tx cross sell then dump buy | Arb inside one pool | Buy high (sell band) / sell low (buy band) ⇒ **lose** value. |

## Cross-venue arb (flash helps size only)

If another on-chain pool marks ETH at 2000 while this buy band still pays ~2500, arb sells ETH here / buys there. Flash scales size; **edge width still caps** how much this pool’s bid pays. Same for ask side vs a richer venue.

## Hook surface

- No `beforeSwapReturnDelta` custom accounting → no hook-custody flash steal.
- `configureRange` once, owner-only → cannot reconfigure mid-flash.
- Middle is **not** a swap ban → no “start outside / end inside forbid” afterSwap issue for flashes.

## Residual risks (accept / ops)

1. **Reverse fill** after buy-band fills: price revisits band within edge — LP may sell ETH back. Mitigate: withdraw & move ETH to sell band (off-hook ops).
2. **Empty-middle price jump** can move `sqrtPrice` to limit with 0 fill (already covered in Boundary tests) — not theft, just mark movement.
3. **Standard sandwich** of user swaps against end bands — fee tier / edge sizing / off-chain execution hygiene.

## Tests

See `test/Flash.t.sol`:

- Atomic unlock cross-middle buy → fill economics in sell band (eff. price >> 2550)
- Same-tx / atomic round trip sell-band→buy-band → no free quote
- Cannot add middle LP in the same attack tx

Note: tests settle from the payer inside one `unlock` (flash-equivalent paths). v4 `take`+repay is the same geometry; double-counting take+exact-in debt is easy to get wrong and is not required to validate the hook.
