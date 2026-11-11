# EndsLimitHook 验证报告（gate-only / 首次加仓记 range）

日期：2026-11-11（机制已改为：无 `configureRange`，首次 `addLiquidity` 记 range，两端开门外）

## 机制摘要

- 构造：`edgeBps=200`
- 首次用户加仓 `[2500,3500]` ticks → 记录 range；`buyUpper=rangeLower`，`sellLower≈3430`
- `beforeSwap`：`tick < buyUpper` 只许卖 ETH 进；`tick >= sellLower` 只许买 ETH 出（含 4000+）；中间 `SwapNotSupported`
- Hook 不调用 `modifyLiquidity`

## forge 单测

```bash
forge test -vv
```

覆盖：记 range、中间拒单、卖区对/错方向、买侧放行、**上沿开门外（3600/4000）仍可卖向**。

## Anvil

```bash
anvil --port 8545
FOUNDRY_PROFILE=script forge script script/DeployAnvil.s.sol:DeployAnvil --rpc-url http://127.0.0.1:8545 --broadcast
FOUNDRY_PROFILE=script bash scripts/anvil-swap-verify.sh
```

早期 anvil 报告中的 status=0 tx 对应旧版 `configureRange`+自挂仓流程；本版请以重新跑脚本的 receipt 为准。
