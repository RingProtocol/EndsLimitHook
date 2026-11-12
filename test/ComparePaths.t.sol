// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {EndToEndBase} from "./EndToEndBase.sol";
import {BandTicks} from "../src/libraries/BandTicks.sol";

/// @notice EndsHook: buy-band funding at init; no-hook full-range still smooth-sells on its own pool.
contract ComparePathsTest is EndToEndBase {
    uint256 internal constant P_LOW = 2500;
    uint256 internal constant P_HIGH = 3500;
    uint256 internal constant ETH_BUDGET = 10 ether;

    function test_endsHook_initAtBuyAnchor_vs_fullRange() public {
        _setUpPool(P_LOW, P_HIGH);
        MockERC20(Currency.unwrap(currency1)).mint(address(this), 1e30);

        _addBuyBand(_buyLiq(50_000 ether));
        assertEq(_slotTick(), buyUpper, "hook pool starts at buy/middle boundary");

        // No-hook comparison pool at mid with full-range LP
        PoolKey memory fullKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            tickSpacing: SPACING,
            hooks: IHooks(address(0))
        });
        manager.initialize(fullKey, BandTicks.sqrtPriceFromHuman(3000));
        int24 lowT = BandTicks.floorToSpacing(BandTicks.tickFromHuman(P_LOW), SPACING);
        int24 highT = BandTicks.floorToSpacing(BandTicks.tickFromHuman(P_HIGH), SPACING);
        uint128 fullLiq = BandTicks.liquidityForAmount0(
            TickMath.getSqrtPriceAtTick(lowT), TickMath.getSqrtPriceAtTick(highT), ETH_BUDGET / 2
        );
        modifyLiquidityRouter.modifyLiquidity(
            fullKey,
            ModifyLiquidityParams({
                tickLower: lowT, tickUpper: highT, liquidityDelta: int256(uint256(fullLiq)), salt: bytes32("FULL")
            }),
            ""
        );
        swapRouter.swap(
            fullKey,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(5e24),
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(highT) + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        BalanceDelta rem = modifyLiquidityRouter.modifyLiquidity(
            fullKey,
            ModifyLiquidityParams({
                tickLower: lowT, tickUpper: highT, liquidityDelta: -int256(uint256(fullLiq)), salt: bytes32("FULL")
            }),
            ""
        );
        uint256 fullEthOut = rem.amount0() > 0 ? uint256(uint128(rem.amount0())) : 0;

        console2.log("EndsHook initTick", int256(_slotTick()));
        console2.log("FullRange ethOut after up-move", fullEthOut);
        assertTrue(fullEthOut < ETH_BUDGET);
    }
}
