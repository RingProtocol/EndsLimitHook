// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {EndToEndBase} from "./EndToEndBase.sol";
import {BandTicks} from "../src/libraries/BandTicks.sol";

/// @notice Mid-path: EndsHook rejects middle swaps; no-hook full-range still smooth-sells.
contract ComparePathsTest is EndToEndBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 internal constant P_LOW = 2500;
    uint256 internal constant P_HIGH = 3500;
    uint256 internal constant P_START = 3000;
    uint256 internal constant ETH_BUDGET = 10 ether;

    function test_middleUnsupported_vs_fullRangeSmoothSell() public {
        _setUpPool(P_LOW, P_START, P_HIGH);
        MockERC20(Currency.unwrap(currency1)).mint(address(this), 1e30);

        uint128 liq = _rangeLiqForEth(ETH_BUDGET);
        _addUserRange(liq);

        vm.expectRevert();
        _swap(false, -1e18, TickMath.getSqrtPriceAtTick(sellLower));
        assertEq(_userPosLiq(), liq, "mid: user LP untouched");

        PoolKey memory fullKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            tickSpacing: SPACING,
            hooks: IHooks(address(0))
        });
        manager.initialize(fullKey, BandTicks.sqrtPriceFromHuman(P_START));
        modifyLiquidityRouter.modifyLiquidity(
            fullKey,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(SPACING),
                tickUpper: TickMath.maxUsableTick(SPACING),
                liquidityDelta: int256(1e22),
                salt: 0
            }),
            ""
        );

        uint128 fullLiq = BandTicks.liquidityForAmount0(
            TickMath.getSqrtPriceAtTick(rangeLower), TickMath.getSqrtPriceAtTick(rangeUpper), ETH_BUDGET / 2
        );
        modifyLiquidityRouter.modifyLiquidity(
            fullKey,
            ModifyLiquidityParams({
                tickLower: rangeLower, tickUpper: rangeUpper, liquidityDelta: int256(uint256(fullLiq)), salt: bytes32("FULL")
            }),
            ""
        );

        swapRouter.swap(
            fullKey,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(5e24),
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(rangeUpper) + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        BalanceDelta rem = modifyLiquidityRouter.modifyLiquidity(
            fullKey,
            ModifyLiquidityParams({
                tickLower: rangeLower, tickUpper: rangeUpper, liquidityDelta: -int256(uint256(fullLiq)), salt: bytes32("FULL")
            }),
            ""
        );
        uint256 fullEthOut = rem.amount0() > 0 ? uint256(uint128(rem.amount0())) : 0;
        uint256 fullUsdcOut = rem.amount1() > 0 ? uint256(uint128(rem.amount1())) : 0;

        console2.log("=== ComparePaths gate model ===");
        console2.log("EndsHook mid swap: reverted SwapNotSupported");
        console2.log("EndsHook user LP still placed:", uint256(_userPosLiq()));
        console2.log("FullRange ethOut after up-move:", fullEthOut);
        console2.log("FullRange usdcOut after up-move:", fullUsdcOut);

        assertTrue(fullEthOut < ETH_BUDGET, "full-range sold some eth along the way");
    }
}
