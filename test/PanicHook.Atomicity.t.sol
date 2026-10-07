// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PanicHook} from "src/PanicHook.sol";
import {PanicTestBase} from "./utils/PanicTestBase.sol";

/// @dev Reuse the real-manager fixture; every rejection is followed by a successful operation.
abstract contract PanicHookAtomicityBase is PanicTestBase {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    function _seed() internal {
        _fundAndApprove();
        _addFullRangeLiquidity(FULL_RANGE_LIQUIDITY);
    }

    function test_rejectedFirstSwapRollsBackObservationAndNextSwapRecovers() public {
        _sellToDrawdown(1000);
        _nextBlock(12);
        uint160 referenceBefore = hook.referenceSqrtPriceX96();
        (uint160 price, int24 tick,,) = IPoolManager(address(manager)).getSlot0(poolId);
        uint256 count = hook.observationCount();
        bytes32 beforeState = _stateHash();
        uint160 closeLimit = panicIs0 ? price + price / 10_000 : price - price / 10_000;

        // This gets through beforeSwap and pool.swap, then fails in afterSwap.
        vm.expectRevert(
            _wrappedHookRevert(
                IHooks.afterSwap.selector, abi.encodeWithSelector(PanicHook.PartialExactInputBuyNotSupported.selector)
            )
        );
        _swap(!panicIs0, -100 ether, closeLimit);
        assertEq(_stateHash(), beforeState, "failed fill leaves no persistent effects");
        _assertSettled();

        uint256 feesBefore = _feesWithDonations();
        BalanceDelta d = _buyPanicExactOut(1 ether);
        uint256 fee = _feesWithDonations() - feesBefore;
        uint256 input = uint256(-int256(_pairedAmount(d)));
        assertGt(fee, 0);
        assertEq(fee, (input - fee) / 100, "next swap uses its own exact-output fee context");
        assertEq(panicIs0 ? d.amount0() : d.amount1(), 1 ether);
        assertEq(hook.observationCount(), count + 1);
        assertEq(hook.lastObservedTick(), tick, "the successful swap records the original price");
        assertEq(hook.referenceSqrtPriceX96(), referenceBefore);

        _sellPanic(1 ether);
        assertEq(hook.observationCount(), count + 1, "one observation despite failure and two successes");
        assertEq(hook.referenceSqrtPriceX96(), referenceBefore);
        _assertSettled();
    }

    function test_rejectedExactOutputSellCannotPoisonNextExactInputSell() public {
        _nextBlock(12);
        bytes32 beforeState = _stateHash();
        vm.expectRevert(
            _wrappedHookRevert(
                IHooks.beforeSwap.selector, abi.encodeWithSelector(PanicHook.ExactOutputSellNotSupported.selector)
            )
        );
        _swap(panicIs0, 1 ether, _noLimit(panicIs0));
        assertEq(_stateHash(), beforeState);

        uint256 feesBefore = _feesWithDonations();
        BalanceDelta d = _sellPanic(1 ether);
        uint256 fee = _feesWithDonations() - feesBefore;
        assertGt(fee, 0);
        assertEq(fee, _grossOutput(d, fee) * 2 / 100);
        assertEq(hook.observationCount(), 2);
        _assertSettled();
    }

    function test_zeroSwapsRollbackInBothDirectionsAndDoNotReserveTheBlock() public {
        _nextBlock(12);
        bytes32 beforeState = _stateHash();
        for (uint256 i; i < 2; i++) {
            bool zeroForOne = i == 0;
            vm.expectRevert(IPoolManager.SwapAmountCannotBeZero.selector);
            _swap(zeroForOne, 0, _noLimit(zeroForOne));
            assertEq(_stateHash(), beforeState);
            _assertSettled();
        }
        _buyPanic(1 ether);
        assertEq(hook.observationCount(), 2);
        assertEq(_feesWithDonations(), 0);
        _assertSettled();
    }

    function test_failedBuybackRestoresFeeGrowthAndOracleThenRecoversAfterAnHour() public {
        _sellPanic(100 ether);
        _buyPanic(600 ether);
        _nextBlock(12);
        uint256 budget = hook.burnBucket();
        assertGt(budget, 0);
        uint160 ref = hook.referenceSqrtPriceX96();
        uint256 liveSquare = uint256(_sqrtPrice()) * _sqrtPrice();
        uint256 refSquare = uint256(ref) * ref;
        assertGt(panicIs0 ? liveSquare * 100 : refSquare * 100, panicIs0 ? refSquare * 102 : liveSquare * 102);
        bytes32 beforeState = _stateHash();

        vm.expectPartialRevert(PanicHook.BuybackBelowReference.selector);
        hook.buybackAndBurn();
        assertEq(_stateHash(), beforeState, "output-floor failure rolls back the entire internal swap");
        _assertSettled();

        _nextBlock(3600);
        uint256 deadBefore = panic.balanceOf(DEAD);
        vm.prank(trader);
        (uint256 spent, uint256 burned) = hook.buybackAndBurn();
        assertEq(spent, budget, "the rejected attempt did not consume the small bucket");
        assertGt(burned, 0);
        assertEq(panic.balanceOf(DEAD) - deadBefore, burned);
        assertEq(panic.balanceOf(trader), 0);
        assertEq(hook.burnBucket(), 0);
        _assertSettled();
    }

    function _assertSettled() internal view {
        IPoolManager pm = IPoolManager(address(manager));
        assertEq(_claimBalance(), hook.totalAccruedFees());
        assertEq(pm.getNonzeroDeltaCount(), 0);
        assertFalse(pm.isUnlocked());
        assertEq(_pairedBalance(address(hook)), 0);
        assertEq(panic.balanceOf(address(hook)), 0);
    }

    function _stateHash() internal view returns (bytes32) {
        (uint160 sqrt, int24 tick,,) = IPoolManager(address(manager)).getSlot0(poolId);
        (uint256 growth0, uint256 growth1) = IPoolManager(address(manager)).getFeeGrowthGlobals(poolId);
        uint256 count = hook.observationCount();
        (uint32 timestamp, int56 cumulative) = hook.observations(count - 1);
        return keccak256(
            abi.encode(
                sqrt,
                tick,
                growth0,
                growth1,
                hook.oracleFundBucket(),
                hook.donationBucket(),
                hook.burnBucket(),
                hook.totalDonated(),
                _claimBalance(),
                count,
                timestamp,
                cumulative,
                hook.lastObservedBlock(),
                hook.lastObservedTick(),
                hook.referenceTick(),
                _pairedBalance(address(this)),
                _pairedBalance(address(manager)),
                _pairedBalance(address(swapRouter)),
                _pairedBalance(oracleFund),
                panic.balanceOf(address(this)),
                panic.balanceOf(address(manager)),
                panic.balanceOf(address(swapRouter)),
                panic.balanceOf(DEAD)
            )
        );
    }
}

