// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "./base/BaseHook.sol";
import {BandTicks} from "./libraries/BandTicks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @title EndsLimitHook
/// @notice Admin locks one range per pool. Init price is forced to `pLow*(1+edge)` (buy/middle boundary).
///         Users add LP only on buy or sell end bands. Swaps are allowed in both directions everywhere:
///         empty middle makes crossing cheap; reverse-fill risk is bounded by edge width (no afterSwap remove).
///         Hook never places LP itself.
/// @dev Assumes token0 = asset, token1 = quote, human price = token1/token0.
contract EndsLimitHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;

    error NotOwner();
    error NotConfigured();
    error AlreadyConfigured();
    error RangeLocked();
    error BadInitPrice();

    event RangeConfigured(
        PoolId indexed id,
        uint256 pLow,
        uint256 pHigh,
        uint16 edgeBps,
        uint160 initSqrtPriceX96,
        int24 buyLower,
        int24 buyUpper,
        int24 sellLower,
        int24 sellUpper
    );

    struct BandState {
        uint160 initSqrtPriceX96;
        uint16 edgeBps;
        int24 buyLower;
        int24 buyUpper;
        int24 sellLower;
        int24 sellUpper;
        bool configured;
    }

    address public owner;
    mapping(PoolId => BandState) public bands;

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(IPoolManager _manager, address _owner) BaseHook(_manager) {
        owner = _owner;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice Admin locks range. Must run **before** pool `initialize`.
    /// `edgeBps` max 2%; width ≥ 5%. Init price locked to `pLow*(1+edge)`.
    function configureRange(PoolKey calldata key, uint256 pLow, uint256 pHigh, uint16 edgeBps) external onlyOwner {
        PoolId id = key.toId();
        BandState storage s = bands[id];
        if (s.configured) revert AlreadyConfigured();

        (int24 buyLower, int24 buyUpper, int24 sellLower, int24 sellUpper, uint160 initSqrt) =
            BandTicks.bandsFromRange(pLow, pHigh, edgeBps, key.tickSpacing);

        s.initSqrtPriceX96 = initSqrt;
        s.edgeBps = edgeBps;
        s.buyLower = buyLower;
        s.buyUpper = buyUpper;
        s.sellLower = sellLower;
        s.sellUpper = sellUpper;
        s.configured = true;

        emit RangeConfigured(id, pLow, pHigh, edgeBps, initSqrt, buyLower, buyUpper, sellLower, sellUpper);
    }

    function _beforeInitialize(address, PoolKey calldata key, uint160 sqrtPriceX96)
        internal
        view
        override
        returns (bytes4)
    {
        BandState storage s = bands[key.toId()];
        if (!s.configured) revert NotConfigured();
        if (sqrtPriceX96 != s.initSqrtPriceX96) revert BadInitPrice();
        return this.beforeInitialize.selector;
    }

    function _beforeAddLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata
    ) internal view override returns (bytes4) {
        BandState storage s = bands[key.toId()];
        if (!s.configured) revert NotConfigured();

        bool buyBand = params.tickLower == s.buyLower && params.tickUpper == s.buyUpper;
        bool sellBand = params.tickLower == s.sellLower && params.tickUpper == s.sellUpper;
        if (!buyBand && !sellBand) revert RangeLocked();

        return this.beforeAddLiquidity.selector;
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        view
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // Directional gates at ends were removed: one-way rules re-deadlock after a partial fill.
        // Geometry does the work — ends-only LP + empty middle; reverse fill ≤ edge width.
        if (!bands[key.toId()].configured) revert NotConfigured();
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }
}
