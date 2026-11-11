// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @notice Broadcast successful end-zone swaps against fixtures from AnvilSwapFixtures.
contract AnvilSwapSuccess is Script {
    function run() external {
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80));

        address sellRouter = vm.envAddress("SELL_ROUTER");
        address sellHook = vm.envAddress("SELL_HOOK");
        address buyRouter = vm.envAddress("BUY_ROUTER");
        address buyHook = vm.envAddress("BUY_HOOK");
        address c0 = vm.envAddress("C0");
        address c1 = vm.envAddress("C1");
        int24 sellUpper = int24(vm.envInt("SELL_UPPER"));
        int24 buyLower = int24(vm.envInt("BUY_LOWER"));

        PoolKey memory sellKey = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(sellHook)
        });
        PoolKey memory buyKey = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(buyHook)
        });

        vm.startBroadcast(pk);

        PoolSwapTest(sellRouter).swap(
            sellKey,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -1e18,
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(sellUpper) + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        console2.log("sell_right_ok");

        PoolSwapTest(buyRouter).swap(
            buyKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -1e18,
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(buyLower)
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        console2.log("buy_right_ok");

        vm.stopBroadcast();
    }
}
