// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Test.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {EndToEndBase} from "./EndToEndBase.sol";

/// @notice Flash-loan considerations (see docs/specs/2026-11-12-flash-loans.md).
/// Flash only removes the capital constraint; paths are the same as same-tx atomic swaps.
contract FlashTest is EndToEndBase {
    uint256 internal constant P_LOW = 2500;
    uint256 internal constant P_HIGH = 3500;

    function setUp() public {
        _setUpPool(P_LOW, P_HIGH);
    }

    /// Cross empty middle in one tx: ETH fills only in sell band; effective price >> 2550.
    function test_atomic_crossMiddle_fillsOnlyInSellBand_notAt2550() public {
        _addBuyBand(_buyLiq(10_000 ether));
        _addSellBand(_sellLiq(5 ether));

        uint256 quoteBefore = MockERC20(Currency.unwrap(currency1)).balanceOf(address(this));
        uint256 ethBefore = MockERC20(Currency.unwrap(currency0)).balanceOf(address(this));

        uint256 quoteIn = 500 ether;
        _swap(false, -int256(quoteIn), TickMath.getSqrtPriceAtTick(sellUpper) + 1);

        assertTrue(_slotTick() >= sellLower, "landed in sell band");

        uint256 ethOut = MockERC20(Currency.unwrap(currency0)).balanceOf(address(this)) - ethBefore;
        uint256 quoteSpent = quoteBefore - MockERC20(Currency.unwrap(currency1)).balanceOf(address(this));
        assertTrue(ethOut > 0, "got ETH");
        assertTrue(quoteSpent > 0, "spent quote");

        uint256 eff = quoteSpent / ethOut; // 18/18 decimals → human USDT per ETH
        assertTrue(eff > 3000, "not filled at ~2550");
        console2.log("effectiveQuotePerEth", eff);
        console2.log("ethOut", ethOut);
    }

    /// Same-tx round trip (flash-equivalent): buy on sell band, dump into buy band → lose quote.
    function test_sameTx_roundTrip_noFreeQuote() public {
        _addBuyBand(_buyLiq(80_000 ether));
        _addSellBand(_sellLiq(5 ether));

        uint256 quoteBefore = MockERC20(Currency.unwrap(currency1)).balanceOf(address(this));
        uint256 ethBefore = MockERC20(Currency.unwrap(currency0)).balanceOf(address(this));

        _swap(false, -int256(20_000 ether), TickMath.getSqrtPriceAtTick(sellUpper) + 1);
        uint256 ethGained = MockERC20(Currency.unwrap(currency0)).balanceOf(address(this)) - ethBefore;
        assertTrue(ethGained > 0);

        _swap(true, -int256(ethGained), TickMath.getSqrtPriceAtTick(buyLower));

        uint256 quoteAfter = MockERC20(Currency.unwrap(currency1)).balanceOf(address(this));
        assertTrue(quoteAfter < quoteBefore, "must lose quote on round trip");
        console2.log("quoteLost", quoteBefore - quoteAfter);
    }

    /// Flash/atomic attacker still cannot add middle LP.
    function test_cannotAddMiddleLiquidity_inAttackTx() public {
        vm.expectRevert();
        modifyLiquidityRouter.modifyLiquidity(
            endsKey,
            ModifyLiquidityParams({
                tickLower: buyUpper,
                tickUpper: buyUpper + SPACING * 2,
                liquidityDelta: 1e18,
                salt: bytes32("FLASHMID")
            }),
            ""
        );
    }
}
