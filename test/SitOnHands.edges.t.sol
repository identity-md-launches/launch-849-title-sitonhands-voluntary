// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SitOnHands} from "src/SitOnHands.sol";
import {MockIMD} from "./mocks/MockIMD.sol";

/// @dev Reads accounting from inside the token's outgoing-transfer callback.
contract WithdrawalObserver {
    SitOnHands internal immutable vault;
    uint256 internal immutable id;
    bool public observedWithdrawn;
    bool public observedCanWithdraw;
    uint256 public observedUserLocked;
    uint256 public observedTotalLocked;

    constructor(SitOnHands vault_, uint256 id_) {
        vault = vault_;
        id = id_;
    }

    function observe() external {
        (address depositor,,, bool withdrawn) = vault.positions(id);
        observedWithdrawn = withdrawn;
        observedCanWithdraw = vault.canWithdraw(id);
        observedUserLocked = vault.lockedBalance(depositor);
        observedTotalLocked = vault.totalLocked();
    }
}

/// forge-config: default.fuzz.runs = 1000
contract SitOnHandsEdgesTest is Test {
    MockIMD internal token;
    SitOnHands internal vault;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);

    function setUp() public {
        vm.warp(1_700_000_123);
        token = new MockIMD();
        vault = new SitOnHands(address(token));
    }

    function testOneWeiRoundTrip() public {
        _roundTrip(1, 1 days);
    }

    function testEntireUint256SupplyRoundTrip() public {
        _roundTrip(type(uint256).max, 365 days);
    }

    function testFuzzFullWidthAmountsReturnExactly(uint256 amount, uint256 duration) public {
        _roundTrip(bound(amount, 1, type(uint256).max), bound(duration, 1 days, 365 days));
    }

    function testFuzzAggregateAtUint256LimitDoesNotTruncate(uint256 firstAmount, bool reverseOrder) public {
        firstAmount = bound(firstAmount, 1, type(uint256).max - 1);
        uint256 secondAmount = type(uint256).max - firstAmount;
        _fund(ALICE, firstAmount);
        _fund(BOB, secondAmount);
        uint256 first = _lock(ALICE, firstAmount, 1 days);
        uint256 second = _lock(BOB, secondAmount, 1 days);
        assertEq(vault.totalLocked(), type(uint256).max);
        assertEq(token.balanceOf(address(vault)), type(uint256).max);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        _withdraw(reverseOrder ? BOB : ALICE, reverseOrder ? second : first);
        assertEq(vault.totalLocked(), reverseOrder ? firstAmount : secondAmount);
        _withdraw(reverseOrder ? ALICE : BOB, reverseOrder ? first : second);
        assertEq(token.balanceOf(ALICE), firstAmount);
        assertEq(token.balanceOf(BOB), secondAmount);
        assertEq(vault.totalLocked(), 0);
        assertEq(token.balanceOf(address(vault)), 0);
    }

    function testFuzzBothInvalidDurationRangesPreserveExistingLock(uint256 seed) public {
        _fund(ALICE, 100);
        uint256 id = _lock(ALICE, 40, 1 days);
        uint256 allowanceBefore = token.allowance(ALICE, address(vault));
        uint256[2] memory durations = [bound(seed, 0, 1 days - 1), bound(seed, 365 days + 1, type(uint256).max)];
        for (uint256 i; i < durations.length; ++i) {
            vm.expectRevert(SitOnHands.InvalidDuration.selector);
            vm.prank(ALICE);
            vault.lock(60, durations[i]);
        }
        assertEq(vault.nextPositionId(), 1);
        assertEq(vault.totalLocked(), 40);
        assertEq(vault.lockedBalance(ALICE), 40);
        assertEq(token.balanceOf(ALICE), 60);
        assertEq(token.balanceOf(address(vault)), 40);
        assertEq(token.allowance(ALICE, address(vault)), allowanceBefore);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        _withdraw(ALICE, id);
        assertEq(token.balanceOf(ALICE), 100);
    }

    function testFuzzUnknownIdsCannotSpendExistingPrincipal(uint256 seed) public {
        _fund(ALICE, 100);
        _lock(ALICE, 100, 1 days);
        uint256 id = bound(seed, 1, type(uint256).max);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        assertFalse(vault.canWithdraw(id));
        vm.expectRevert(SitOnHands.UnknownPosition.selector);
        vm.prank(ALICE);
        vault.withdraw(id);
        assertEq(vault.totalLocked(), 100);
        assertEq(token.balanceOf(address(vault)), 100);
        _withdraw(ALICE, 0);
        assertEq(token.balanceOf(ALICE), 100);
    }

    function testRevokedAllowanceAndEmptyWalletDoNotBlockMatureWithdrawal() public {
        _fund(ALICE, 100);
        uint256 id = _lock(ALICE, 60, 1 days);
        vm.startPrank(ALICE);
        token.approve(address(vault), 0);
        token.transfer(BOB, 40);
        vm.stopPrank();
        assertEq(token.balanceOf(ALICE), 0);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        _withdraw(ALICE, id);
        assertEq(token.balanceOf(ALICE), 60);
        assertEq(token.balanceOf(BOB), 40);
        assertEq(token.allowance(ALICE, address(vault)), 0);
        assertEq(vault.totalLocked(), 0);
    }

    function testApprovedTokenSpenderCannotTakePosition() public {
        _fund(ALICE, 100);
        uint256 id = _lock(ALICE, 100, 1 days);
        vm.prank(ALICE);
        token.approve(BOB, type(uint256).max);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.expectRevert(SitOnHands.NotDepositor.selector);
        vm.prank(BOB);
        vault.withdraw(id);
        _withdraw(ALICE, id);
        assertEq(token.balanceOf(ALICE), 100);
        assertEq(token.balanceOf(BOB), 0);
    }

    function testCallerOwnsPositionEvenWhenOriginDiffers() public {
        // ALICE can also represent a smart wallet invoked by BOB.
        _fund(ALICE, 100);
        vm.prank(ALICE, BOB);
        uint256 id = vault.lock(100, 1 days);
        (address depositor,,,) = vault.positions(id);
        assertEq(depositor, ALICE);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.expectRevert(SitOnHands.NotDepositor.selector);
        vm.prank(BOB, ALICE);
        vault.withdraw(id);
        vm.prank(ALICE, BOB);
        vault.withdraw(id);
        assertEq(token.balanceOf(ALICE), 100);
        assertEq(token.balanceOf(BOB), 0);
    }

    function testMaturedPrincipalRemainsOwedWithoutExpiryOrYield() public {
        _fund(ALICE, 100);
        uint256 id = _lock(ALICE, 100, 365 days);
        vm.warp(vm.getBlockTimestamp() + 100 * 365 days);
        assertTrue(vault.canWithdraw(id));
        assertEq(vault.lockedBalance(ALICE), 100);
        assertEq(vault.totalLocked(), 100);
        assertEq(token.balanceOf(ALICE), 0);
        _withdraw(ALICE, id);
        assertEq(token.balanceOf(ALICE), 100);
    }

    function testWithdrawEffectsAreVisibleBeforeTokenCallback() public {
        _fund(ALICE, 100);
        _fund(BOB, 200);
        uint256 id = _lock(ALICE, 60, 1 days);
        _lock(ALICE, 40, 2 days);
        _lock(BOB, 200, 2 days);
        WithdrawalObserver observer = new WithdrawalObserver(vault, id);
        token.setHook(address(observer), abi.encodeCall(observer.observe, ()));
        vm.warp(vm.getBlockTimestamp() + 1 days);
        _withdraw(ALICE, id);
        assertTrue(token.hookSucceeded(), "observer must actually run");
        assertTrue(observer.observedWithdrawn());
        assertFalse(observer.observedCanWithdraw());
        assertEq(observer.observedUserLocked(), 40);
        assertEq(observer.observedTotalLocked(), 240);
        assertEq(token.balanceOf(ALICE), 60);
    }

    function testRepeatedFullBalanceRelocksNeverReuseIdsOrPayOldClaims() public {
        _fund(ALICE, 100);
        for (uint256 i; i < 12; ++i) {
            vm.prank(ALICE);
            token.approve(address(vault), 100);
            uint256 id = _lock(ALICE, 100, 1 days);
            assertEq(id, i);
            if (i != 0) {
                vm.expectRevert(SitOnHands.AlreadyWithdrawn.selector);
                vm.prank(ALICE);
                vault.withdraw(i - 1);
                assertEq(token.balanceOf(address(vault)), 100);
            }
            vm.warp(vm.getBlockTimestamp() + 1 days);
            _withdraw(ALICE, id);
            assertEq(token.balanceOf(ALICE), 100);
            assertEq(vault.totalLocked(), 0);
            assertEq(token.totalSupply(), 100);
        }
        assertEq(vault.nextPositionId(), 12);
    }

    function _roundTrip(uint256 amount, uint256 duration) internal {
        _fund(ALICE, amount);
        uint256 deadline = vm.getBlockTimestamp() + duration;
        uint256 id = _lock(ALICE, amount, duration);
        (address depositor, uint256 storedAmount, uint256 storedDeadline, bool withdrawn) = vault.positions(id);
        assertEq(depositor, ALICE);
        assertEq(storedAmount, amount);
        assertEq(storedDeadline, deadline);
        assertFalse(withdrawn);
        assertEq(vault.lockedBalance(ALICE), amount);
        assertEq(vault.totalLocked(), amount);
        assertEq(token.balanceOf(ALICE), 0);
        vm.warp(deadline - 1);
        vm.expectRevert(abi.encodeWithSelector(SitOnHands.StillLocked.selector, deadline));
        vm.prank(ALICE);
        vault.withdraw(id);
        vm.warp(deadline);
        _withdraw(ALICE, id);
        assertEq(token.balanceOf(ALICE), amount);
        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(vault.lockedBalance(ALICE), 0);
        assertEq(vault.totalLocked(), 0);
        assertEq(token.totalSupply(), amount);
        assertFalse(vault.canWithdraw(id));
    }

    function _fund(address actor, uint256 amount) internal {
        token.mint(actor, amount);
        vm.prank(actor);
        token.approve(address(vault), amount);
    }

    function _lock(address actor, uint256 amount, uint256 duration) internal returns (uint256) {
        vm.prank(actor);
        return vault.lock(amount, duration);
    }

    function _withdraw(address actor, uint256 id) internal {
        vm.prank(actor);
        vault.withdraw(id);
    }
}
