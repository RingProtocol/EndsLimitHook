// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// @notice Range → end-band tick helpers for EndsLimitHook.
/// @dev Human price = token1/token0 (both tokens same decimals).
library BandTicks {
    uint16 internal constant MAX_EDGE_BPS = 200; // 2%
    uint16 internal constant MIN_RANGE_BPS = 500; // 5% width: pHigh/pLow >= 1.05

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

    /// @notice Require `pHigh/pLow >= 1 + MIN_RANGE_BPS/10000` (5%).
    function assertMinWidth(uint256 pLow, uint256 pHigh) internal pure {
        if (pLow == 0 || pHigh <= pLow) revert BadRange();
        if (pHigh * 10_000 < pLow * (10_000 + MIN_RANGE_BPS)) revert BadWidth();
    }

    function assertEdge(uint16 edgeBps) internal pure {
        if (edgeBps == 0 || edgeBps > MAX_EDGE_BPS) revert BadEdge();
    }

    /// @notice Derive buy/sell bands from user range `[pLow, pHigh]` and `edgeBps`.
    function bandsFromRange(uint256 pLow, uint256 pHigh, uint16 edgeBps, int24 spacing)
        internal
        pure
        returns (int24 buyLower, int24 buyUpper, int24 sellLower, int24 sellUpper)
    {
        assertMinWidth(pLow, pHigh);
        assertEdge(edgeBps);

        buyUpper = floorToSpacing(tickFromHuman(pLow), spacing);
        sellUpper = floorToSpacing(tickFromHuman(pHigh), spacing);
        return bandsFromTicks(buyUpper, sellUpper, edgeBps, spacing);
    }

    /// @notice Derive end thresholds from tick range. `buyUpper = rangeLower`, `sellUpper = rangeUpper`.
    function bandsFromTicks(int24 rangeLower, int24 rangeUpper, uint16 edgeBps, int24 spacing)
        internal
        pure
        returns (int24 buyLower, int24 buyUpper, int24 sellLower, int24 sellUpper)
    {
        if (rangeLower >= rangeUpper) revert BadRange();
        assertEdge(edgeBps);

        uint256 pLow = humanFromTick(rangeLower);
        uint256 pHigh = humanFromTick(rangeUpper);
        if (pLow == 0) pLow = 1;
        assertMinWidth(pLow, pHigh);

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
