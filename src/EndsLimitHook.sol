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
/// @notice Admin configures one locked range per pool. Users may add LP only on that range.
///         `beforeSwap` allows open-ended end zones; middle reverts. Hook never places LP itself.
/// @dev Assumes token0 = asset, token1 = quote, human price = token1/token0.
contract EndsLimitHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;

    error NotOwner();
    error NotConfigured();
    error AlreadyConfigured();
    error RangeLocked();
    error SwapNotSupported();
    error WrongDirection();

    event RangeConfigured(
        PoolId indexed id,
        uint256 pLow,
        uint256 pHigh,
        uint16 edgeBps,
        int24 rangeLower,
        int24 rangeUpper,
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

    /// @notice Admin locks pool strategy range. `edgeBps` max 2%; width must be ≥ 5%.
    function configureRange(PoolKey calldata key, uint256 pLow, uint256 pHigh, uint16 edgeBps) external onlyOwner {
        PoolId id = key.toId();
        BandState storage s = bands[id];
        if (s.configured) revert AlreadyConfigured();

        BandTicks.assertMinWidth(pLow, pHigh);
        BandTicks.assertEdge(edgeBps);

        int24 rangeLower = BandTicks.floorToSpacing(BandTicks.tickFromHuman(pLow), key.tickSpacing);
        int24 rangeUpper = BandTicks.floorToSpacing(BandTicks.tickFromHuman(pHigh), key.tickSpacing);
        (int24 buyLower, int24 buyUpper, int24 sellLower, int24 sellUpper) =
            BandTicks.bandsFromTicks(rangeLower, rangeUpper, edgeBps, key.tickSpacing);

        s.rangeLower = rangeLower;
        s.rangeUpper = rangeUpper;
        s.edgeBps = edgeBps;
        s.buyLower = buyLower;
        s.buyUpper = buyUpper;
        s.sellLower = sellLower;
        s.sellUpper = sellUpper;
        s.configured = true;

        emit RangeConfigured(id, pLow, pHigh, edgeBps, rangeLower, rangeUpper, buyLower, buyUpper, sellLower, sellUpper);
    }

    function _beforeAddLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata
    ) internal view override returns (bytes4) {
        BandState storage s = bands[key.toId()];
        if (!s.configured) revert NotConfigured();
        if (params.tickLower != s.rangeLower || params.tickUpper != s.rangeUpper) revert RangeLocked();
        return this.beforeAddLiquidity.selector;
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

        // Below range low (open-ended): traders sell asset → LP buys.
        if (tick < s.buyUpper) {
            if (!params.zeroForOne) revert WrongDirection();
            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // At/above sell edge (open-ended up): traders buy asset → LP sells.
        if (tick >= s.sellLower) {
            if (params.zeroForOne) revert WrongDirection();
            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        revert SwapNotSupported();
    }
}
