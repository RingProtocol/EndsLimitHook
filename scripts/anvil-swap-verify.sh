#!/usr/bin/env bash
# Deploy fixtures on anvil, then cast-send mid/ends swaps. Mid & wrong-dir use --gas-limit so
# anvil mines status=0 (failed) receipts.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RPC="${RPC_URL:-http://127.0.0.1:8545}"
PK="${PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"
LOG="$ROOT/broadcast/anvil-swap-verify.log"
REPORT_SNIP="$ROOT/broadcast/anvil-swap-tx-summary.md"
cd "$ROOT"

if ! curl -s -X POST "$RPC" -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}' | grep -q result; then
  echo "anvil not running on $RPC" >&2
  exit 1
fi

echo "=== deploy fixtures ==="
forge script script/AnvilSwapFixtures.s.sol:AnvilSwapFixtures --rpc-url "$RPC" --broadcast -vv \
  | tee "$LOG"

pick() { rg -o "FIX_${1}_$2[[:space:]]+0x[0-9a-fA-F]+" "$LOG" | awk '{print $2}' | tail -1; }
pick_u() { rg -o "FIX_${1}_$2[[:space:]]+[0-9]+" "$LOG" | awk '{print $2}' | tail -1; }

MID_CALLER=$(pick mid caller)
SELL_CALLER=$(pick sell caller)
BUY_CALLER=$(pick buy caller)
C0=$(pick mid c0)
C1=$(pick mid c1)
MID_HOOK=$(pick mid hook)
SELL_HOOK=$(pick sell hook)
BUY_HOOK=$(pick buy hook)
MID_SELL_LIM=$(pick_u mid sellLim)
SELL_SELL_LIM=$(pick_u sell sellLim)
BUY_BUY_LIM=$(pick_u buy buyLim)
MIN_SQRT=4295128740

echo "mid_caller=$MID_CALLER sell_caller=$SELL_CALLER buy_caller=$BUY_CALLER"
echo "limits mid_sell=$MID_SELL_LIM sell_sell=$SELL_SELL_LIM buy_buy=$BUY_BUY_LIM"

KEY_MID="($C0,$C1,3000,60,$MID_HOOK)"
KEY_SELL="($C0,$C1,3000,60,$SELL_HOOK)"
KEY_BUY="($C0,$C1,3000,60,$BUY_HOOK)"

send_fail() {
  local label="$1"; shift
  local out hash status
  set +e
  out=$(cast send "$@" --private-key "$PK" --rpc-url "$RPC" --gas-limit 2000000 2>&1)
  set -e
  hash=$(echo "$out" | rg -o 'transactionHash[[:space:]]+0x[0-9a-fA-F]+' | awk '{print $2}' | head -1)
  status=$(echo "$out" | rg -o 'status[[:space:]]+[0-9]+' | awk '{print $2}' | head -1)
  echo "$label hash=$hash status=$status"
  echo "| $label | \`$hash\` | $status (failed expected) |" >> "$REPORT_SNIP"
}

send_ok() {
  local label="$1"; shift
  local out hash status
  out=$(cast send "$@" --private-key "$PK" --rpc-url "$RPC" 2>&1)
  hash=$(echo "$out" | rg -o 'transactionHash[[:space:]]+0x[0-9a-fA-F]+' | awk '{print $2}' | head -1)
  status=$(echo "$out" | rg -o 'status[[:space:]]+[0-9]+' | awk '{print $2}' | head -1)
  echo "$label hash=$hash status=$status"
  echo "| $label | \`$hash\` | $status (success expected) |" >> "$REPORT_SNIP"
}

: > "$REPORT_SNIP"
echo "## Anvil swap txs (cast)" >> "$REPORT_SNIP"
echo "" >> "$REPORT_SNIP"
echo "| case | tx | status |" >> "$REPORT_SNIP"
echo "|---|---|---|" >> "$REPORT_SNIP"

# Mid @3000: any swap should fail SwapNotSupported
send_fail "mid_swap_unsupported" \
  "$MID_CALLER" "swap((address,address,uint24,int24,address),bool,int256,uint160)" \
  "$KEY_MID" false -1000000000000000000 "$MID_SELL_LIM"

# Sell zone @3450: wrong dir fail, right dir ok
send_fail "sell_wrong_direction" \
  "$SELL_CALLER" "swap((address,address,uint24,int24,address),bool,int256,uint160)" \
  "$KEY_SELL" true -100000000000000000 "$MIN_SQRT"

send_ok "sell_right_direction_buy_eth" \
  "$SELL_CALLER" "swap((address,address,uint24,int24,address),bool,int256,uint160)" \
  "$KEY_SELL" false -1000000000000000000 "$SELL_SELL_LIM"

# Buy zone @2470: right dir ok
send_ok "buy_right_direction_sell_eth" \
  "$BUY_CALLER" "swap((address,address,uint24,int24,address),bool,int256,uint160)" \
  "$KEY_BUY" true -1000000000000000000 "$BUY_BUY_LIM"

echo "Wrote $REPORT_SNIP"
cat "$REPORT_SNIP"
