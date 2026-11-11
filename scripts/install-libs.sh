#!/usr/bin/env bash
# Install Foundry libs at the same pins as RingHook/VolatilePairHook.
# Drops nested .git dirs so they are not nested repos inside ai-cxo.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/lib"
mkdir -p "$DEST"

clone_rev() {
  local name="$1" url="$2" rev="$3"
  echo "=== $name @ $rev ==="
  rm -rf "$DEST/$name"
  git clone --filter=blob:none --no-checkout "$url" "$DEST/$name"
  git -C "$DEST/$name" fetch --depth 1 origin "$rev"
  git -C "$DEST/$name" checkout "$rev"
  rm -rf "$DEST/$name/.git"
}

clone_rev forge-std https://github.com/foundry-rs/forge-std.git 60acb7aaadcce2d68e52986a0a66fe79f07d138f
clone_rev v4-core https://github.com/Uniswap/v4-core.git d153b048868a60c2403a3ef5b2301bb247884d46
clone_rev v4-periphery https://github.com/Uniswap/v4-periphery.git 07336f2144f522874e2c3c85e04d1d3f8d5fa471
clone_rev solady https://github.com/Vectorized/solady.git acd959aa4bd04720d640bf4e6a5c71037510cc4b

echo "=== nested solmate under v4-core ==="
rm -rf "$DEST/v4-core/lib/solmate"
git clone --filter=blob:none --depth 1 https://github.com/transmissions11/solmate.git "$DEST/v4-core/lib/solmate"
rm -rf "$DEST/v4-core/lib/solmate/.git"

echo "libs ready under $DEST"