contract PanicNativeAtomicityTest is PanicHookAtomicityBase {
    function setUp() public {
        _setUpNativePool(SQRT_PRICE_1_1);
        _seed();
    }

    function test_recipientCannotReenterClaimOrSpendAnotherBucketDuringPayout() public {
        _sellToDrawdown(2000);
        _nextBlock(12);
        OracleReentryProbe implementation = new OracleReentryProbe(hook);
        vm.etch(oracleFund, address(implementation).code);
        uint256 oracleDue = hook.oracleFundBucket();
        uint256 burnBefore = hook.burnBucket();
        uint256 observationsBefore = hook.observationCount();
        uint256 claimsBefore = _claimBalance();
        uint256 deadBefore = panic.balanceOf(DEAD);
        uint256 donatedBefore = hook.totalDonated();
        uint160 priceBefore = _sqrtPrice();
        uint160 refBefore = hook.referenceSqrtPriceX96();

        vm.prank(trader);
        assertEq(hook.claimOracleFund(), oracleDue);
        OracleReentryProbe receiver = OracleReentryProbe(payable(oracleFund));
        assertFalse(receiver.claimSucceeded());
        assertEq(receiver.claimError(), PanicHook.NothingToClaim.selector);
        assertFalse(receiver.buybackSucceeded());
        assertEq(receiver.buybackError(), IPoolManager.AlreadyUnlocked.selector);
        assertEq(oracleFund.balance, oracleDue, "exactly one payout");
        assertEq(hook.oracleFundBucket(), 0);
        assertEq(_claimBalance(), claimsBefore - oracleDue);
        assertEq(hook.burnBucket(), burnBefore);
        assertEq(hook.totalDonated(), donatedBefore);
        assertEq(panic.balanceOf(DEAD), deadBefore);
        assertEq(hook.observationCount(), observationsBefore);
        assertEq(_sqrtPrice(), priceBefore);
        assertEq(hook.referenceSqrtPriceX96(), refBefore);
        _assertSettled();

        (uint256 spent, uint256 burned) = hook.buybackAndBurn(0.1 ether);
        assertEq(spent, 0.1 ether, "legitimate buyback remains usable after reentry failure");
        assertEq(panic.balanceOf(DEAD) - deadBefore, burned);
        _assertSettled();
    }
}

contract PanicCurrency0AtomicityTest is PanicHookAtomicityBase {
    function setUp() public {
        _setUpErc20Pool(true, SQRT_PRICE_1_1);
        _seed();
    }
}

contract PanicCurrency1AtomicityTest is PanicHookAtomicityBase {
    function setUp() public {
        _setUpErc20Pool(false, SQRT_PRICE_1_1);
        _seed();
    }
}

/// @dev Models a contract at the fixed recipient; immutable target survives relocating its code.
contract OracleReentryProbe {
    PanicHook private immutable hook;
    bool public claimSucceeded;
    bool public buybackSucceeded;
    bytes4 public claimError;
    bytes4 public buybackError;

    constructor(PanicHook h) {
        hook = h;
    }

    receive() external payable {
        bytes memory reason;
        (claimSucceeded, reason) = address(hook).call(abi.encodeCall(hook.claimOracleFund, ()));
        claimError = bytes4(reason);
        (buybackSucceeded, reason) = address(hook).call(abi.encodeWithSignature("buybackAndBurn()"));
        buybackError = bytes4(reason);
    }
}
