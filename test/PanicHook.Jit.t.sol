// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {PanicTestBase} from "./utils/PanicTestBase.sol";

/// @notice Same-block liquidity forfeits the fees it earned, so a seller cannot recapture the LP share of
/// their own hook fee with liquidity that exists only around their sell.
contract PanicHookJitTest is PanicTestBase {
    using StateLibrary for IPoolManager;

    function setUp() public {
        _setUpNativePool(SQRT_PRICE_1_1);
        _fundAndApprove();
        _addFullRangeLiquidity(FULL_RANGE_LIQUIDITY);
        // Resident liquidity predates the trading block.
        _nextBlock(12);
    }

    function _modify(int24 lower, int24 upper, int256 liquidityDelta) internal returns (BalanceDelta) {
        return lpRouter.modifyLiquidity{value: liquidityDelta > 0 ? 1e26 : 0}(
            key, ModifyLiquidityParams(lower, upper, liquidityDelta, 0), ""
        );
    }

    function test_sellerCannotRecaptureTheirOwnDonationWithSameBlockLiquidity() public {
        int24 lower = 2200;
        uint160 stopAt = TickMath.getSqrtPriceAtTick(lower) + 1;
        uint256 snap = vm.snapshotState();

        uint256 before = address(this).balance;
        _sellPanicToPrice(stopAt);
        uint256 plainGain = address(this).balance - before;
        assertGt(hook.totalDonated(), 0, "the LP share is still donated in the swap");

        vm.revertToState(snap);
        before = address(this).balance;
        _modify(lower, lower + TICK_SPACING, 1e24);
        _sellPanicToPrice(stopAt);
        (, int24 tickAfter,,) = IPoolManager(address(manager)).getSlot0(poolId);
        assertEq(tickAfter, lower, "the sell ends inside the JIT range");
        _modify(lower, lower + TICK_SPACING, -1e24);
        uint256 jitGain = address(this).balance - before;

        assertLe(jitGain, plainGain, "no recapture");
        assertEq(_claimBalance(), hook.totalAccruedFees());
    }

    function test_forfeitedFeesGoToTheLiquidityThatStayed() public {
        int24 lower = 2200;
        _modify(lower, lower + TICK_SPACING, 1e24);
        _sellPanicToPrice(TickMath.getSqrtPriceAtTick(lower) + 1);
        (uint256 growthBefore,) = IPoolManager(address(manager)).getFeeGrowthGlobals(poolId);
        BalanceDelta removed = _modify(lower, lower + TICK_SPACING, -1e24);
        (uint256 growthAfter,) = IPoolManager(address(manager)).getFeeGrowthGlobals(poolId);
        assertGt(growthAfter, growthBefore, "forfeited ETH fees donated to the remaining liquidity");
        assertGt(removed.amount0(), 0, "principal is returned");
    }

    function test_positionHeldAcrossBlocksKeepsItsFees() public {
        _sellToDrawdown(2000);
        uint256 donation = hook.totalDonated();
        _nextBlock(12);
        BalanceDelta collected = _modify(TickMath.minUsableTick(TICK_SPACING), TickMath.maxUsableTick(TICK_SPACING), 0);
        assertApproxEqAbs(uint256(int256(collected.amount0())), donation, 1, "resident LP keeps the donation");
    }

    function test_secondAddInTheSameBlockCannotCollectFees() public {
        int24 lower = 2200;
        _modify(lower, lower + TICK_SPACING, 1e24);
        _sellPanicToPrice(TickMath.getSqrtPriceAtTick(lower) + 1);
        // Adding again would collect the fees earned since the first add; they are forfeited instead.
        uint256 ethBefore = address(this).balance;
        _modify(lower, lower + TICK_SPACING, 1);
        assertLe(address(this).balance, ethBefore, "no ETH fees paid out on the second add");
    }

    function test_withNoLiquidityLeftForfeitedFeesAreBucketedAndBurned() public {
        // Remove the resident position, then act as the only LP within one block.
        int24 minT = TickMath.minUsableTick(TICK_SPACING);
        int24 maxT = TickMath.maxUsableTick(TICK_SPACING);
        _modify(minT, maxT, -int256(uint256(FULL_RANGE_LIQUIDITY)));
        _nextBlock(12);
        _modify(minT, maxT, int256(uint256(FULL_RANGE_LIQUIDITY)));
        _sellPanic(1e21);
        _buyPanic(1e21);
        uint256 bucketBefore = hook.donationBucket();
        uint256 deadBefore = panic.balanceOf(DEAD);
        _modify(minT, maxT, -int256(uint256(FULL_RANGE_LIQUIDITY)));
        assertEq(IPoolManager(address(manager)).getLiquidity(poolId), 0);
        assertGt(hook.donationBucket(), bucketBefore, "ETH fees wait in the donation bucket");
        assertGt(panic.balanceOf(DEAD), deadBefore, "PANIC fees are burned");
        assertEq(_claimBalance(), hook.totalAccruedFees(), "bucket is backed by claims");
    }
}
