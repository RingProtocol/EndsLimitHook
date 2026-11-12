// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {EndToEndBase} from "./EndToEndBase.sol";
import {BandTicks} from "../src/libraries/BandTicks.sol";
import {EndsLimitHook} from "../src/EndsLimitHook.sol";

contract EndsLimitTest is EndToEndBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 internal constant P_LOW = 2500;
    uint256 internal constant P_HIGH = 3500;

    uint160 internal nextHookBits = 0x80;
    uint24 internal nextFee = 100;

    function setUp() public {
        _setUpPool(P_LOW, P_HIGH);
    }

    function _freshHook() internal returns (EndsLimitHook hk, PoolKey memory key) {
        address ha = address(uint160(HOOK_FLAGS) | nextHookBits);
        nextHookBits <<= 1;
        uint24 fee = nextFee;
        nextFee += 100;
        deployCodeTo("EndToEndBase.sol:EndsLimitHookHarness", abi.encode(manager, address(this)), ha);
        hk = EndsLimitHook(ha);
        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: fee,
            tickSpacing: SPACING,
            hooks: IHooks(ha)
        });
    }

    function test_initPrice_isPLowTimesOnePlusEdge_notMid() public view {
        assertEq(BandTicks.initHumanPrice(P_LOW, EDGE_BPS), 2550);
        assertEq(initSqrt, TickMath.getSqrtPriceAtTick(buyUpper));
        assertEq(_slotTick(), buyUpper);
        assertTrue(_slotTick() < sellLower);
        console2.log("buyUpper", int256(buyUpper));
        console2.log("initTick", int256(_slotTick()));
    }

    function test_initialize_rejectsWrongPrice() public {
        (EndsLimitHook hk, PoolKey memory key) = _freshHook();
        hk.configureRange(key, P_LOW, P_HIGH, EDGE_BPS);
        vm.expectRevert();
        manager.initialize(key, BandTicks.sqrtPriceFromHuman(3000));
    }

    function test_initialize_beforeConfigureReverts() public {
        (, PoolKey memory key) = _freshHook();
        vm.expectRevert();
        manager.initialize(key, initSqrt);
    }

    function test_configure_rejectsEdgeAbove2pct() public {
        (EndsLimitHook hk, PoolKey memory key) = _freshHook();
        vm.expectRevert(BandTicks.BadEdge.selector);
        hk.configureRange(key, P_LOW, P_HIGH, 201);
    }

    function test_configure_rejectsWidthBelow5pct() public {
        (EndsLimitHook hk, PoolKey memory key) = _freshHook();
        vm.expectRevert(BandTicks.BadWidth.selector);
        hk.configureRange(key, 2500, 2600, EDGE_BPS);
    }

    function test_addLiquidity_onlyEndBands() public {
        vm.expectRevert();
        modifyLiquidityRouter.modifyLiquidity(
            endsKey,
            ModifyLiquidityParams({
                tickLower: buyLower, tickUpper: sellUpper, liquidityDelta: 1e18, salt: 0
            }),
            ""
        );

        _addBuyBand(_buyLiq(10_000 ether));
        _addSellBand(_sellLiq(5 ether));
        assertTrue(_buyPosLiq() > 0);
        assertTrue(_sellPosLiq() > 0);
    }

    function test_fromInit_crossEmptyMiddleToSell() public {
        _addBuyBand(_buyLiq(10_000 ether));
        _addSellBand(_sellLiq(5 ether));
        // Start at buyUpper (middle boundary); climb across empty middle into sell band.
        assertEq(_slotTick(), buyUpper);
        _swap(false, -1e24, TickMath.getSqrtPriceAtTick(sellUpper) + 1);
        assertTrue(_slotTick() >= sellLower, "reached sell via middle");
    }

    function test_bothDirections_okInBuyBand_noDeadlock() public {
        _addBuyBand(_buyLiq(50_000 ether));
        _swap(true, -1e20, TickMath.getSqrtPriceAtTick(buyLower));
        // Opposite direction must also work (otherwise partial fill permanently traps price).
        _swap(false, -1e18, TickMath.getSqrtPriceAtTick(buyUpper) + 1);
        assertTrue(_slotTick() <= buyUpper);
    }
}
