// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Pair, IFlashSwapCallee} from "../src/core/Pair.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {DexFixture} from "./utils/DexFixture.sol";

/// @notice Borrows in a flash swap and repays `repayBps` of what the fee-inclusive repayment should be.
contract FlashBorrower is IFlashSwapCallee {
    uint256 public repayBps;
    bool public reenter;

    function borrow(Pair pair, uint256 amount0Out, uint256 amount1Out, uint256 repayBps_, bool reenter_) external {
        repayBps = repayBps_;
        reenter = reenter_;
        pair.swap(amount0Out, amount1Out, address(this), "flash");
    }

    function flashSwapCall(address, uint256 amount0Out, uint256 amount1Out, bytes calldata) external {
        Pair pair = Pair(msg.sender);
        if (reenter) pair.sync();
        // Repaying in the same token: need amountOut / 0.997, rounded up.
        if (amount0Out > 0) _repay(pair.token0(), msg.sender, amount0Out);
        if (amount1Out > 0) _repay(pair.token1(), msg.sender, amount1Out);
    }

    function _repay(address token, address pair, uint256 borrowed) internal {
        uint256 owed = (borrowed * 10_000) / 9_970 + 1;
        uint256 amount = (owed * repayBps) / 10_000;
        MockERC20(token).mint(address(this), amount);
        MockERC20(token).transfer(pair, amount);
    }
}

