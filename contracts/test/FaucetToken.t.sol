// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {FaucetToken} from "../src/tokens/FaucetToken.sol";

contract FaucetTokenTest is Test {
    FaucetToken internal token;
    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");

    function setUp() public {
        vm.prank(owner);
        token = new FaucetToken("Stake Token", "STK", 1_000e18);
    }

    function test_FaucetMints() public {
        vm.prank(alice);
        token.faucet();
        assertEq(token.balanceOf(alice), 1_000e18);
        assertEq(token.lastFaucetAt(alice), block.timestamp);
    }

    function test_RevertWhen_FaucetWithinCooldown() public {
        vm.startPrank(alice);
        token.faucet();
        vm.warp(block.timestamp + 1 days - 1);
        vm.expectRevert(abi.encodeWithSelector(FaucetToken.FaucetCooldown.selector, token.lastFaucetAt(alice) + 1 days));
        token.faucet();
        vm.stopPrank();
    }

    function test_FaucetAgainAfterCooldown() public {
        vm.startPrank(alice);
        token.faucet();
        vm.warp(block.timestamp + 1 days);
        token.faucet();
        vm.stopPrank();
        assertEq(token.balanceOf(alice), 2_000e18);
    }

    function test_OwnerCanMint() public {
        vm.prank(owner);
        token.mint(alice, 5e18);
        assertEq(token.balanceOf(alice), 5e18);
    }

    function test_RevertWhen_NonOwnerMints() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        token.mint(alice, 5e18);
    }
}
