// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {PanicAccountingHandler} from "./handlers/PanicAccountingHandler.sol";
import {PanicTestBase} from "./utils/PanicTestBase.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {Vm} from "forge-std/Vm.sol";
import {PanicHook} from "src/PanicHook.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";

/// @dev No storage edits, mocked callbacks, RPC, or token minting after setup. Each campaign
/// starts at a flat price and can cross all tiers in either direction, in the same or later blocks.
abstract contract PanicAccountingInvariantBase is PanicTestBase {
    using CurrencyLibrary for Currency;
    using TransientStateLibrary for IPoolManager;

    PanicAccountingHandler internal handler;

    function _startCampaign() internal {
        _fundAndApprove();
        _addFullRangeLiquidity(FULL_RANGE_LIQUIDITY);
        // Actors' narrow positions live under a router of their own, apart from the resident full-range one.
        PoolModifyLiquidityTest actorLp = new PoolModifyLiquidityTest(IPoolManager(address(manager)));
        handler = new PanicAccountingHandler(hook, panic, IPoolManager(address(manager)), swapRouter, actorLp, key);
        for (uint256 i; i < 3; i++) {
            address actor = handler.actors(i);
            panic.transfer(actor, 1e25);
            vm.deal(actor, 1e25);
            if (!paired.isAddressZero()) MockERC20(Currency.unwrap(paired)).transfer(actor, 1e25);
            vm.startPrank(actor);
            panic.approve(address(swapRouter), type(uint256).max);
            panic.approve(address(actorLp), type(uint256).max);
            if (!paired.isAddressZero()) {
                MockERC20(Currency.unwrap(paired)).approve(address(swapRouter), type(uint256).max);
                MockERC20(Currency.unwrap(paired)).approve(address(actorLp), type(uint256).max);
            }
            vm.stopPrank();
        }
        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = handler.sell.selector;
        selectors[1] = handler.buy.selector;
        selectors[2] = handler.advance.selector;
        selectors[3] = handler.claim.selector;
        selectors[4] = handler.donate.selector;
        selectors[5] = handler.buyback.selector;
        selectors[6] = handler.transferPanic.selector;
        selectors[7] = handler.buyExactOutput.selector;
        selectors[8] = handler.addLiquidity.selector;
        selectors[9] = handler.removeLiquidity.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_conservationReferenceAndSupply() public view virtual {
        uint256 outstanding = hook.oracleFundBucket() + hook.donationBucket() + hook.burnBucket();
        assertEq(manager.balanceOf(address(hook), paired.toId()), outstanding, "every obligation backed by claims");
        assertEq(hook.totalAccruedFees(), outstanding);
        assertEq(
            outstanding + handler.claimed() + hook.totalDonated() + handler.spent(),
            handler.fees(),
            "all fees accounted for"
        );
        assertEq(hook.oracleFundBucket() + handler.claimed(), handler.expectedOracle(), "oracle allocation");
        assertEq(hook.donationBucket() + hook.totalDonated(), handler.expectedLp(), "LP allocation");
        assertEq(hook.burnBucket() + handler.spent(), handler.expectedBurn(), "burn allocation");
        assertEq(paired.balanceOf(oracleFund), handler.claimed(), "only the budget wallet receives claims");
        assertEq(panic.balanceOf(DEAD), handler.burned(), "all bought PANIC sent to dead address");
        assertEq(paired.balanceOf(address(hook)), 0, "no loose paired currency");
        assertEq(panic.balanceOf(address(hook)), 0, "no stranded PANIC");
        assertEq(hook.referenceTick(), handler.modelReferenceTick(), "one-hour independent reference");

        uint256 tracked = panic.balanceOf(address(this)) + panic.balanceOf(address(manager)) + panic.balanceOf(DEAD);
        for (uint256 i; i < 3; i++) {
            tracked += panic.balanceOf(handler.actors(i));
        }
        assertEq(tracked, 1_000_000_000 ether, "supply conserved across pool and all holders");
        assertEq(panic.totalSupply(), tracked);
        assertEq(panic.balanceOf(address(0)), 0);
        assertEq(panic.balanceOf(address(swapRouter)), 0);
        assertEq(panic.balanceOf(address(lpRouter)), 0);
        assertEq(panic.balanceOf(address(handler.lpRouter())), 0);
        assertEq(paired.balanceOf(address(handler.lpRouter())), 0, "LP router keeps no paired currency");
        assertEq(IPoolManager(address(manager)).getNonzeroDeltaCount(), 0, "all v4 debts settled");
        assertFalse(IPoolManager(address(manager)).isUnlocked(), "manager relocked after each action");
    }

    /// @dev Exercise successful and failed outlets deterministically so the campaign is not
    /// trusted merely because an empty bucket happened to satisfy the accounting identities.
    function test_handlerExercisesFundedAndRejectedOperations() public {
        handler.claim(0);
        handler.donate(1);
        handler.buyback(2, 0);
        handler.sell(0, 1200 ether);
        handler.buy(1, 1 ether);
        handler.buyback(2, 0.1 ether);
        handler.claim(1);
        handler.advance(3600);
        handler.buy(2, 200 ether);
        handler.buy(2, 200 ether);
        handler.buyback(0, 1 ether);
        assertEq(handler.successfulSwaps(), 4);
        assertGt(handler.successfulBuybacks(), 0);
        assertGe(handler.rejectedBuybacks(), 2);
        assertGt(handler.claimed(), 0);
        invariant_conservationReferenceAndSupply();
    }

    function test_handlerMixesExactOutputAndExactInputAcrossTheHour() public {
        handler.buyExactOutput(0, 1); // Smallest output, while not down.
        handler.sell(1, 1200 ether);
        handler.buyExactOutput(2, 1 ether); // Dip fee in the afterSwap return delta.
        handler.buy(0, 1 ether); // Dip fee in the beforeSwap return delta.
        handler.buyback(1, 0.1 ether);
        invariant_conservationReferenceAndSupply();
        handler.advance(3600);
        handler.buyExactOutput(0, 1 ether); // Flat for an hour: no hook fee again.
        handler.claim(2);
        assertEq(handler.successfulExactOutputBuys(), 3);
        assertEq(handler.successfulSwaps(), 5);
        invariant_conservationReferenceAndSupply();
    }

    /// @dev A trader's own narrow liquidity around fee-bearing trades, removed in the same block, returns
    /// principal only; a position held into the next block keeps the fees and in-swap donations it earned.
    function test_handlerLiquidityAroundTradesInAndAcrossBlocks() public {
        handler.addLiquidity(0, 1, 2, 1e21);
        handler.sell(0, 1200 ether);
        handler.buy(1, 1 ether);
        vm.recordLogs();
        handler.addLiquidity(0, 0, 0, 1e15); // Second add in the block: forfeits, pays exact principal.
        handler.removeLiquidity(0, 5e20); // Partial, same block.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool forfeited;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(hook) || logs[i].topics[0] != PanicHook.SameBlockFeesForfeited.selector) {
                continue;
            }
            (uint256 pairedFees, uint256 panicFees) = abi.decode(logs[i].data, (uint256, uint256));
            if (pairedFees + panicFees > 0) forfeited = true;
        }
        assertTrue(forfeited, "the same-block position had earned fees, and they were forfeited");
        handler.removeLiquidity(0, type(uint256).max); // Rest, same block.
        handler.addLiquidity(1, 0, 3, 1e21);
        handler.sell(2, 1200 ether);
        handler.donate(0);
        handler.advance(12);
        handler.buy(0, 1 ether);
        handler.removeLiquidity(1, type(uint256).max); // Held across a block: keeps fees.
        handler.buyback(2, 0.1 ether);
        handler.claim(0);
        assertEq(handler.liquidityAdds(), 3);
        assertEq(handler.sameBlockRemovals(), 2);
        assertEq(handler.laterRemovals(), 1);
        invariant_conservationReferenceAndSupply();
    }
}

contract PanicNativeInvariantTest is PanicAccountingInvariantBase {
    function setUp() public {
        _setUpNativePool(SQRT_PRICE_1_1);
        _startCampaign();
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_conservationReferenceAndSupply() public view override {
        super.invariant_conservationReferenceAndSupply();
    }
}

contract PanicCurrency0InvariantTest is PanicAccountingInvariantBase {
    function setUp() public {
        _setUpErc20Pool(true, SQRT_PRICE_1_1);
        _startCampaign();
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_conservationReferenceAndSupply() public view override {
        super.invariant_conservationReferenceAndSupply();
    }
}

contract PanicCurrency1InvariantTest is PanicAccountingInvariantBase {
    function setUp() public {
        _setUpErc20Pool(false, SQRT_PRICE_1_1);
        _startCampaign();
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_conservationReferenceAndSupply() public view override {
        super.invariant_conservationReferenceAndSupply();
    }
}