contract PairTest is DexFixture {
    Pair internal pair;
    MockERC20 internal t0;
    MockERC20 internal t1;

    function setUp() public {
        _deployDex();
        pair = Pair(factory.createPair(address(eth), address(usd)));
        t0 = MockERC20(pair.token0());
        t1 = MockERC20(pair.token1());
    }

    function _send(uint256 a0, uint256 a1) internal {
        t0.mint(address(pair), a0);
        t1.mint(address(pair), a1);
    }

    function _add(uint256 a0, uint256 a1) internal returns (uint256) {
        _send(a0, a1);
        return pair.mint(address(this));
    }

    function _amountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) internal pure returns (uint256) {
        return (amountIn * 9_970 * reserveOut) / (reserveIn * 10_000 + amountIn * 9_970);
    }

    // ------------------------------------------------------------------
    // Mint and burn
    // ------------------------------------------------------------------
    function test_FirstMintLocksMinimumLiquidity() public {
        uint256 liquidity = _add(1e18, 4e18);

        assertEq(liquidity, 2e18 - 1_000); // sqrt(1e18 * 4e18) - MINIMUM_LIQUIDITY
        assertEq(pair.balanceOf(pair.DEAD()), 1_000);
        assertEq(pair.totalSupply(), 2e18);
        (uint112 r0, uint112 r1,) = pair.getReserves();
        assertEq(r0, 1e18);
        assertEq(r1, 4e18);
    }

    function test_RevertWhen_FirstMintTooSmall() public {
        _send(1_000, 1_000);
        vm.expectRevert(Pair.InsufficientLiquidityMinted.selector);
        pair.mint(address(this));
    }

    function test_LaterMintIsProportional() public {
        _add(1e18, 4e18);
        assertEq(_add(0.5e18, 2e18), 1e18);
    }

    function test_OffRatioMintOnlyCountsSmallerSide() public {
        _add(1e18, 4e18);
        // 1e18 of token0 would be worth 2e18 LP, but 1e18 of token1 only 0.5e18.
        assertEq(_add(1e18, 1e18), 0.5e18);
    }

    function test_RevertWhen_MintWithNothingAdded() public {
        _add(1e18, 1e18);
        vm.expectRevert(Pair.InsufficientLiquidityMinted.selector);
        pair.mint(address(this));
    }

    function test_BurnReturnsProportionalShare() public {
        uint256 liquidity = _add(1e18, 4e18);
        pair.transfer(address(pair), liquidity);
        (uint256 a0, uint256 a1) = pair.burn(alice);

        assertEq(a0, 1e18 - 500); // all but the locked share
        assertEq(a1, 4e18 - 2_000);
        assertEq(t0.balanceOf(alice), a0);
        assertEq(t1.balanceOf(alice), a1);
        assertEq(pair.totalSupply(), 1_000);
    }

    function test_RevertWhen_BurnNothing() public {
        _add(1e18, 1e18);
        vm.expectRevert(Pair.InsufficientLiquidityBurned.selector);
        pair.burn(alice);
    }

    // ------------------------------------------------------------------
    // Swaps
    // ------------------------------------------------------------------
    function test_SwapToken0ForToken1() public {
        _add(10e18, 10e18);
        uint256 out = _amountOut(1e18, 10e18, 10e18);
        t0.mint(address(pair), 1e18);
        pair.swap(0, out, alice, "");

        assertEq(t1.balanceOf(alice), out);
        (uint112 r0, uint112 r1,) = pair.getReserves();
        assertEq(r0, 11e18);
        assertEq(r1, 10e18 - out);
    }

    function test_SwapToken1ForToken0() public {
        _add(10e18, 10e18);
        uint256 out = _amountOut(1e18, 10e18, 10e18);
        t1.mint(address(pair), 1e18);
        pair.swap(out, 0, alice, "");
        assertEq(t0.balanceOf(alice), out);
    }

    function test_RevertWhen_SwapTakesOneWeiTooMuch() public {
        _add(10e18, 10e18);
        uint256 out = _amountOut(1e18, 10e18, 10e18);
        t0.mint(address(pair), 1e18);
        vm.expectRevert(Pair.K.selector);
        pair.swap(0, out + 1, alice, "");
    }

    function test_RevertWhen_SwapWithoutFee() public {
        _add(10e18, 10e18);
        // The no-fee output (x*y=k exactly) must fail: the 0.3% fee has to stay in the pool.
        uint256 noFeeOut = (uint256(1e18) * 10e18) / (10e18 + 1e18);
        t0.mint(address(pair), 1e18);
        vm.expectRevert(Pair.K.selector);
        pair.swap(0, noFeeOut, alice, "");
    }

    function test_RevertWhen_SwapZeroOutput() public {
        _add(10e18, 10e18);
        vm.expectRevert(Pair.InsufficientOutputAmount.selector);
        pair.swap(0, 0, alice, "");
    }

    function test_RevertWhen_SwapDrainsReserve() public {
        _add(10e18, 10e18);
        vm.expectRevert(Pair.InsufficientLiquidity.selector);
        pair.swap(10e18, 0, alice, "");
        vm.expectRevert(Pair.InsufficientLiquidity.selector);
        pair.swap(0, 10e18, alice, "");
    }

    function test_RevertWhen_SwapToTokenAddress() public {
        _add(10e18, 10e18);
        vm.expectRevert(Pair.InvalidTo.selector);
        pair.swap(1, 0, address(t0), "");
        vm.expectRevert(Pair.InvalidTo.selector);
        pair.swap(1, 0, address(t1), "");
    }

    function test_RevertWhen_SwapWithoutInput() public {
        _add(10e18, 10e18);
        vm.expectRevert(Pair.InsufficientInputAmount.selector);
        pair.swap(1e18, 0, alice, "");
    }

    function test_FeesAccrueToLiquidityProviders() public {
        _add(100e18, 100e18);
        (uint112 r0Before, uint112 r1Before,) = pair.getReserves();
        uint256 kBefore = uint256(r0Before) * r1Before;

        for (uint256 i = 0; i < 10; ++i) {
            (uint112 r0, uint112 r1,) = pair.getReserves();
            t0.mint(address(pair), 5e18);
            pair.swap(0, _amountOut(5e18, r0, r1), alice, "");
            (r0, r1,) = pair.getReserves();
            t1.mint(address(pair), 5e18);
            pair.swap(_amountOut(5e18, r1, r0), 0, alice, "");
        }

        (uint112 r0After, uint112 r1After,) = pair.getReserves();
        assertGt(uint256(r0After) * r1After, kBefore, "k grows from fees");
    }

    // ------------------------------------------------------------------
    // Flash swaps and reentrancy
    // ------------------------------------------------------------------
    function test_FlashSwapRepaidWithFee() public {
        _add(10e18, 10e18);
        FlashBorrower borrower = new FlashBorrower();
        borrower.borrow(pair, 1e18, 0, 10_000, false);

        assertEq(t0.balanceOf(address(borrower)), 1e18); // kept the loan, paid the fee from its own funds
        (uint112 r0,,) = pair.getReserves();
        assertGt(r0, 10e18); // pool earned the fee
    }

    function test_RevertWhen_FlashSwapUnderpaid() public {
        _add(10e18, 10e18);
        FlashBorrower borrower = new FlashBorrower();
        vm.expectRevert(Pair.K.selector);
        borrower.borrow(pair, 0, 1e18, 9_990, false); // 0.1% short
    }

    function test_RevertWhen_ReenteringDuringFlashSwap() public {
        _add(10e18, 10e18);
        FlashBorrower borrower = new FlashBorrower();
        vm.expectRevert(Pair.Locked.selector);
        borrower.borrow(pair, 1e18, 0, 10_000, true);
    }

    // ------------------------------------------------------------------
    // Skim, sync, overflow, oracle
    // ------------------------------------------------------------------
    function test_SkimSendsExcessBalance() public {
        _add(10e18, 10e18);
        _send(3e18, 7e18);
        pair.skim(bob);
        assertEq(t0.balanceOf(bob), 3e18);
        assertEq(t1.balanceOf(bob), 7e18);
    }

    function test_SyncMatchesReservesToBalances() public {
        _add(10e18, 10e18);
        _send(3e18, 7e18);
        pair.sync();
        (uint112 r0, uint112 r1,) = pair.getReserves();
        assertEq(r0, 13e18);
        assertEq(r1, 17e18);
    }

    function test_RevertWhen_ReservesOverflowUint112() public {
        uint256 tooBig = uint256(type(uint112).max) + 1;
        _send(tooBig, tooBig);
        vm.expectRevert(Pair.Overflow.selector);
        pair.mint(address(this));
    }

    function test_PriceAccumulatorsTrackTimeWeightedPrice() public {
        _add(1e18, 4e18); // price0 = 4 token1 per token0
        uint256 start0 = pair.price0CumulativeLast();
        uint256 start1 = pair.price1CumulativeLast();

        vm.warp(block.timestamp + 10);
        pair.sync();

        assertEq(pair.price0CumulativeLast() - start0, (uint256(4) << 112) * 10);
        assertEq(pair.price1CumulativeLast() - start1, ((uint256(1) << 112) / 4) * 10);
    }

    function test_SameBlockUpdatesDoNotAccumulate() public {
        _add(1e18, 4e18);
        uint256 start0 = pair.price0CumulativeLast();
        pair.sync();
        assertEq(pair.price0CumulativeLast(), start0);
    }

    // ------------------------------------------------------------------
    // Attack: first-depositor inflation
    // ------------------------------------------------------------------
    function test_InflationAttackIsUneconomical() public {
        // Attacker creates the pool with dust, then donates a lot to inflate the LP price.
        _send(1_001, 1_001);
        uint256 attackerLp = pair.mint(alice); // 1 LP; 1,000 LP locked forever
        assertEq(attackerLp, 1);
        _send(100e18, 100e18);
        pair.sync();

        // Most of the donation now belongs to the locked liquidity, not the attacker.
        vm.prank(alice);
        pair.transfer(address(pair), attackerLp);
        (uint256 back0, uint256 back1) = pair.burn(alice);
        assertLt(back0, 0.001e18 * 100); // got back < 0.1% of the 100e18 donated
        assertLt(back1, 0.001e18 * 100);
    }
}
