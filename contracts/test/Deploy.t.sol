// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {RenewFarms} from "../script/RenewFarms.s.sol";
import {Pair} from "../src/core/Pair.sol";

/// @notice Runs the real deployment and renewal scripts against the local test chain.
contract DeployScriptTest is Test {
    function test_DeployAndRenew() public {
        // Anvil's well-known first test key. Never use it on a real network.
        uint256 pk = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        vm.setEnv("PRIVATE_KEY", vm.toString(bytes32(pk)));

        Deploy.Deployment memory d = new Deploy().run();

        assertEq(d.factory.allPairsLength(), 3);
        assertEq(d.router.factory(), address(d.factory));
        assertEq(d.arbitrage.factory(), address(d.factory));

        // Prices are consistent: 1 ETH = 3,000 USD and 1 BTC = 60,000 USD = 20 ETH.
        (uint256 rEth, uint256 rUsd) = d.router.getReserves(address(d.eth), address(d.usd));
        assertEq((rUsd * 1e18) / rEth, 3_000e18);
        (uint256 rBtc, uint256 rUsd2) = d.router.getReserves(address(d.btc), address(d.usd));
        assertEq((rUsd2 * 1e18) / rBtc, 60_000e18);
        (uint256 rEth3, uint256 rBtc3) = d.router.getReserves(address(d.eth), address(d.btc));
        assertEq((rEth3 * 1e18) / rBtc3, 20e18);

        assertEq(address(d.farmEthUsd.stakingToken()), d.pairEthUsd);
        assertEq(d.mdx.balanceOf(address(d.farmEthUsd)), 1_000e18);
        assertGt(Pair(d.pairEthUsd).balanceOf(vm.addr(pk)), 0);

        vm.warp(block.timestamp + 7 days);
        new RenewFarms().run();
        assertEq(d.mdx.balanceOf(address(d.farmEthBtc)), 2_000e18);
    }
}
