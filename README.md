# RingLowHigher — EndsLimitHook

Uniswap v4 hook：用户**第一次 `addLiquidity`** 的 tick range 即策略区间（如 2500–3500）；hook **不代挂仓**。`beforeSwap` 在中间拒单，两端开门外放行（含价格冲破上沿，如 4000）。

玩法图：[docs/liquidity-play.md](docs/liquidity-play.md)  
设计稿（多档网格远期）：[design.md](design.md)  
验证报告：[report-anvil-k1.md](report-anvil-k1.md)

## 机制（当前实现）

1. 构造时固定 `edgeBps`（如 200 = 2%）
2. 首次 `beforeAddLiquidity` → 记录 `tickLower/tickUpper`，推导 `buyUpper=rangeLower`、`sellLower≈pHigh×(1-edge)`
3. 之后用户自己加仓；hook 不再 `modifyLiquidity`
4. `beforeSwap`：
   - `tick < buyUpper`：只允许卖 ETH 进池（`zeroForOne=true`）
   - `tick >= sellLower`：只允许买 ETH 出池（开区间向上）
   - 中间 → `SwapNotSupported`

已移除：`configureRange` / `placeBuy` / `placeSell`。

## 依赖

```bash
bash scripts/install-libs.sh
```

## 测试

```bash
forge test -vv
```

## 布局

| 路径 | 作用 |
|---|---|
| `src/EndsLimitHook.sol` | 记 range + beforeSwap 门控 |
| `src/libraries/BandTicks.sol` | range → bands / 流动性计算 |
| `test/EndsLimit.t.sol` | 记 range、中间拒单、方向门、开门外卖 |
| `test/ComparePaths.t.sol` | 中间 unsupported vs 满区间平滑卖 |
