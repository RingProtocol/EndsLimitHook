#!/usr/bin/env node
/**
 * RingLowHigher 设计文档的算例计算器（可复算，不靠手算）。
 *
 * 场景：100 万美元，50 万放 v4 LP [P_low, P_high]，50 万放 GridVault 同区间。
 *
 * 关键约定（与 design.md §2 一致）：
 *   - mid = sqrt(P_low * P_high)，买卖腿分界：mid 之上只卖、mid 之下只买
 *   - 每侧 K 档，delta 由 band 反解：delta = (P_high/mid)^(1/K) - 1
 *     ⇒ 两侧档位精确对齐边界，不会出现"被钳"的退化
 *   - 容量闭合：mid 上持 e0 = K*q 的 ETH、c0 = q*sum(buyLevels) 的现金
 *     ⇒ P_high 处 ETH 清零（到顶全卖）；P_low 处现金清零、ETH = 2*e0（到底买满）
 *
 * 用法：node RingLowHigher/calc.mjs
 */

const P_LOW = 2500;
const P_HIGH = 2800;
const CAPITAL = 500_000; // 单个桶的美元资金

const mid = Math.sqrt(P_LOW * P_HIGH);
const sqA = Math.sqrt(P_LOW);
const sqB = Math.sqrt(P_HIGH);
const sqMid = Math.sqrt(mid);

const f = (v, d = 2) => v.toLocaleString("en-US", { minimumFractionDigits: d, maximumFractionDigits: d });
const pct = (v, d = 2) => `${(v * 100).toFixed(d)}%`;

function ladder(K) {
  const delta = Math.pow(P_HIGH / mid, 1 / K) - 1;
  const sell = [];
  const buy = [];
  for (let j = 1; j <= K; j++) {
    sell.push(mid * Math.pow(1 + delta, j));
    buy.push(mid / Math.pow(1 + delta, j));
  }
  return { delta, sell, buy };
}

function capacity(K, capital = CAPITAL) {
  const { delta, sell, buy } = ladder(K);
  const sumBuy = buy.reduce((a, b) => a + b, 0);
  const sumSell = sell.reduce((a, b) => a + b, 0);
  const q = capital / (K * mid + sumBuy); // 每档 q 枚 ETH
  const e0 = K * q;
  const c0 = q * sumBuy;
  const grossPerOscillation = q * (sumSell - sumBuy); // 一轮完整摆动（上+下）毛利
  return { K, delta, sell, buy, q, e0, c0, sumSell, sumBuy, grossPerOscillation };
}

// ---- v4 LP 桶（同区间，mid 上精确 50/50） ----
// 在 mid 上：x = capital/2/mid 枚 ETH，y = capital/2 美元
const lpX0 = CAPITAL / 2 / mid;
const L = CAPITAL / 2 / (sqMid - sqA); // 由 y0 = L*(sqMid - sqA)
if (Math.abs(L * (1 / sqMid - 1 / sqB) - lpX0) > 0.5) {
  console.error("LP 自检失败：x 侧与 y 侧不一致");
}

function lpValueAt(P) {
  if (P <= P_LOW) return L * (1 / sqA - 1 / sqB) * P;
  if (P >= P_HIGH) return L * (sqB - sqA);
  const x = L * (1 / Math.sqrt(P) - 1 / sqB);
  const y = L * (Math.sqrt(P) - sqA);
  return x * P + y;
}

// ---- GridVault 桶 ----
function gridValueAt(k, P, phase = "flat") {
  const { e0, c0, sell, buy, q } = capacity(k);
  if (phase === "up") {
    // 单调上行：上侧全部卖出，其余情况按是否触及档位
    let e = e0;
    let c = c0;
    for (let j = 0; j < sell.length; j++) {
      if (P >= sell[j]) { e -= q; c += q * sell[j]; }
    }
    return e * P + c;
  }
  if (phase === "down") {
    let e = e0;
    let c = c0;
    for (let j = 0; j < buy.length; j++) {
      if (P <= buy[j]) { c -= q * buy[j]; e += q; }
    }
    return e * P + c;
  }
  return e0 * P + c0;
}

// ================= 输出 =================
console.log(`band [${P_LOW}, ${P_HIGH}]  W=${pct(P_HIGH / P_LOW - 1)}  mid=${f(mid, 2)}  每桶 $${f(CAPITAL, 0)}`);
console.log("");

console.log("== 档位反解（delta 由 K 决定，两侧精确对齐边界）==");
for (let K = 1; K <= 4; K++) {
  const c = capacity(K);
  console.log(
    `K=${K}  delta=${pct(c.delta, 4)}  ` +
    `卖 [${c.sell.map((v) => f(v, 1)).join(", ")}]  ` +
    `买 [${c.buy.map((v) => f(v, 1)).join(", ")}]`
  );
}
console.log("");

