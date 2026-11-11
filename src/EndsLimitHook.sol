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
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

/// @title EndsLimitHook
/// @notice First user `addLiquidity` records the strategy range. Hook does not place LP itself.
///         `beforeSwap` allows only outside the middle: below `buyUpper` (sell ETH in) or at/above
///         `sellLower` (buy ETH out, open-ended upward — e.g. 4000 still allowed). Middle reverts.
/// @dev Assumes token0 = asset, token1 = quote, human price = token1/token0.
contract EndsLimitHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;

    error NotConfigured();
    error BadEdge();
    error BadRange();
    error SwapNotSupported();
    error WrongDirection();

    event RangeRecorded(
        PoolId indexed id,
        int24 rangeLower,
        int24 rangeUpper,
        uint16 edgeBps,
        int24 buyLower,
        int24 buyUpper,
        int24 sellLower,
        int24 sellUpper
    );

    struct BandState {
        int24 rangeLower;
        int24 rangeUpper;
        uint16 edgeBps;
        int24 buyLower;
        int24 buyUpper;
        int24 sellLower;
        int24 sellUpper;
        bool configured;
    }

    /// @notice Edge width used when deriving end thresholds from the recorded range (e.g. 200 = 2%).
    uint16 public immutable edgeBps;

    mapping(PoolId => BandState) public bands;

    constructor(IPoolManager _manager, uint16 _edgeBps) BaseHook(_manager) {
        if (_edgeBps == 0 || _edgeBps >= 5000) revert BadEdge();
        edgeBps = _edgeBps;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
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

    function _beforeAddLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata
    ) internal override returns (bytes4) {
        BandState storage s = bands[key.toId()];
        // First add defines the user range; later adds are unrestricted (gate handles swaps).
        if (!s.configured) _recordRange(key, params.tickLower, params.tickUpper);
        return this.beforeAddLiquidity.selector;
    }

    function _recordRange(PoolKey calldata key, int24 tickLower, int24 tickUpper) internal {
        if (tickLower >= tickUpper) revert BadRange();

        BandState storage s = bands[key.toId()];
        s.rangeLower = tickLower;
        s.rangeUpper = tickUpper;
        s.edgeBps = edgeBps;
        (s.buyLower, s.buyUpper, s.sellLower, s.sellUpper) =
            BandTicks.bandsFromTicks(tickLower, tickUpper, edgeBps, key.tickSpacing);
        s.configured = true;

        emit RangeRecorded(
            key.toId(), tickLower, tickUpper, edgeBps, s.buyLower, s.buyUpper, s.sellLower, s.sellUpper
        );
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        view
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        BandState storage s = bands[key.toId()];
        if (!s.configured) revert NotConfigured();

        (, int24 tick,,) = poolManager.getSlot0(key.toId());

        // Below range low (open-ended downward, includes buy edge): traders sell asset → LP buys.
        if (tick < s.buyUpper) {
            if (!params.zeroForOne) revert WrongDirection();
            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // At/above sell edge (open-ended upward, includes > pHigh e.g. 4000): traders buy asset → LP sells.
        if (tick >= s.sellLower) {
            if (params.zeroForOne) revert WrongDirection();
            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // Middle between buyUpper and sellLower.
        revert SwapNotSupported();
    }
}
