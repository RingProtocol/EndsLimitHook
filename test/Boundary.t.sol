// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Test.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {EndToEndBase} from "./EndToEndBase.sol";

/// @notice Boundary cases from product review:
/// - low zone: user sells ETH, LP buys ETH
/// - buy-band USDT exhaust → price at ~pLow (2500), not stuck at init 2550
/// - sell-band ETH idle at 2550; first cross fills from ~sellLower (3430), not 2550
/// - empty middle: large swap may jump; middle is NOT a swap-forbidden zone
/// - starting just inside buy band, huge swap into/through middle still succeeds
contract BoundaryTest is EndToEndBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 internal constant P_LOW = 2500;
    uint256 internal constant P_HIGH = 3500;

    function setUp() public {
        _setUpPool(P_LOW, P_HIGH);
    }

    /// Init is buyUpper (~2550), not mid 3000; sell-band ETH is inventoried but inactive.
    function test_boundary_atInit_buyBandQuoteHeavy_sellBandIdleEth() public {
        assertEq(_slotTick(), buyUpper, "init at buy/middle boundary");
        assertTrue(buyUpper < sellLower, "empty middle gap exists");

        _addBuyBand(_buyLiq(20_000 ether));
        _addSellBand(_sellLiq(5 ether));

        // Both positions exist; price still at buyUpper so sell band is below-range (idle ETH).
        assertTrue(_buyPosLiq() > 0 && _sellPosLiq() > 0);
        assertEq(_slotTick(), buyUpper, "price unchanged by adding out-of-range sell LP");
        console2.log("initTick", int256(_slotTick()));
        console2.log("sellLower", int256(sellLower));
    }

    /// Users sell ETH into buy band until USDT is gone → price at/below buyLower (~2500), not 2550.
    function test_boundary_buyBand_usdtExhausted_priceAtLowerNotInit() public {
        _addBuyBand(_buyLiq(20_000 ether));

        assertEq(_slotTick(), buyUpper, "start at init ~2550");

        // Exact-in dump of token0 (ETH): LP buys ETH until band is traversed.
        _swap(true, -int256(1e24), TickMath.getSqrtPriceAtTick(buyLower));

        int24 tick = _slotTick();
        assertTrue(tick <= buyLower, "USDT exhausted => at/below buyLower ~2500");
        assertTrue(tick < buyUpper, "must have left init 2550");
        console2.log("afterExhaustTick", int256(tick));
        console2.log("buyLower", int256(buyLower));
        console2.log("buyUpper", int256(buyUpper));
    }

    /// After buy band is empty, further selling ETH has no strategy LP below → swap reverts.
    function test_boundary_belowBuyBand_noLiquidity_reverts() public {
        _addBuyBand(_buyLiq(5_000 ether));
        _swap(true, -int256(1e24), TickMath.MIN_SQRT_PRICE + 1);
        assertTrue(_slotTick() <= buyLower, "band drained");

        vm.expectRevert();
        _swap(true, -int256(1e18), TickMath.MIN_SQRT_PRICE + 1);
    }

    /// One upward swap from 2550 with only sell-band LP jumps empty middle; fills start at sell zone.
    function test_boundary_sellBand_notFilledAt2550_jumpStartsAtSellLower() public {
        _addSellBand(_sellLiq(5 ether));
        // No buy-band LP — middle+buy side empty of strategy liquidity.

        int24 tickBefore = _slotTick();
        assertEq(tickBefore, buyUpper, "start ~2550");
        assertTrue(tickBefore < sellLower, "sell band still inactive");

        _swap(false, -int256(1e24), TickMath.getSqrtPriceAtTick(sellUpper) + 1);

        int24 tickAfter = _slotTick();
        assertTrue(tickAfter >= sellLower, "first liquidity hit is sell band, not mid prices");
        // Single swap leaped the gap: never "trades through" 2551..sellLower with LP.
        assertTrue(tickAfter > tickBefore + int24(100), "moved far across empty middle");
        console2.log("tickBefore", int256(tickBefore));
        console2.log("tickAfter", int256(tickAfter));
        console2.log("sellLower", int256(sellLower));
    }

    /// Huge swap starting at buyUpper (not in a swap-ban): may cross middle; must succeed (middle not forbidden).
    function test_boundary_largeSwap_fromInit_throughMiddle_succeeds() public {
        _addBuyBand(_buyLiq(10_000 ether));
        _addSellBand(_sellLiq(5 ether));

        assertEq(_slotTick(), buyUpper);
        // "100万级" exact-in quote→ETH across gap — beforeSwap only sees start tick; must not revert for landing in middle.
        _swap(false, -int256(1e26), TickMath.getSqrtPriceAtTick(sellUpper) + 1);
        assertTrue(_slotTick() >= sellLower, "landed in/above sell band");
    }

    /// Start just inside buy band (tick < buyUpper), then large up-swap through middle still OK.
    function test_boundary_startJustInsideBuyBand_largeUpCross_succeeds() public {
        _addBuyBand(_buyLiq(50_000 ether));
        _addSellBand(_sellLiq(5 ether));

        // Nudge into buy band (user sells a bit of ETH).
        _swap(true, -int256(1e18), TickMath.getSqrtPriceAtTick(buyLower));
        assertTrue(_slotTick() < buyUpper, "now strictly inside buy band");

        // Large buy-ETH order: starts legal, crosses empty middle, hits sell band.
        _swap(false, -int256(1e26), TickMath.getSqrtPriceAtTick(sellUpper) + 1);
        assertTrue(_slotTick() >= sellLower, "crossed middle from inside buy band");
    }

    /// Middle ticks cannot receive LP (forbidden for add, not for swap).
    function test_boundary_rejectLiquidityInMiddle() public {
        int24 midLow = buyUpper;
        int24 midHigh = buyUpper + SPACING * 2;
        if (midHigh > sellLower) midHigh = sellLower;
        assertTrue(midHigh > midLow, "need a middle span");

        vm.expectRevert();
        modifyLiquidityRouter.modifyLiquidity(
            endsKey,
            ModifyLiquidityParams({
                tickLower: midLow, tickUpper: midHigh, liquidityDelta: 1e18, salt: bytes32("MID")
            }),
            ""
        );
    }

    /// Without sell-band LP, buying ETH from 2550 cannot pull sell-band inventory (there is none):
    /// empty-middle may move sqrtPrice toward the limit with ~0 ETH out — not a 2550 ask fill.
    function test_boundary_noSellLp_upSwap_givesNoEthInventory() public {
        _addBuyBand(_buyLiq(20_000 ether));
        assertEq(_slotTick(), buyUpper);

        uint256 ethBefore = MockERC20(Currency.unwrap(currency0)).balanceOf(address(this));
        // Empty gap: v4 may walk sqrtPrice to the limit with zero fills.
        _swap(false, -int256(1e20), TickMath.getSqrtPriceAtTick(sellUpper) + 1);
        uint256 ethAfter = MockERC20(Currency.unwrap(currency0)).balanceOf(address(this));

        assertTrue(ethAfter <= ethBefore + 1, "no sell LP => no ETH paid out (price jump != fill)");
        console2.log("ethBefore", ethBefore);
        console2.log("ethAfter", ethAfter);
        console2.log("tickAfter", int256(_slotTick()));
    }

    /// After exhausting buy band to ~2500, reverse (user buys ETH back) can climb toward buyUpper (reverse fill ≤ edge).
    function test_boundary_reverseFill_buyBand_climbsTowardInit() public {
        _addBuyBand(_buyLiq(30_000 ether));
        _swap(true, -int256(1e24), TickMath.getSqrtPriceAtTick(buyLower));
        assertTrue(_slotTick() <= buyLower, "fully converted to ETH side");

        _swap(false, -int256(1e24), TickMath.getSqrtPriceAtTick(buyUpper) + 1);
        assertTrue(_slotTick() >= buyLower, "climbed within/at buy band");
        assertTrue(_slotTick() <= buyUpper, "cannot invent mid-range LP; stops by buyUpper without sell LP");
    }
}
