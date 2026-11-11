// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

/// @dev Prefer `scripts/anvil-swap-verify.sh` + AnvilSwapFixtures / AnvilSwapSuccess.
/// Kept as a stub so old docs links do not point at a broken configureRange flow.
contract AnvilSwapVerify is Script {
    function run() external pure {
        console2.log("Use AnvilSwapFixtures + anvil-swap-verify.sh + AnvilSwapSuccess");
        console2.log("configureRange/placeBuy/placeSell removed: first addLiquidity records range");
    }
}
