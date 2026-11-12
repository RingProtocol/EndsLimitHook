# EndsLimitHook

Uniswap v4 hook：每池管理员锁定 range；**初始价强制为 `pLow×(1+edge)`**（非中点）；只能在两端 band 加仓；中间可穿价。

**统一说法（LP 视角命名）：**

- **低区 / 买带**：用户卖 ETH，池子（LP）买 ETH  
- **高区 / 卖带**：用户买 ETH，池子（LP）卖 ETH  

规格：
- [docs/specs/2026-11-11-admin-range-design.md](docs/specs/2026-11-11-admin-range-design.md)
- [docs/specs/2026-11-12-init-price-and-zones.md](docs/specs/2026-11-12-init-price-and-zones.md)  
玩法（含「USDT 换完价格停哪」）：[docs/liquidity-play.md](docs/liquidity-play.md)  
闪电贷：[docs/specs/2026-11-12-flash-loans.md](docs/specs/2026-11-12-flash-loans.md)

## 机制

1. 管理员 `configureRange(pLow, pHigh, edgeBps)`（**先于** `initialize`）
   - `edgeBps ∈ (0, 200]`；宽度 ≥5%
   - 买带 `[pLow, pLow×(1+edge)]`（例 `[2500, 2550]`），卖带 `[pHigh×(1-edge), pHigh]`
   - 锁定 init = tick(`buyUpper`) ≈ `pLow×(1+edge)`（例 **2550**：此时买带 ≈100% USDT）
2. `initialize` 必须用该 init sqrt，否则 `BadInitPrice`
3. 加仓只允许买带或卖带 ticks
4. `beforeSwap`：已配置即可双向成交（不做两端单向门）；空心中间穿价；回吐风险 ≤ edge  
5. 买带 USDT 被用户卖 ETH 吃光后，现价在带**下沿 ≈ pLow（2500）**，不是 2550；仓位 ≈100% ETH（可有粉尘 USDT）

## 测试

```bash
bash scripts/install-libs.sh
forge test -vv
```