console.log("== 容量（K=3）==");
{
  const c = capacity(3);
  console.log(`q/档          = ${f(c.q, 4)} ETH`);
  console.log(`e0 (mid 上 ETH) = ${f(c.e0, 4)} ETH (= ${f(c.e0 * mid, 0)} USD @mid)`);
  console.log(`c0 (mid 上现金) = ${f(c.c0, 0)} USD`);
  console.log(`合计 @mid     = ${f(c.e0 * mid + c.c0, 0)} USD`);
  console.log(`@P_low 持仓   = ${f(2 * c.e0, 4)} ETH, 现金 0  → ${f(2 * c.e0 * P_LOW, 0)} USD`);
  console.log(`@P_high 持仓  = 0 ETH, 现金 ${f(c.c0 + c.q * c.sumSell, 0)} USD`);
  console.log("");
  console.log("每档一轮毛利：");
  let tot = 0;
  for (let j = 0; j < c.sell.length; j++) {
    const d = c.sell[j] / c.buy[j] - 1;
    const usd = c.q * (c.sell[j] - c.buy[j]);
    tot += usd;
    console.log(`  j=${j + 1}  买 ${f(c.buy[j], 1)} → 卖 ${f(c.sell[j], 1)}  Δ=${pct(d)}  毛利 $${f(usd, 0)}`);
  }
  console.log(`  合计一轮完整摆动毛利 = $${f(tot, 0)}  = ${pct(tot / CAPITAL)} 资本`);
}
console.log("");

console.log("== LP 桶（同区间，零费用口径）==");
console.log(`L = ${f(L, 0)}   mid 上 = ${f(lpX0, 2)} ETH + $${f(CAPITAL / 2, 0)}`);
for (const P of [2300, 2500, 2600, 2645.75, 2700, 2800, 3000]) {
  console.log(`  P=${f(P, 2)}  LP=$${f(lpValueAt(P), 0)}  (${pct(lpValueAt(P) / CAPITAL - 1)})`);
}
console.log("");

console.log("== 平均卖价（mid → 2800，全部换成 USDC）==");
{
  const c = capacity(3);
  const gridProceeds = c.q * c.sumSell;
  const lpProceeds = lpValueAt(P_HIGH) - CAPITAL / 2;
  console.log(`Grid: 卖 ${f(c.e0, 2)} ETH 得 $${f(gridProceeds, 0)}  均价 ${f(gridProceeds / c.e0, 1)}`);
  console.log(`LP  : 卖 ${f(lpX0, 2)} ETH 得 $${f(lpProceeds, 0)}  均价 ${f(lpProceeds / lpX0, 1)}`);
  console.log(`价差 ${pct(gridProceeds / c.e0 / (lpProceeds / lpX0) - 1)} = 段内凸性损耗`);
}
console.log("");

console.log("== 路径对照（起点都 = mid，各 50 万，零费用）==");
const paths = [
  ["上行停在 2800", 2800, "up"],
  ["下行停在 2500", 2500, "down"],
  ["突破上行停在 3000", 3000, "up"],
  ["突破下行停在 2300", 2300, "down"],
  ["区间内不动（停在 mid）", mid, "flat"],
];
for (const [name, P, phase] of paths) {
  const g = gridValueAt(3, P, phase);
  const l = lpValueAt(P);
  console.log(
    `${name.padEnd(22)} Grid=$${f(g, 0)} (${pct(g / CAPITAL - 1)})  ` +
    `LP=$${f(l, 0)} (${pct(l / CAPITAL - 1)})  差=$${f(g - l, 0)}`
  );
}
console.log("");

console.log("== 一轮完整摆动 = 上行全卖再下行全买，回到 mid ==");
{
  const c = capacity(3);
  const cUp = c.c0 + c.q * c.sumSell;
  const cBack = cUp - c.q * c.sumBuy;
  const v = c.e0 * mid + cBack;
  console.log(`Grid: 卖出后现金 $${f(cUp, 0)} → 买回后现金 $${f(cBack, 0)} → 回到 mid 总值 $${f(v, 0)}  (${pct(v / CAPITAL - 1)})`);
  console.log(`LP  : 回到 mid 总值 $${f(lpValueAt(mid), 0)}  (${pct(lpValueAt(mid) / CAPITAL - 1)})  ← 固定仓位价值只取决于 P`);
  console.log(`差  : $${f(v - lpValueAt(mid), 0)} = ${pct((v - lpValueAt(mid)) / CAPITAL)} 资本`);
  console.log("");
  console.log(`LP 追平所需的费收 = ${pct((v - lpValueAt(mid)) / CAPITAL)} 资本`);
  console.log(`按 0.05% 费率 ⇒ 需要 (本段成交量 / 本段名义) × 流动性份额 ≥ ${f(((v - lpValueAt(mid)) / CAPITAL) / 0.0005, 0)}`);
}
