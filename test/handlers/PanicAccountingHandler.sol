// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {PanicHook} from "src/PanicHook.sol";
import {PanicMonkeys} from "src/PanicMonkeys.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";

/// @dev Ghost amounts come from pool Swap events and actual wallet transfers, not hook buckets.
/// The TWAP model integrates the independently recorded spot-price timeline, without reading
/// the hook's observations or cumulative ticks. All actions use real swaps and settlement.
contract PanicAccountingHandler is Test {
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;

    bytes32 constant SWAP_EVENT = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
    address constant DEAD = address(0xdEaD);
    PanicHook public immutable hook;
    PanicMonkeys public immutable panic;
    IPoolManager public immutable manager;
    PoolSwapTest public immutable router;
    PoolModifyLiquidityTest public immutable lpRouter;
    Currency public paired;
    PoolKey private key;
    bool private immutable panicIs0;
    address[3] public actors;

    uint256 public fees;
    uint256 public expectedOracle;
    uint256 public expectedLp;
    uint256 public expectedBurn;
    uint256 public claimed;
    uint256 public spent;
    uint256 public burned;
    uint256 public successfulSwaps;
    uint256 public successfulExactOutputBuys;
    uint256 public successfulBuybacks;
    uint256 public rejectedBuybacks;
    uint256 public liquidityAdds;
    uint256 public sameBlockRemovals;
    uint256 public laterRemovals;

    /// @dev One narrow position per actor (salt = actor), tracked independently of the hook.
    struct Range {
        int24 lower;
        int24 upper;
        uint128 liquidity;
        uint256 addedBlock;
    }
    mapping(address => Range) public ranges;

    struct Spot {
        uint256 time;
        int24 tick;
    }
    Spot[] private spots;
    uint256 private referenceBlock;
    int24 private frozenReference;
    int24 private immutable launchTick;

    constructor(
        PanicHook h,
        PanicMonkeys p,
        IPoolManager m,
        PoolSwapTest r,
        PoolModifyLiquidityTest lr,
        PoolKey memory k
    ) {
        hook = h;
        panic = p;
        manager = m;
        router = r;
        lpRouter = lr;
        key = k;
        panicIs0 = Currency.unwrap(k.currency0) == address(p);
        paired = panicIs0 ? k.currency1 : k.currency0;
        actors = [address(0xA11CE), address(0xB0B), address(0xCA401)];
        (, int24 tick,,) = manager.getSlot0(k.toId());
        spots.push(Spot(block.timestamp, tick));
        referenceBlock = block.number;
        frozenReference = tick;
        launchTick = tick;
    }

    function advance(uint256 secondsSeed) external {
        vm.warp(block.timestamp + bound(secondsSeed, 0, 7200));
        vm.roll(block.number + 1);
    }

    function sell(uint256 actorSeed, uint256 amountSeed) external {
        address actor = actors[actorSeed % 3];
        uint256 maximum = panic.balanceOf(actor);
        if (maximum == 0) return;
        if (maximum > 1200 ether) maximum = 1200 ether;
        uint256 amount = bound(amountSeed, 1, maximum);
        _trade(actor, false, amount, false);
    }

    function buy(uint256 actorSeed, uint256 amountSeed) external {
        _trade(actors[actorSeed % 3], true, bound(amountSeed, 1, 200 ether), false);
    }

    function buyExactOutput(uint256 actorSeed, uint256 amountSeed) external {
        (uint160 sqrt,,,) = manager.getSlot0(key.toId());
        uint256 liquidity = manager.getLiquidity(key.toId());
        uint256 reserve =
            panicIs0 ? FullMath.mulDiv(liquidity, 1 << 96, sqrt) : FullMath.mulDiv(liquidity, sqrt, 1 << 96);
        // Request at most 1% of the virtual reserve to keep exact output reachable throughout a sequence.
        uint256 maximum = reserve / 100;
        if (maximum > 100 ether) maximum = 100 ether;
        assertGt(maximum, 0, "campaign retains usable full-range liquidity");
        _trade(actors[actorSeed % 3], true, bound(amountSeed, 1, maximum), true);
        successfulExactOutputBuys++;
    }

    function _trade(address actor, bool isBuy, uint256 amount, bool exactOutput) private {
        uint160 referencePrice = _freezeReference();
        (uint160 beforePrice,,,) = manager.getSlot0(key.toId());
        uint256 pairedBefore = paired.balanceOf(actor);
        uint256 panicBefore = panic.balanceOf(actor);
        uint256 observationsBefore = hook.observationCount();
        bool alreadyObserved = hook.lastObservedBlock() == block.number;
        bool zeroForOne = isBuy != panicIs0;

        vm.recordLogs();
        vm.prank(actor);
        uint256 value = isBuy && paired.isAddressZero() ? (exactOutput ? actor.balance : amount) : 0;
        BalanceDelta d = router.swap{value: value}(
            key,
            SwapParams(
                zeroForOne,
                exactOutput ? int256(amount) : -int256(amount),
                zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        (uint256 poolAmount, uint160 afterPrice) = _poolSwap(vm.getRecordedLogs(), isBuy);
        uint256 actualFee;
        if (isBuy) {
            uint256 paid = pairedBefore - paired.balanceOf(actor);
            actualFee = paid - poolAmount;
            uint256 expected = _drawdown(beforePrice, referencePrice) >= 500 ? poolAmount / 100 : 0;
            if (exactOutput) {
                assertEq(panic.balanceOf(actor) - panicBefore, amount, "exact output delivered");
                assertEq(actualFee, expected, "exact output fee on realised paired input");
            } else {
                assertEq(paid, amount, "exact input buy budget");
                // Reserving a fee from an inclusive input budget can round down one extra wei.
                assertLe(actualFee, expected);
                assertLe(expected - actualFee, 1);
            }
            assertEq(paid, uint256(-int256(panicIs0 ? d.amount1() : d.amount0())), "wallet input matches delta");
            assertEq(panic.balanceOf(actor) - panicBefore, uint256(uint128(panicIs0 ? d.amount0() : d.amount1())));
        } else {
            actualFee = poolAmount - (paired.balanceOf(actor) - pairedBefore);
            uint256 dd = _drawdown(afterPrice, referencePrice);
            uint256 rate = dd < 500 ? 200 : dd < 1500 ? 1000 : dd < 3000 ? 2000 : 3000;
            assertEq(actualFee, poolAmount * rate / 10_000, "sell judged after execution");
            assertEq(panicBefore - panic.balanceOf(actor), amount);
        }
        assertLe(actualFee * 10_000, poolAmount * 3000, "fee ceiling");
        _accrue(actualFee);
        successfulSwaps++;
        assertEq(hook.referenceSqrtPriceX96(), referencePrice, "current block cannot change reference");
        assertLe(hook.observationCount() - observationsBefore, alreadyObserved ? 0 : 1);
        _recordSpot();
    }

    function claim(uint256 actorSeed) external {
        address actor = actors[actorSeed % 3];
        uint256 due = expectedOracle - claimed;
        uint256 beforeBalance = paired.balanceOf(hook.oracleFund());
        vm.prank(actor);
        if (due == 0) {
            vm.expectRevert(PanicHook.NothingToClaim.selector);
            hook.claimOracleFund();
        } else {
            assertEq(hook.claimOracleFund(), due);
            claimed += due;
        }
        assertEq(paired.balanceOf(hook.oracleFund()) - beforeBalance, due, "fixed recipient receives all claims");
    }

    function donate(uint256 actorSeed) external {
        uint256 pending = hook.donationBucket();
        vm.prank(actors[actorSeed % 3]);
        if (pending == 0) {
            vm.expectRevert(PanicHook.NothingToDonate.selector);
            hook.donateToLiquidityProviders();
        } else {
            assertEq(hook.donateToLiquidityProviders(), pending);
        }
    }

    function buyback(uint256 actorSeed, uint256 maxSpendSeed) external {
        uint256 limit = bound(maxSpendSeed, 0, 2 ether);
        uint256 previousReferenceBlock = referenceBlock;
        int24 previousFrozen = frozenReference;
        uint160 referencePrice = _freezeReference();
        (uint160 priceBefore,,,) = manager.getSlot0(key.toId());
        uint256 bucket = hook.burnBucket();
        uint256 deadBefore = panic.balanceOf(DEAD);
        bytes32 beforeState = _stateHash();
        vm.recordLogs();
        vm.prank(actors[actorSeed % 3]);
        try hook.buybackAndBurn(limit) returns (uint256 used, uint256 bought) {
            (uint256 poolInput,) = _poolSwap(vm.getRecordedLogs(), true);
            uint256 fee = used - poolInput;
            uint256 expectedFee = _drawdown(priceBefore, referencePrice) >= 500 ? poolInput / 100 : 0;
            assertLe(fee, expectedFee, "buyback fee ceiling");
            assertLe(expectedFee - fee, 1, "buybacks receive no fee exemption");
            assertLe(used, limit);
            assertLe(used, 1 ether);
            assertLe(used, bucket);
            assertGt(bought, 0);
            assertEq(panic.balanceOf(DEAD) - deadBefore, bought);
            // These campaigns stay near parity, where the square fits in uint256. A single
            // division provides an independent quote without calling the hook's conversion helper.
            uint256 square = uint256(referencePrice) * uint256(referencePrice);
            uint256 implied =
                panicIs0 ? FullMath.mulDiv(used, 1 << 192, square) : FullMath.mulDiv(used, square, 1 << 192);
            assertGe(bought * 10_000, implied * 9800, "98% reference output floor, including dust budgets");
            _accrue(fee);
            spent += used;
            burned += bought;
            successfulBuybacks++;
            assertEq(hook.referenceSqrtPriceX96(), referencePrice);
            _recordSpot();
        } catch (bytes memory reason) {
            vm.getRecordedLogs();
            if (bucket == 0 || limit == 0) {
                assertEq(bytes4(reason), PanicHook.NothingToBuyBack.selector);
            } else {
                assertEq(bytes4(reason), PanicHook.BuybackBelowReference.selector, "no unexpected buyback failure");
            }
            assertEq(_stateHash(), beforeState, "failed buyback rolls back every effect");
            referenceBlock = previousReferenceBlock;
            frozenReference = previousFrozen;
            rejectedBuybacks++;
        }
    }

    function transferPanic(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        address from = actors[fromSeed % 3];
        address to = actors[toSeed % 3];
        uint256 amount = bound(amountSeed, 0, panic.balanceOf(from) / 2);
        uint256 fromBefore = panic.balanceOf(from);
        uint256 toBefore = panic.balanceOf(to);
        vm.prank(from);
        assertTrue(panic.transfer(to, amount));
        assertEq(panic.balanceOf(from), from == to ? fromBefore : fromBefore - amount);
        assertEq(panic.balanceOf(to), from == to ? toBefore : toBefore + amount);
    }

    /// @dev Adds narrow liquidity around the current tick, possibly to a position already added to in
    /// this block. Fees the position earned since a same-block add are forfeited, so the actor then pays
    /// exactly the rounded-up principal.
    function addLiquidity(uint256 actorSeed, uint256 offsetSeed, uint256 widthSeed, uint256 liquiditySeed) external {
        address actor = actors[actorSeed % 3];
        Range storage r = ranges[actor];
        if (r.liquidity == 0) {
            int24 spacing = key.tickSpacing;
            (, int24 tick,,) = manager.getSlot0(key.toId());
            int24 base = tick / spacing * spacing;
            if (tick < 0 && tick % spacing != 0) base -= spacing;
            r.lower = base - int24(int256(bound(offsetSeed, 0, 4))) * spacing;
            r.upper = base + int24(int256(bound(widthSeed, 1, 5))) * spacing;
        }
        uint128 liquidity = uint128(bound(liquiditySeed, 1e15, 1e22));
        bool sameBlock = r.liquidity > 0 && r.addedBlock == block.number;
        if (r.liquidity > 0 && !sameBlock) {
            // Collect fees from an earlier block first with a zero-liquidity poke, which the hook leaves alone;
            // the test router cannot settle an add whose fees exceed its principal on one side.
            (uint256 owed0, uint256 owed1) = (key.currency0.balanceOf(actor), key.currency1.balanceOf(actor));
            vm.prank(actor);
            lpRouter.modifyLiquidity(key, ModifyLiquidityParams(r.lower, r.upper, 0, _salt(actor)), "");
            assertGe(key.currency0.balanceOf(actor), owed0, "poke only pays out");
            assertGe(key.currency1.balanceOf(actor), owed1, "poke only pays out");
        }
        (uint256 need0, uint256 need1) = _principal(r.lower, r.upper, liquidity, true);
        uint256 before0 = key.currency0.balanceOf(actor);
        uint256 before1 = key.currency1.balanceOf(actor);
        bytes32 beforeBuckets = _bucketHash();
        vm.prank(actor);
        lpRouter.modifyLiquidity{value: key.currency0.isAddressZero() ? need0 + 1 : 0}(
            key, ModifyLiquidityParams(r.lower, r.upper, int256(uint256(liquidity)), _salt(actor)), ""
        );
        // A same-block add forfeits the fees earned since the earlier add, so it pays exactly principal too.
        assertEq(before0 - key.currency0.balanceOf(actor), need0, "add pays exactly principal0");
        assertEq(before1 - key.currency1.balanceOf(actor), need1, "add pays exactly principal1");
        // Full-range liquidity is always in range, so forfeited fees are donated, never bucketed.
        assertEq(_bucketHash(), beforeBuckets, "liquidity changes leave fee buckets untouched");
        r.liquidity += liquidity;
        r.addedBlock = block.number;
        liquidityAdds++;
    }

    /// @dev Removes part or all of an actor's position. Within the block of its last add, the actor
    /// receives exactly the rounded-down principal: every fee earned in between is forfeited.
    function removeLiquidity(uint256 actorSeed, uint256 amountSeed) external {
        address actor = actors[actorSeed % 3];
        Range storage r = ranges[actor];
        if (r.liquidity == 0) return;
        uint128 liquidity = uint128(bound(amountSeed, 1, r.liquidity));
        if (liquidity < 1e15 && liquidity != r.liquidity) liquidity = r.liquidity;
        bool sameBlock = r.addedBlock == block.number;
        (uint256 out0, uint256 out1) = _principal(r.lower, r.upper, liquidity, false);
        if (out0 == 0 && out1 == 0) return; // The test router asserts on an empty withdrawal.
        uint256 before0 = key.currency0.balanceOf(actor);
        uint256 before1 = key.currency1.balanceOf(actor);
        bytes32 beforeBuckets = _bucketHash();
        vm.prank(actor);
        lpRouter.modifyLiquidity(
            key, ModifyLiquidityParams(r.lower, r.upper, -int256(uint256(liquidity)), _salt(actor)), ""
        );
        uint256 got0 = key.currency0.balanceOf(actor) - before0;
        uint256 got1 = key.currency1.balanceOf(actor) - before1;
        if (sameBlock) {
            assertEq(got0, out0, "same-block removal returns principal0 only");
            assertEq(got1, out1, "same-block removal returns principal1 only");
            sameBlockRemovals++;
        } else {
            assertGe(got0, out0, "a position held across blocks keeps its fees");
            assertGe(got1, out1);
            laterRemovals++;
        }
        assertEq(_bucketHash(), beforeBuckets, "liquidity changes leave fee buckets untouched");
        r.liquidity -= liquidity;
    }

    function _principal(int24 lower, int24 upper, uint128 liquidity, bool roundUp)
        private
        view
        returns (uint256 amount0, uint256 amount1)
    {
        (uint160 sqrt,,,) = manager.getSlot0(key.toId());
        uint160 a = TickMath.getSqrtPriceAtTick(lower);
        uint160 b = TickMath.getSqrtPriceAtTick(upper);
        if (sqrt <= a) {
            amount0 = SqrtPriceMath.getAmount0Delta(a, b, liquidity, roundUp);
        } else if (sqrt < b) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrt, b, liquidity, roundUp);
            amount1 = SqrtPriceMath.getAmount1Delta(a, sqrt, liquidity, roundUp);
        } else {
            amount1 = SqrtPriceMath.getAmount1Delta(a, b, liquidity, roundUp);
        }
    }

    function _salt(address actor) private pure returns (bytes32) {
        return bytes32(uint256(uint160(actor)));
    }

    function _bucketHash() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                hook.oracleFundBucket(),
                hook.donationBucket(),
                hook.burnBucket(),
                hook.totalDonated(),
                manager.balanceOf(address(hook), paired.toId())
            )
        );
    }

    function modelReferenceTick() public view returns (int24) {
        if (referenceBlock == block.number) return frozenReference;
        uint256 start = block.timestamp - 3600;
        int256 sum;
        if (start < spots[0].time) sum = int256(launchTick) * int256(spots[0].time - start);
        for (uint256 i; i < spots.length; i++) {
            uint256 lo = spots[i].time > start ? spots[i].time : start;
            uint256 hi = i + 1 < spots.length ? spots[i + 1].time : block.timestamp;
            if (hi > lo) sum += int256(spots[i].tick) * int256(hi - lo);
        }
        int256 mean = sum / 3600;
        if (sum < 0 && sum % 3600 != 0) mean--;
        return int24(mean);
    }

    function _freezeReference() private returns (uint160) {
        int24 expected = modelReferenceTick();
        assertEq(hook.referenceTick(), expected, "independent one-hour spot integral");
        referenceBlock = block.number;
        frozenReference = expected;
        return TickMath.getSqrtPriceAtTick(expected);
    }

    function _recordSpot() private {
        (, int24 tick,,) = manager.getSlot0(key.toId());
        if (spots[spots.length - 1].time == block.timestamp) spots[spots.length - 1].tick = tick;
        else spots.push(Spot(block.timestamp, tick));
    }

    function _drawdown(uint160 live, uint160 ref) private view returns (uint256) {
        (uint256 num, uint256 den) = panicIs0 ? (uint256(live), uint256(ref)) : (uint256(ref), uint256(live));
        if (num >= den) return 0;
        return (den * den - num * num) * 10_000 / (den * den);
    }

    function _accrue(uint256 fee) private {
        fees += fee;
        expectedLp += fee * 3 / 10;
        expectedBurn += fee / 10;
        expectedOracle += fee - fee * 3 / 10 - fee / 10;
    }

    function _poolSwap(Vm.Log[] memory logs, bool isBuy) private view returns (uint256 amount, uint160 sqrt) {
        uint256 count;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(manager) || logs[i].topics[0] != SWAP_EVENT) continue;
            assertEq(logs[i].topics[1], PoolId.unwrap(key.toId()));
            (int128 d0, int128 d1, uint160 price,,,) =
                abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
            int256 delta = panicIs0 ? int256(d1) : int256(d0);
            amount = uint256(isBuy ? -delta : delta);
            sqrt = price;
            count++;
        }
        assertEq(count, 1, "exactly one real pool swap");
    }

    function _stateHash() private view returns (bytes32) {
        (uint160 sqrt, int24 tick,,) = manager.getSlot0(key.toId());
        (uint256 growth0, uint256 growth1) = manager.getFeeGrowthGlobals(key.toId());
        return keccak256(
            abi.encode(
                hook.oracleFundBucket(),
                hook.donationBucket(),
                hook.burnBucket(),
                hook.totalDonated(),
                manager.balanceOf(address(hook), paired.toId()),
                paired.balanceOf(address(manager)),
                panic.balanceOf(address(manager)),
                panic.balanceOf(DEAD),
                sqrt,
                tick,
                hook.observationCount(),
                hook.lastObservedBlock(),
                hook.lastObservedTick(),
                growth0,
                growth1
            )
        );
    }
}
