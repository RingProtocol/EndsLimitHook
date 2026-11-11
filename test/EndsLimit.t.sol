// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/Test.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {EndToEndBase, EndsLimitHookHarness} from "./EndToEndBase.sol";
import {BandTicks} from "../src/libraries/BandTicks.sol";
import {EndsLimitHook} from "../src/EndsLimitHook.sol";

contract EndsLimitTest is EndToEndBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 internal constant P_LOW = 2500;
    uint256 internal constant P_HIGH = 3500;
    uint256 internal constant P_MID = 3000;

    uint160 internal nextHookBits = 0x80;
    uint24 internal nextFee = 100;

    function setUp() public {
        _setUpPool(P_LOW, P_MID, P_HIGH);
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
        manager.initialize(key, BandTicks.sqrtPriceFromHuman(P_MID));
    }

    function test_adminConfigure_recordsLockedRange() public view {
        (
            int24 rl,
            int24 ru,
            uint16 edge,
            ,
            int24 bu,
            int24 sl,
            int24 su,
            bool configured
        ) = hook.bands(endsKey.toId());

        assertTrue(configured);
        assertEq(rl, rangeLower);
        assertEq(ru, rangeUpper);
        assertEq(edge, EDGE_BPS);
        assertEq(bu, rangeLower);
        assertEq(su, rangeUpper);
        assertTrue(bu <= sl, "middle empty");
        console2.log("sellLower", int256(sl));
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

    function test_configure_onlyOwner() public {
        (EndsLimitHook hk, PoolKey memory key) = _freshHook();
        vm.prank(address(0xBEEF));
        vm.expectRevert(EndsLimitHook.NotOwner.selector);
        hk.configureRange(key, P_LOW, P_HIGH, EDGE_BPS);
    }

    function test_configure_alreadyConfigured() public {
        vm.expectRevert(EndsLimitHook.AlreadyConfigured.selector);
        hook.configureRange(endsKey, P_LOW, P_HIGH, EDGE_BPS);
    }

    function test_addLiquidity_mustMatchLockedRange() public {
        vm.expectRevert();
        modifyLiquidityRouter.modifyLiquidity(
            endsKey,
            ModifyLiquidityParams({
                tickLower: rangeLower + SPACING,
                tickUpper: rangeUpper,
                liquidityDelta: 1e18,
                salt: 0
            }),
            ""
        );
    }

    function test_addLiquidity_beforeConfigureReverts() public {
        (, PoolKey memory key) = _freshHook();
        vm.expectRevert();
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: rangeLower, tickUpper: rangeUpper, liquidityDelta: 1e18, salt: 0
            }),
            ""
        );
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

    function test_belowRange_wrongDirectionReverts() public {
        _setUpPool(P_LOW, 2470, P_HIGH);
        _addUserRange(_rangeLiqForEth(5 ether));
        vm.expectRevert();
        _swap(false, -1e17, TickMath.getSqrtPriceAtTick(rangeUpper) + 1);
    }

    function test_aboveRange_wrongDirectionReverts() public {
        _setUpPool(P_LOW, 3600, P_HIGH);
        _addUserRange(_rangeLiqForEth(5 ether));
        vm.expectRevert();
        _swap(true, -1e17, TickMath.MIN_SQRT_PRICE + 1);
    }
}
