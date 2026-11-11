# EndsLimitHook

Uniswap v4 hook：每个池（如 ETH/USDT）由**管理员配置一套锁定 range**；用户只能按该 range 加仓；中间 `beforeSwap` 拒单，两端开门外按方向放行。

设计稿：[docs/specs/2026-11-11-admin-range-design.md](docs/specs/2026-11-11-admin-range-design.md)  
玩法图：[docs/liquidity-play.md](docs/liquidity-play.md)

## 机制

1. 管理员 `configureRange(pLow, pHigh, edgeBps)`（每池一次）
   - `edgeBps ∈ (0, 200]`（≤2%）
   - 宽度 ≥5%：`pHigh * 10000 >= pLow * 10500`
2. 池 `initialize` 不限制；第一个调用者定初始价
3. 任何人 `addLiquidity`，但 ticks 必须等于锁定 range
4. 任何人 `swap`；中间 `SwapNotSupported`；低端只许卖资产进、高端只许买资产出（含冲破上沿）

## 测试

```bash
bash scripts/install-libs.sh
forge test -vv
```
