# EndsLimitHook 验证报告（admin-locked range）

日期：2026-11-11

## 机制

- 管理员 `configureRange`（edge ≤2%，宽度 ≥5%，每池一次）
- 用户只能按锁定 ticks 加仓；任何人可 swap（中间拒单）
- 池 `initialize` 不限制

## forge

```bash
forge test -vv
```

**13/13 PASS**（含 owner/edge/width/RangeLocked/中间与卖区门控）。

规格：`docs/specs/2026-11-11-admin-range-design.md`
