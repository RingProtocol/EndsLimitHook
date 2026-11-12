// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {SortTokens} from "@uniswap/v4-core/test/utils/SortTokens.sol";

import {EndsLimitHook} from "../src/EndsLimitHook.sol";
import {BandTicks} from "../src/libraries/BandTicks.sol";
import {HookMiner} from "../src/utils/HookMiner.sol";
import {BaseHook} from "../src/base/BaseHook.sol";
import {SwapCaller} from "../src/test/SwapCaller.sol";

contract EndsLimitHookFix is EndsLimitHook {
    constructor(IPoolManager m, address o) EndsLimitHook(m, o) {}

    function validateHookAddress(BaseHook) internal pure override {}
}

contract AnvilSwapFixtures is Script {
    uint160 constant FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
    );
    uint16 constant EDGE_BPS = 200;
    int24 constant SPACING = 60;
    address constant CREATE2 = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80));
        address owner = vm.addr(pk);
        vm.startBroadcast(pk);

        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        a.mint(owner, type(uint128).max);
        b.mint(owner, type(uint128).max);
        (Currency c0, Currency c1) = SortTokens.sort(a, b);

        _one("main", owner, c0, c1, a, b);

        vm.stopBroadcast();
    }

    function _one(string memory label, address owner, Currency c0, Currency c1, MockERC20 a, MockERC20 b) internal {
        PoolManager manager = new PoolManager(owner);
        (address hookAddr, bytes32 salt) = HookMiner.find(
            CREATE2, FLAGS, type(EndsLimitHookFix).creationCode, abi.encode(address(manager), owner)
        );
        EndsLimitHookFix hook = new EndsLimitHookFix{salt: salt}(IPoolManager(address(manager)), owner);
        require(address(hook) == hookAddr, "hook salt");

        PoolModifyLiquidityTest liq = new PoolModifyLiquidityTest(IPoolManager(address(manager)));
        PoolSwapTest swapRouter = new PoolSwapTest(IPoolManager(address(manager)));
        SwapCaller caller = new SwapCaller(swapRouter);

        a.approve(address(liq), type(uint256).max);
        b.approve(address(liq), type(uint256).max);
        a.approve(address(swapRouter), type(uint256).max);
        b.approve(address(swapRouter), type(uint256).max);

        PoolKey memory key = PoolKey({
            currency0: c0, currency1: c1, fee: 3000, tickSpacing: SPACING, hooks: IHooks(hookAddr)
        });

        (int24 bl, int24 bu, int24 sl, int24 su, uint160 initSqrt) =
            BandTicks.bandsFromRange(2500, 3500, EDGE_BPS, SPACING);

        hook.configureRange(key, 2500, 3500, EDGE_BPS);
        manager.initialize(key, initSqrt);

        uint128 buyLiq = BandTicks.liquidityForAmount1(
            TickMath.getSqrtPriceAtTick(bl), TickMath.getSqrtPriceAtTick(bu), 50_000 ether
        );
        uint128 sellLiq = BandTicks.liquidityForAmount0(
            TickMath.getSqrtPriceAtTick(sl), TickMath.getSqrtPriceAtTick(su), 5 ether
        );
        liq.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: bl, tickUpper: bu, liquidityDelta: int256(uint256(buyLiq)), salt: bytes32("BUY")
            }),
            ""
        );
        liq.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: sl, tickUpper: su, liquidityDelta: int256(uint256(sellLiq)), salt: bytes32("SELL")
            }),
            ""
        );

        console2.log(string.concat("FIX_", label, "_manager"), address(manager));
        console2.log(string.concat("FIX_", label, "_hook"), hookAddr);
        console2.log(string.concat("FIX_", label, "_router"), address(swapRouter));
        console2.log(string.concat("FIX_", label, "_caller"), address(caller));
        console2.log(string.concat("FIX_", label, "_c0"), Currency.unwrap(c0));
        console2.log(string.concat("FIX_", label, "_c1"), Currency.unwrap(c1));
        console2.log(string.concat("FIX_", label, "_buyLower"), int256(bl));
        console2.log(string.concat("FIX_", label, "_buyUpper"), int256(bu));
        console2.log(string.concat("FIX_", label, "_sellLower"), int256(sl));
        console2.log(string.concat("FIX_", label, "_sellUpper"), int256(su));
        console2.log(string.concat("FIX_", label, "_initSqrt"), uint256(initSqrt));
        console2.log(string.concat("FIX_", label, "_sellLim"), uint256(TickMath.getSqrtPriceAtTick(su)) + 1);
        console2.log(string.concat("FIX_", label, "_buyLim"), uint256(TickMath.getSqrtPriceAtTick(bl)));
    }
}
