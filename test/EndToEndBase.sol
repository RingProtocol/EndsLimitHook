// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {SortTokens} from "@uniswap/v4-core/test/utils/SortTokens.sol";

import {EndsLimitHook} from "../src/EndsLimitHook.sol";
import {BaseHook} from "../src/base/BaseHook.sol";
import {BandTicks} from "../src/libraries/BandTicks.sol";

contract EndsLimitHookHarness is EndsLimitHook {
    constructor(IPoolManager m, address owner_) EndsLimitHook(m, owner_) {}

    function validateHookAddress(BaseHook) internal pure override {}
}

/// @dev Thin fixture — avoids inheriting v4-core Deployers (stack-too-deep with this hook).
abstract contract EndToEndBase is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;

    uint160 internal constant HOOK_FLAGS =
        uint160(Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG);
    int24 internal constant SPACING = 60;
    uint16 internal constant EDGE_BPS = 200; // 2%

    IPoolManager internal manager;
    PoolModifyLiquidityTest internal modifyLiquidityRouter;
    PoolSwapTest internal swapRouter;
    Currency internal currency0;
    Currency internal currency1;
    EndsLimitHook internal hook;
    PoolKey internal endsKey;

    uint256 internal pLowHuman;
    uint256 internal pHighHuman;
    int24 internal rangeLower;
    int24 internal rangeUpper;
    int24 internal buyLower;
    int24 internal buyUpper;
    int24 internal sellLower;
    int24 internal sellUpper;

    function _setUpPool(uint256 pLow, uint256 pInit, uint256 pHigh) internal {
        pLowHuman = pLow;
        pHighHuman = pHigh;

        manager = new PoolManager(address(this));
        swapRouter = new PoolSwapTest(manager);
        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);

        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        a.mint(address(this), type(uint128).max);
        b.mint(address(this), type(uint128).max);
        (currency0, currency1) = SortTokens.sort(a, b);

        a.approve(address(swapRouter), type(uint256).max);
        b.approve(address(swapRouter), type(uint256).max);
        a.approve(address(modifyLiquidityRouter), type(uint256).max);
        b.approve(address(modifyLiquidityRouter), type(uint256).max);

        address hookAddr = address(HOOK_FLAGS);
        deployCodeTo("EndToEndBase.sol:EndsLimitHookHarness", abi.encode(manager, address(this)), hookAddr);
        hook = EndsLimitHook(hookAddr);

        rangeLower = BandTicks.floorToSpacing(BandTicks.tickFromHuman(pLow), SPACING);
        rangeUpper = BandTicks.floorToSpacing(BandTicks.tickFromHuman(pHigh), SPACING);
        (buyLower, buyUpper, sellLower, sellUpper) =
            BandTicks.bandsFromTicks(rangeLower, rangeUpper, EDGE_BPS, SPACING);

        endsKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            tickSpacing: SPACING,
            hooks: IHooks(hookAddr)
        });
        // Anyone may initialize; first caller sets price.
        manager.initialize(endsKey, BandTicks.sqrtPriceFromHuman(pInit));
        hook.configureRange(endsKey, pLow, pHigh, EDGE_BPS);
    }

    function _addUserRange(uint128 liquidity) internal {
        modifyLiquidityRouter.modifyLiquidity(
            endsKey,
            ModifyLiquidityParams({
                tickLower: rangeLower, tickUpper: rangeUpper, liquidityDelta: int256(uint256(liquidity)), salt: 0
            }),
            ""
        );
    }

    function _rangeLiqForEth(uint256 ethIn) internal view returns (uint128) {
        return BandTicks.liquidityForAmount0(
            TickMath.getSqrtPriceAtTick(rangeLower), TickMath.getSqrtPriceAtTick(rangeUpper), ethIn
        );
    }

    function _userPosLiq() internal view returns (uint128 liq) {
        (liq,,) = manager.getPositionInfo(endsKey.toId(), address(modifyLiquidityRouter), rangeLower, rangeUpper, bytes32(0));
    }

    function _slotTick() internal view returns (int24 tick) {
        (, tick,,) = manager.getSlot0(endsKey.toId());
    }

    function _swap(bool zeroForOne, int256 amountSpecified, uint160 limit) internal {
        swapRouter.swap(
            endsKey,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }
}
