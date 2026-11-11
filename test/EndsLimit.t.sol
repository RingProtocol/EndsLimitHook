// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Test.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {EndToEndBase} from "./EndToEndBase.sol";
import {BandTicks} from "../src/libraries/BandTicks.sol";

contract EndsLimitTest is EndToEndBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 internal constant P_LOW = 2500;
    uint256 internal constant P_HIGH = 3500;
    uint256 internal constant P_MID = 3000;

    function setUp() public {
        _setUpPool(P_LOW, P_MID, P_HIGH);
    }

    function test_firstAddRecordsRange_edge2pct() public {
        _addUserRange(_rangeLiqForEth(5 ether));

        (
            int24 rl,
            int24 ru,
            uint16 edge,
            int24 bl,
            int24 bu,
            int24 sl,
            int24 su,
            bool configured
        ) = hook.bands(endsKey.toId());

        (int24 eBl, int24 eBu, int24 eSl, int24 eSu) =
            BandTicks.bandsFromTicks(rangeLower, rangeUpper, EDGE_BPS, SPACING);

        assertTrue(configured, "configured");
        assertEq(rl, rangeLower, "rangeLower");
        assertEq(ru, rangeUpper, "rangeUpper");
        assertEq(edge, EDGE_BPS, "edge");
        assertEq(bu, rangeLower, "buyUpper == rangeLower");
        assertEq(su, rangeUpper, "sellUpper == rangeUpper");
        assertEq(bl, eBl, "buyLower");
        assertEq(bu, eBu, "buyUpper");
        assertEq(sl, eSl, "sellLower");
        assertEq(su, eSu, "sellUpper");
        assertTrue(bu <= sl, "middle empty");
        console2.log("buyLower", int256(bl));
        console2.log("buyUpper", int256(bu));
        console2.log("sellLower", int256(sl));
        console2.log("sellUpper", int256(su));
    }

    function test_middleSwapReverts_quoteUnsupported() public {
        _addUserRange(_rangeLiqForEth(5 ether));

        vm.expectRevert();
        _swap(false, -1e18, TickMath.getSqrtPriceAtTick(sellLower));
    }

    function test_sellZone_wrongDirectionReverts() public {
        _setUpPool(P_LOW, 3450, P_HIGH);
        _addUserRange(_rangeLiqForEth(5 ether));

        vm.expectRevert();
        _swap(true, -1e17, TickMath.MIN_SQRT_PRICE + 1);
    }

    function test_sellZone_rightDirectionFillsFromUniswapFlow() public {
        _setUpPool(P_LOW, 3450, P_HIGH);
        uint128 liq = _rangeLiqForEth(5 ether);
        _addUserRange(liq);

        _swap(false, -1e20, TickMath.getSqrtPriceAtTick(rangeUpper) + 1);
        assertEq(_userPosLiq(), liq, "user LP not removed by hook");
    }

    function test_buySide_rightDirectionAllowed() public {
        _setUpPool(P_LOW, 2470, P_HIGH);
        uint128 liq = _rangeLiqForEth(5 ether);
        _addUserRange(liq);

        // Below rangeLower the [2500,3500] position is quote-only — add a thin buy-side band for fill.
        (int24 bl, int24 bu,,) = BandTicks.bandsFromTicks(rangeLower, rangeUpper, EDGE_BPS, SPACING);
        modifyLiquidityRouter.modifyLiquidity(
            endsKey,
            ModifyLiquidityParams({
                tickLower: bl,
                tickUpper: bu,
                liquidityDelta: int256(
                    uint256(
                        BandTicks.liquidityForAmount1(
                            TickMath.getSqrtPriceAtTick(bl), TickMath.getSqrtPriceAtTick(bu), 10_000 ether
                        )
                    )
                ),
                salt: bytes32("BUY")
            }),
            ""
        );

        _swap(true, -1e18, TickMath.getSqrtPriceAtTick(bl));
        assertEq(_userPosLiq(), liq, "range LP kept");
    }

    function test_aboveRange_openEndedSellAllowed() public {
        _setUpPool(P_LOW, 3600, P_HIGH);
        _addUserRange(_rangeLiqForEth(5 ether));

        int24 hi = BandTicks.floorToSpacing(BandTicks.tickFromHuman(4200), SPACING);
        modifyLiquidityRouter.modifyLiquidity(
            endsKey,
            ModifyLiquidityParams({
                tickLower: rangeUpper,
                tickUpper: hi,
                liquidityDelta: int256(
                    uint256(
                        BandTicks.liquidityForAmount0(
                            TickMath.getSqrtPriceAtTick(rangeUpper), TickMath.getSqrtPriceAtTick(hi), 2 ether
                        )
                    )
                ),
                salt: bytes32("HI")
            }),
            ""
        );

        _swap(false, -1e18, TickMath.getSqrtPriceAtTick(hi) + 1);
        assertTrue(_slotTick() >= sellLower, "still in open sell region");
    }

    function test_aboveRange_wrongDirectionReverts() public {
        _setUpPool(P_LOW, 3600, P_HIGH);
        _addUserRange(_rangeLiqForEth(5 ether));

        vm.expectRevert();
        _swap(true, -1e17, TickMath.MIN_SQRT_PRICE + 1);
    }
}
