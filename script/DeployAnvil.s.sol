// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {SortTokens} from "@uniswap/v4-core/test/utils/SortTokens.sol";

import {EndsLimitHook} from "../src/EndsLimitHook.sol";
import {BandTicks} from "../src/libraries/BandTicks.sol";
import {HookMiner} from "../src/utils/HookMiner.sol";
import {BaseHook} from "../src/base/BaseHook.sol";

contract EndsLimitHookAnvil is EndsLimitHook {
    constructor(IPoolManager m, uint16 edge) EndsLimitHook(m, edge) {}

    function validateHookAddress(BaseHook) internal pure override {}
}

/// @notice Deploy PoolManager + EndsLimitHook; first user addLiquidity records range 2500–3500.
contract DeployAnvil is Script {
    using PoolIdLibrary for PoolKey;

    uint160 constant FLAGS = uint160(Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG);
    uint16 constant EDGE_BPS = 200;
    int24 constant SPACING = 60;

    function run() external {
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80));
        address deployer = vm.addr(pk);
        vm.startBroadcast(pk);

        PoolManager manager = new PoolManager(deployer);
        address create2Deployer = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
        (address hookAddr, bytes32 salt) = HookMiner.find(
            create2Deployer, FLAGS, type(EndsLimitHookAnvil).creationCode, abi.encode(address(manager), EDGE_BPS)
        );
        EndsLimitHookAnvil hook = new EndsLimitHookAnvil{salt: salt}(IPoolManager(address(manager)), EDGE_BPS);
        require(address(hook) == hookAddr, "hook salt");

        MockERC20 a = new MockERC20("ETH", "ETH", 18);
        MockERC20 b = new MockERC20("USDC", "USDC", 18);
        a.mint(deployer, type(uint128).max);
        b.mint(deployer, type(uint128).max);
        (Currency c0, Currency c1) = SortTokens.sort(a, b);

        PoolModifyLiquidityTest liq = new PoolModifyLiquidityTest(IPoolManager(address(manager)));
        a.approve(address(liq), type(uint256).max);
        b.approve(address(liq), type(uint256).max);

        PoolKey memory key = PoolKey({
            currency0: c0, currency1: c1, fee: 3000, tickSpacing: SPACING, hooks: IHooks(hookAddr)
        });
        manager.initialize(key, BandTicks.sqrtPriceFromHuman(3000));

        int24 rangeLower = BandTicks.floorToSpacing(BandTicks.tickFromHuman(2500), SPACING);
        int24 rangeUpper = BandTicks.floorToSpacing(BandTicks.tickFromHuman(3500), SPACING);
        uint128 liquidity = BandTicks.liquidityForAmount0(
            TickMath.getSqrtPriceAtTick(rangeLower), TickMath.getSqrtPriceAtTick(rangeUpper), 5 ether
        );
        liq.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: rangeLower, tickUpper: rangeUpper, liquidityDelta: int256(uint256(liquidity)), salt: 0
            }),
            ""
        );

        (,,, int24 bl, int24 bu, int24 sl, int24 su, bool configured) = hook.bands(key.toId());
        require(configured, "range not recorded");

        vm.stopBroadcast();

        console2.log("PoolManager", address(manager));
        console2.log("EndsLimitHook", hookAddr);
        console2.log("ModifyLiquidityRouter", address(liq));
        console2.log("buyLower", int256(bl));
        console2.log("buyUpper", int256(bu));
        console2.log("sellLower", int256(sl));
        console2.log("sellUpper", int256(su));
    }
}
