// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {StakingRewards} from "../src/farm/StakingRewards.sol";
import {FaucetToken} from "../src/tokens/FaucetToken.sol";

/// @notice Tops up every farm with another week of MDX rewards.
///         Reads addresses from deployments/<chainId>.json.
contract RenewFarms is Script {
    uint256 internal constant FARM_REWARD = 1_000e18;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        string memory json = vm.readFile(string.concat("./deployments/", vm.toString(block.chainid), ".json"));
        FaucetToken mdx = FaucetToken(vm.parseJsonAddress(json, ".tokenMDX"));

        string[3] memory keys = [".farmETHUSD", ".farmBTCUSD", ".farmETHBTC"];
        vm.startBroadcast(pk);
        for (uint256 i = 0; i < keys.length; ++i) {
            StakingRewards farm = StakingRewards(vm.parseJsonAddress(json, keys[i]));
            mdx.mint(deployer, FARM_REWARD);
            mdx.approve(address(farm), FARM_REWARD);
            farm.notifyRewardAmount(FARM_REWARD);
        }
        vm.stopBroadcast();
        console.log("Renewed 3 farms");
    }
}
