// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Factory} from "../src/core/Factory.sol";
import {Router} from "../src/periphery/Router.sol";
import {FlashArbitrage} from "../src/periphery/FlashArbitrage.sol";
import {StakingRewards} from "../src/farm/StakingRewards.sol";
import {FaucetToken} from "../src/tokens/FaucetToken.sol";

/// @notice Deploys the whole DEX with test tokens, three seeded pools at consistent prices,
///         and a liquidity-mining farm per pool. Writes addresses to deployments/<chainId>.json.
///
/// Usage:
///   PRIVATE_KEY=0x... forge script script/Deploy.s.sol --rpc-url sepolia --broadcast
contract Deploy is Script {
    struct Deployment {
        Factory factory;
        Router router;
        FlashArbitrage arbitrage;
        FaucetToken eth;
        FaucetToken btc;
        FaucetToken usd;
        FaucetToken mdx;
        address pairEthUsd;
        address pairBtcUsd;
        address pairEthBtc;
        StakingRewards farmEthUsd;
        StakingRewards farmBtcUsd;
        StakingRewards farmEthBtc;
    }

    uint256 internal constant FARM_DURATION = 7 days;
    uint256 internal constant FARM_REWARD = 1_000e18;

    address internal deployer;
    Deployment internal d;

    function run() external returns (Deployment memory) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        deployer = vm.addr(pk);

        vm.startBroadcast(pk);
        d.eth = new FaucetToken("Mini Ether", "mETH", 10e18);
        d.btc = new FaucetToken("Mini Bitcoin", "mBTC", 0.5e18);
        d.usd = new FaucetToken("Mini Dollar", "mUSD", 10_000e18);
        d.mdx = new FaucetToken("Mini DEX Reward", "MDX", 100e18);

        d.factory = new Factory();
        d.router = new Router(address(d.factory));
        d.arbitrage = new FlashArbitrage(address(d.factory));

        // Consistent prices: 1 ETH = 3,000 USD, 1 BTC = 60,000 USD, so 1 BTC = 20 ETH.
        d.pairEthUsd = _seedPool(d.eth, 100e18, d.usd, 300_000e18);
        d.pairBtcUsd = _seedPool(d.btc, 5e18, d.usd, 300_000e18);
        d.pairEthBtc = _seedPool(d.eth, 100e18, d.btc, 5e18);

        d.farmEthUsd = _farm(d.pairEthUsd);
        d.farmBtcUsd = _farm(d.pairBtcUsd);
        d.farmEthBtc = _farm(d.pairEthBtc);
        vm.stopBroadcast();

        _write();
        return d;
    }

    function _seedPool(FaucetToken a, uint256 amountA, FaucetToken b, uint256 amountB) internal returns (address) {
        a.mint(deployer, amountA);
        b.mint(deployer, amountB);
        a.approve(address(d.router), amountA);
        b.approve(address(d.router), amountB);
        d.router
            .addLiquidity(
                address(a), address(b), amountA, amountB, amountA, amountB, deployer, block.timestamp + 1 hours
            );
        return d.factory.getPair(address(a), address(b));
    }

    function _farm(address lpToken) internal returns (StakingRewards farm) {
        farm = new StakingRewards(lpToken, address(d.mdx), FARM_DURATION);
        d.mdx.mint(deployer, FARM_REWARD);
        d.mdx.approve(address(farm), FARM_REWARD);
        farm.notifyRewardAmount(FARM_REWARD);
    }

    function _write() internal {
        string memory o = "deployment";
        vm.serializeUint(o, "chainId", block.chainid);
        vm.serializeUint(o, "startBlock", block.number);
        vm.serializeAddress(o, "factory", address(d.factory));
        vm.serializeAddress(o, "router", address(d.router));
        vm.serializeAddress(o, "arbitrage", address(d.arbitrage));
        vm.serializeAddress(o, "tokenETH", address(d.eth));
        vm.serializeAddress(o, "tokenBTC", address(d.btc));
        vm.serializeAddress(o, "tokenUSD", address(d.usd));
        vm.serializeAddress(o, "tokenMDX", address(d.mdx));
        vm.serializeAddress(o, "pairETHUSD", d.pairEthUsd);
        vm.serializeAddress(o, "pairBTCUSD", d.pairBtcUsd);
        vm.serializeAddress(o, "pairETHBTC", d.pairEthBtc);
        vm.serializeAddress(o, "farmETHUSD", address(d.farmEthUsd));
        vm.serializeAddress(o, "farmBTCUSD", address(d.farmBtcUsd));
        string memory json = vm.serializeAddress(o, "farmETHBTC", address(d.farmEthBtc));
        vm.writeJson(json, string.concat("./deployments/", vm.toString(block.chainid), ".json"));

        console.log("Factory:   ", address(d.factory));
        console.log("Router:    ", address(d.router));
        console.log("Arbitrage: ", address(d.arbitrage));
    }
}
