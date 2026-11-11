// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// @notice Range → end-band tick helpers for EndsLimitHook.
/// @dev Human price = token1/token0 (both tokens same decimals).
library BandTicks {
    error BadSpacing();
    error BadWidth();
    error BandOrder();
    error BadEdge();
    error BadRange();

    /// @dev `price` is token1 per token0 in whole units, e.g. 2300.
    function sqrtPriceFromHuman(uint256 price) internal pure returns (uint160) {
        require(price > 0, "price=0");
        uint256 ratioX192 = price << 192;
        uint256 root = FixedPointMathLib.sqrt(ratioX192);
        require(root <= type(uint160).max, "sqrt overflow");
        return uint160(root);
    }

    function tickFromHuman(uint256 price) internal pure returns (int24) {
        return TickMath.getTickAtSqrtPrice(sqrtPriceFromHuman(price));
    }

    /// @dev Truncated human token1/token0 from a tick (same decimals assumed).
    function humanFromTick(int24 tick) internal pure returns (uint256) {
        uint160 sqrtP = TickMath.getSqrtPriceAtTick(tick);
        return FullMath.mulDiv(uint256(sqrtP), uint256(sqrtP), uint256(1) << 192);
    }

    function floorToSpacing(int24 tick, int24 spacing) internal pure returns (int24) {
        if (spacing <= 0) revert BadSpacing();
        int24 compressed = tick / spacing;
        if (tick < 0 && tick % spacing != 0) compressed--;
        return compressed * spacing;
    }

    /// @notice Derive buy/sell bands from user range `[pLow, pHigh]` and `edgeBps`.
    /// Buy:  `[pLow*(1-edge), pLow]`  e.g. 2450–2500 when pLow=2500, edge=2%.
    /// Sell: `[pHigh*(1-edge), pHigh]` e.g. 3430–3500 when pHigh=3500, edge=2%.
    function bandsFromRange(uint256 pLow, uint256 pHigh, uint16 edgeBps, int24 spacing)
        internal
        pure
        returns (int24 buyLower, int24 buyUpper, int24 sellLower, int24 sellUpper)
    {
        if (pHigh <= pLow) revert BadRange();
        if (edgeBps == 0 || edgeBps >= 5000) revert BadEdge(); // (0, 50%)

        buyUpper = floorToSpacing(tickFromHuman(pLow), spacing);
        sellUpper = floorToSpacing(tickFromHuman(pHigh), spacing);
        return bandsFromTicks(buyUpper, sellUpper, edgeBps, spacing);
    }

    /// @notice Derive end thresholds from an already-chosen tick range (no tick↔price round-trip on bounds).
    /// `buyUpper = rangeLower`, `sellUpper = rangeUpper`; edge only moves the inner thresholds.
    function bandsFromTicks(int24 rangeLower, int24 rangeUpper, uint16 edgeBps, int24 spacing)
        internal
        pure
        returns (int24 buyLower, int24 buyUpper, int24 sellLower, int24 sellUpper)
    {
        if (rangeLower >= rangeUpper) revert BadRange();
        if (edgeBps == 0 || edgeBps >= 5000) revert BadEdge();

        uint256 pLow = humanFromTick(rangeLower);
        uint256 pHigh = humanFromTick(rangeUpper);
        if (pLow == 0) pLow = 1;
        if (pHigh <= pLow) revert BadRange();

        uint256 buyPriceLow = (pLow * (10_000 - edgeBps)) / 10_000;
        if (buyPriceLow == 0) buyPriceLow = 1;
        uint256 sellPriceLow = (pHigh * (10_000 - edgeBps)) / 10_000;

        buyUpper = rangeLower;
        sellUpper = rangeUpper;
        buyLower = floorToSpacing(tickFromHuman(buyPriceLow), spacing);
        sellLower = floorToSpacing(tickFromHuman(sellPriceLow), spacing);
        if (buyUpper <= buyLower) buyLower = buyUpper - spacing;
        if (sellUpper <= sellLower) sellLower = sellUpper - spacing;

        assertEndsOnly(buyLower, buyUpper, sellLower, sellUpper);
    }

    function assertEndsOnly(int24 buyLower, int24 buyUpper, int24 sellLower, int24 sellUpper) internal pure {
        if (!(buyLower < buyUpper && sellLower < sellUpper && buyUpper <= sellLower)) revert BandOrder();
    }

    function liquidityForAmount0(uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, uint256 amount0)
        internal
        pure
        returns (uint128)
    {
        if (sqrtPriceAX96 > sqrtPriceBX96) (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        uint256 intermediate = FullMath.mulDiv(sqrtPriceAX96, sqrtPriceBX96, 1 << 96);
        uint256 liq = FullMath.mulDiv(amount0, intermediate, sqrtPriceBX96 - sqrtPriceAX96);
        require(liq <= type(uint128).max, "L overflow");
        return uint128(liq);
    }

    function liquidityForAmount1(uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, uint256 amount1)
        internal
        pure
        returns (uint128)
    {
        if (sqrtPriceAX96 > sqrtPriceBX96) (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        uint256 liq = FullMath.mulDiv(amount1, 1 << 96, sqrtPriceBX96 - sqrtPriceAX96);
        require(liq <= type(uint128).max, "L overflow");
        return uint128(liq);
    }
}
