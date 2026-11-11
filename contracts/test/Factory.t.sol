// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Factory} from "../src/core/Factory.sol";
import {Pair} from "../src/core/Pair.sol";
import {DexFixture} from "./utils/DexFixture.sol";

contract FactoryTest is DexFixture {
    function setUp() public {
        _deployDex();
    }

    function test_CreatePairSortsTokensAndRegistersBothWays() public {
        address pairAddr = factory.createPair(address(usd), address(eth));
        Pair pair = Pair(pairAddr);

        (address lo, address hi) = address(eth) < address(usd) ? (address(eth), address(usd)) : (address(usd), address(eth));
        assertEq(pair.token0(), lo);
        assertEq(pair.token1(), hi);
        assertEq(pair.factory(), address(factory));
        assertEq(factory.getPair(address(eth), address(usd)), pairAddr);
        assertEq(factory.getPair(address(usd), address(eth)), pairAddr);
        assertEq(factory.allPairsLength(), 1);
        assertEq(factory.allPairs(0), pairAddr);

        (address p0, address p1) = factory.parameters();
        assertEq(p0, address(0)); // cleared after deployment
        assertEq(p1, address(0));
    }

    function test_PairAddressIsPredictable() public {
        (address lo, address hi) = address(eth) < address(usd) ? (address(eth), address(usd)) : (address(usd), address(eth));
        bytes32 salt = keccak256(abi.encodePacked(lo, hi));
        address predicted = address(
            uint160(uint256(keccak256(abi.encodePacked(hex"ff", address(factory), salt, factory.pairCodeHash()))))
        );
        assertEq(factory.createPair(address(eth), address(usd)), predicted);
    }

    function test_RevertWhen_IdenticalTokens() public {
        vm.expectRevert(Factory.IdenticalTokens.selector);
        factory.createPair(address(eth), address(eth));
    }

    function test_RevertWhen_ZeroAddress() public {
        vm.expectRevert(Factory.ZeroAddress.selector);
        factory.createPair(address(0), address(eth));
    }

    function test_RevertWhen_PairExists() public {
        factory.createPair(address(eth), address(usd));
        vm.expectRevert(Factory.PairExists.selector);
        factory.createPair(address(usd), address(eth));
    }
}
