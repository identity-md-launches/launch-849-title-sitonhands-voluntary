// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SitOnHands} from "../src/SitOnHands.sol";
import {MockIMD} from "./mocks/MockIMD.sol";

contract SitOnHandsTest is Test {
    SitOnHands internal vault;
    MockIMD internal token;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    uint256 internal constant INITIAL = 1_000_000;

    event Locked(address indexed depositor, uint256 amount, uint256 unlockTime, uint256 indexed positionId);
    event Withdrawn(address indexed depositor, uint256 amount, uint256 unlockTime, uint256 indexed positionId);

    function setUp() public {
        vm.warp(1_000_000);
        token = new MockIMD();
        vault = new SitOnHands(address(token));
        token.mint(ALICE, INITIAL);
        token.mint(BOB, INITIAL);
        vm.prank(ALICE);
        token.approve(address(vault), INITIAL);
        vm.prank(BOB);
        token.approve(address(vault), INITIAL);
    }

    function testConstructorAndBounds() public view {
        assertEq(address(vault.imd()), address(token));
        assertEq(vault.MIN_DURATION(), 1 days);
        assertEq(vault.MAX_DURATION(), 365 days);
    }

    function testRejectsZeroToken() public {
        vm.expectRevert(SitOnHands.InvalidToken.selector);
        new SitOnHands(address(0));
    }

    function testLockAndWithdrawFullAmountExactlyAtUnlock() public {
        uint256 unlock = vm.getBlockTimestamp() + 1 days;
        vm.expectEmit(true, true, false, true, address(vault));
        emit Locked(ALICE, 300, unlock, 0);
        uint256 id = _lock(ALICE, 300, 1 days);
        assertEq(id, 0);
        assertEq(vault.nextPositionId(), 1);
        _assertPosition(id, ALICE, 300, unlock, false);
        assertEq(token.balanceOf(ALICE), INITIAL - 300);
        assertEq(token.balanceOf(address(vault)), 300);
        assertEq(vault.lockedBalance(ALICE), 300);
        assertEq(vault.totalLocked(), 300);
        assertFalse(vault.canWithdraw(id));

        vm.warp(unlock);
        assertTrue(vault.canWithdraw(id));
        vm.expectEmit(true, true, false, true, address(vault));
        emit Withdrawn(ALICE, 300, unlock, id);
        vm.prank(ALICE);
        vault.withdraw(id);
        _assertPosition(id, ALICE, 300, unlock, true);
        assertFalse(vault.canWithdraw(id));
        assertEq(token.balanceOf(ALICE), INITIAL);
        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(vault.totalLocked(), 0);
        assertEq(vault.lockedBalance(ALICE), 0);
    }

    function testWithdrawOneSecondEarlyReverts() public {
        uint256 unlock = vm.getBlockTimestamp() + 1 days;
        uint256 id = _lock(ALICE, 300, 1 days);
        vm.warp(unlock - 1);
        vm.expectRevert(abi.encodeWithSelector(SitOnHands.StillLocked.selector, unlock));
        vm.prank(ALICE);
        vault.withdraw(id);
        assertEq(token.balanceOf(address(vault)), 300);
        _assertPosition(id, ALICE, 300, unlock, false);
    }

    function testTwoPositionsUnlockIndependently() public {
        uint256 start = vm.getBlockTimestamp();
        uint256 longId = _lock(ALICE, 700, 3 days);
        vm.warp(start + 1 hours);
        uint256 shortId = _lock(ALICE, 200, 1 days);
        assertEq(shortId, longId + 1);
        vm.warp(start + 1 hours + 1 days);
        vm.prank(ALICE);
        vault.withdraw(shortId);
        assertEq(vault.lockedBalance(ALICE), 700);
        assertFalse(vault.canWithdraw(longId));
        vm.expectRevert(abi.encodeWithSelector(SitOnHands.StillLocked.selector, start + 3 days));
        vm.prank(ALICE);
        vault.withdraw(longId);
        vm.warp(start + 3 days);
        vm.prank(ALICE);
        vault.withdraw(longId);
        assertEq(token.balanceOf(ALICE), INITIAL);
        assertEq(vault.totalLocked(), 0);
    }

    function testCannotWithdrawOthersPositionEvenAfterMaturity() public {
        uint256 id = _lock(ALICE, 500, 1 days);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.expectRevert(SitOnHands.NotDepositor.selector);
        vm.prank(BOB);
        vault.withdraw(id);
        vm.expectRevert(SitOnHands.NotDepositor.selector);
        vault.withdraw(id); // The deployer has no privilege either.
        assertEq(token.balanceOf(BOB), INITIAL);
        assertEq(vault.totalLocked(), 500);
    }

    function testLockOnlySpendsCallersApprovedTokens() public {
        address stranger = address(0xCAFE);
        vm.expectRevert(MockIMD.InsufficientAllowance.selector);
        vm.prank(stranger);
        vault.lock(100, 1 days);
        uint256 id = _lock(BOB, 100, 1 days);
        _assertPosition(id, BOB, 100, vm.getBlockTimestamp() + 1 days, false);
        assertEq(token.balanceOf(ALICE), INITIAL);
        assertEq(token.allowance(ALICE, address(vault)), INITIAL);
    }

    function testCannotWithdrawTwice() public {
        uint256 id = _lock(ALICE, 100, 1 days);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.startPrank(ALICE);
        vault.withdraw(id);
        vm.expectRevert(SitOnHands.AlreadyWithdrawn.selector);
        vault.withdraw(id);
        vm.stopPrank();
        assertEq(token.balanceOf(ALICE), INITIAL);
    }

    function testUnknownPositionRevertsAndIsNotWithdrawable() public {
        assertFalse(vault.canWithdraw(0));
        assertFalse(vault.canWithdraw(type(uint256).max));
        vm.expectRevert(SitOnHands.UnknownPosition.selector);
        vm.prank(ALICE);
        vault.withdraw(0);
    }

    function testRejectsZeroAmount() public {
        vm.expectRevert(SitOnHands.ZeroAmount.selector);
        vm.prank(ALICE);
        vault.lock(0, 1 days);
    }

    function testRejectsInvalidDurations() public {
        uint256[5] memory invalid = [uint256(0), 1, 1 days - 1, 365 days + 1, type(uint256).max];
        for (uint256 i; i < invalid.length; ++i) {
            vm.expectRevert(SitOnHands.InvalidDuration.selector);
            vm.prank(ALICE);
            vault.lock(1, invalid[i]);
        }
        assertEq(vault.nextPositionId(), 0);
        assertEq(token.balanceOf(ALICE), INITIAL);
    }

    function testMaximumDurationIsAcceptedAndEnforced() public {
        uint256 unlock = vm.getBlockTimestamp() + 365 days;
        uint256 id = _lock(ALICE, 1, 365 days);
        vm.warp(unlock - 1);
        vm.expectRevert(abi.encodeWithSelector(SitOnHands.StillLocked.selector, unlock));
        vm.prank(ALICE);
        vault.withdraw(id);
        vm.warp(unlock);
        vm.prank(ALICE);
        vault.withdraw(id);
        assertEq(token.balanceOf(ALICE), INITIAL);
    }

    function testInsufficientApprovalRollsBack() public {
        vm.prank(ALICE);
        token.approve(address(vault), 99);
        vm.expectRevert(MockIMD.InsufficientAllowance.selector);
        vm.prank(ALICE);
        vault.lock(100, 1 days);
        assertEq(vault.nextPositionId(), 0);
        assertEq(vault.totalLocked(), 0);
    }

    function testInsufficientBalanceRollsBack() public {
        vm.prank(ALICE);
        token.approve(address(vault), INITIAL + 1);
        vm.expectRevert(MockIMD.InsufficientBalance.selector);
        vm.prank(ALICE);
        vault.lock(INITIAL + 1, 1 days);
        assertEq(token.allowance(ALICE, address(vault)), INITIAL + 1);
        assertEq(vault.nextPositionId(), 0);
    }

    function testRejectsFeeOnDepositAndRollsBack() public {
        _assertFailedDeposit(MockIMD.Mode.Fee, abi.encodeWithSelector(SitOnHands.UnexpectedTokenBalance.selector));
    }

    function testRejectsExtraSenderFeeOnDepositAndRollsBack() public {
        _assertFailedDeposit(MockIMD.Mode.SenderFee, abi.encodeWithSelector(SitOnHands.UnexpectedTokenBalance.selector));
    }

    function testRejectsFalseReturningDeposit() public {
        _assertFailedDeposit(
            MockIMD.Mode.ReturnFalse,
            abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token))
        );
    }

    function testRejectsRevertingDeposit() public {
        _assertFailedDeposit(MockIMD.Mode.RevertTransfer, abi.encodeWithSelector(MockIMD.MockTransferReverted.selector));
    }

    function testRejectsSuccessfulNoOpDeposit() public {
        _assertFailedDeposit(MockIMD.Mode.NoOp, abi.encodeWithSelector(SitOnHands.UnexpectedTokenBalance.selector));
    }

    function testSupportsNoReturnTokenTransfers() public {
        token.setModes(MockIMD.Mode.NoReturn, MockIMD.Mode.NoReturn);
        uint256 id = _lock(ALICE, 100, 1 days);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.prank(ALICE);
        vault.withdraw(id);
        assertEq(token.balanceOf(ALICE), INITIAL);
        assertEq(vault.totalLocked(), 0);
    }

    function testFalseReturningWithdrawCanBeRetried() public {
        _assertFailedWithdrawal(
            MockIMD.Mode.ReturnFalse,
            abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token))
        );
    }

    function testRevertingWithdrawCanBeRetried() public {
        _assertFailedWithdrawal(
            MockIMD.Mode.RevertTransfer, abi.encodeWithSelector(MockIMD.MockTransferReverted.selector)
        );
    }

    function testFeeChargingWithdrawCanBeRetried() public {
        _assertFailedWithdrawal(MockIMD.Mode.Fee, abi.encodeWithSelector(SitOnHands.UnexpectedTokenBalance.selector));
    }

    function testSuccessfulNoOpWithdrawCanBeRetried() public {
        _assertFailedWithdrawal(MockIMD.Mode.NoOp, abi.encodeWithSelector(SitOnHands.UnexpectedTokenBalance.selector));
    }

    function testSenderFeeCannotConsumeAnotherUsersPrincipal() public {
        _lock(BOB, 100, 1 days);
        _assertFailedWithdrawal(
            MockIMD.Mode.SenderFee, abi.encodeWithSelector(SitOnHands.UnexpectedTokenBalance.selector)
        );
        assertEq(token.balanceOf(address(vault)), 100);
        assertEq(vault.lockedBalance(BOB), 100);
    }

    function testDonationDoesNotChangePrincipalOrMaturity() public {
        uint256 unlock = vm.getBlockTimestamp() + 1 days;
        uint256 id = _lock(ALICE, 100, 1 days);
        vm.prank(BOB);
        token.transfer(address(vault), 77);
        _assertPosition(id, ALICE, 100, unlock, false);
        assertEq(vault.totalLocked(), 100);
        vm.warp(unlock + 30 days);
        vm.prank(ALICE);
        vault.withdraw(id);
        assertEq(token.balanceOf(ALICE), INITIAL);
        assertEq(token.balanceOf(address(vault)), 77);
        assertEq(vault.totalLocked(), 0);
    }

    function testOtherTokensCannotFundAPosition() public {
        MockIMD other = new MockIMD();
        other.mint(address(vault), 100);
        vm.prank(ALICE);
        token.approve(address(vault), 0);
        vm.expectRevert(MockIMD.InsufficientAllowance.selector);
        vm.prank(ALICE);
        vault.lock(100, 1 days);
        assertEq(vault.totalLocked(), 0);
    }

    function testNoPositionTransferOrAdminEscapeSelectors() public {
        uint256 id = _lock(ALICE, 100, 1 days);
        bytes[5] memory calls = [
            abi.encodeWithSignature("transferPosition(uint256,address)", id, BOB),
            abi.encodeWithSignature("emergencyWithdraw(uint256)", id),
            abi.encodeWithSignature("sweep(address,uint256)", address(token), 100),
            abi.encodeWithSignature("setUnlockTime(uint256,uint256)", id, vm.getBlockTimestamp()),
            abi.encodeWithSignature("upgradeTo(address)", BOB)
        ];
        for (uint256 i; i < calls.length; ++i) {
            (bool success,) = address(vault).call(calls[i]);
            assertFalse(success);
        }
        assertEq(vault.totalLocked(), 100);
        assertEq(token.balanceOf(address(vault)), 100);
    }

    function testRejectsEther() public {
        vm.deal(address(this), 1 ether);
        (bool success,) = address(vault).call{value: 1}("");
        assertFalse(success);
    }

    function testReentrantDepositIsBlocked() public {
        _fundTokenAccount(200);
        token.setHook(address(vault), abi.encodeCall(vault.lock, (100, 1 days)));
        _lock(address(token), 100, 1 days);
        _assertReentrancyBlocked();
        assertEq(vault.nextPositionId(), 1);
        assertEq(vault.totalLocked(), 100);
    }

    function testReentrantWithdrawalOfSamePositionIsBlocked() public {
        _fundTokenAccount(100);
        uint256 id = _lock(address(token), 100, 1 days);
        token.setHook(address(vault), abi.encodeCall(vault.withdraw, (id)));
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.prank(address(token));
        vault.withdraw(id);
        _assertReentrancyBlocked();
        assertEq(token.balanceOf(address(token)), 100);
        assertEq(vault.totalLocked(), 0);
    }

    function testReentrantWithdrawalOfOtherMaturedPositionIsBlocked() public {
        _fundTokenAccount(200);
        uint256 first = _lock(address(token), 100, 1 days);
        uint256 second = _lock(address(token), 100, 1 days);
        token.setHook(address(vault), abi.encodeCall(vault.withdraw, (second)));
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.prank(address(token));
        vault.withdraw(first);
        _assertReentrancyBlocked();
        assertTrue(vault.canWithdraw(second));
        assertEq(vault.totalLocked(), 100);
    }

    function testCannotReenterLockDuringWithdrawal() public {
        _fundTokenAccount(200);
        uint256 id = _lock(address(token), 100, 1 days);
        token.setHook(address(vault), abi.encodeCall(vault.lock, (100, 1 days)));
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.prank(address(token));
        vault.withdraw(id);
        _assertReentrancyBlocked();
        assertEq(vault.nextPositionId(), 1);
        assertEq(vault.totalLocked(), 0);
    }

    function testCannotReenterWithdrawalDuringDeposit() public {
        _fundTokenAccount(200);
        uint256 id = _lock(address(token), 100, 1 days);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        token.setHook(address(vault), abi.encodeCall(vault.withdraw, (id)));
        _lock(address(token), 100, 1 days);
        _assertReentrancyBlocked();
        assertTrue(vault.canWithdraw(id));
        assertEq(vault.totalLocked(), 200);
    }

    function testFuzzFullPrincipalAndTimeGate(uint256 rawAmount, uint256 rawDuration, uint256 rawEarly) public {
        uint256 amount = bound(rawAmount, 1, INITIAL);
        uint256 duration = bound(rawDuration, 1 days, 365 days);
        uint256 start = vm.getBlockTimestamp();
        uint256 id = _lock(ALICE, amount, duration);
        vm.warp(start + bound(rawEarly, 0, duration - 1));
        vm.expectRevert(abi.encodeWithSelector(SitOnHands.StillLocked.selector, start + duration));
        vm.prank(ALICE);
        vault.withdraw(id);
        vm.warp(start + duration);
        vm.prank(ALICE);
        vault.withdraw(id);
        assertEq(token.balanceOf(ALICE), INITIAL);
        assertEq(vault.totalLocked(), 0);
    }

    function testFuzzInvalidDuration(uint256 duration) public {
        vm.assume(duration < 1 days || duration > 365 days);
        vm.expectRevert(SitOnHands.InvalidDuration.selector);
        vm.prank(ALICE);
        vault.lock(1, duration);
        assertEq(vault.totalLocked(), 0);
    }

    function _lock(address user, uint256 amount, uint256 duration) internal returns (uint256) {
        vm.prank(user);
        return vault.lock(amount, duration);
    }

    function _assertPosition(uint256 id, address user, uint256 amount, uint256 unlock, bool withdrawn) internal view {
        (address actualUser, uint256 actualAmount, uint256 actualUnlock, bool actualWithdrawn) = vault.positions(id);
        assertEq(actualUser, user);
        assertEq(actualAmount, amount);
        assertEq(actualUnlock, unlock);
        assertEq(actualWithdrawn, withdrawn);
    }

    function _assertFailedDeposit(MockIMD.Mode mode, bytes memory expectedError) internal {
        token.setModes(mode, MockIMD.Mode.Normal);
        vm.expectRevert(expectedError);
        vm.prank(ALICE);
        vault.lock(100, 1 days);
        assertEq(vault.nextPositionId(), 0);
        assertEq(vault.totalLocked(), 0);
        assertEq(vault.lockedBalance(ALICE), 0);
        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(token.balanceOf(ALICE), INITIAL);
        assertEq(token.allowance(ALICE, address(vault)), INITIAL);
    }

    function _assertFailedWithdrawal(MockIMD.Mode mode, bytes memory expectedError) internal {
        uint256 unlock = vm.getBlockTimestamp() + 1 days;
        uint256 id = _lock(ALICE, 100, 1 days);
        uint256 totalBefore = vault.totalLocked();
        uint256 balanceBefore = token.balanceOf(address(vault));
        vm.warp(unlock);
        token.setModes(MockIMD.Mode.Normal, mode);
        vm.expectRevert(expectedError);
        vm.prank(ALICE);
        vault.withdraw(id);
        _assertPosition(id, ALICE, 100, unlock, false);
        assertEq(vault.totalLocked(), totalBefore);
        assertEq(vault.lockedBalance(ALICE), 100);
        assertEq(token.balanceOf(address(vault)), balanceBefore);
        assertEq(token.balanceOf(ALICE), INITIAL - 100);

        token.setModes(MockIMD.Mode.Normal, MockIMD.Mode.Normal);
        vm.prank(ALICE);
        vault.withdraw(id);
        assertEq(token.balanceOf(ALICE), INITIAL);
        assertEq(vault.totalLocked(), totalBefore - 100);
    }

    function _fundTokenAccount(uint256 amount) internal {
        token.mint(address(token), amount);
        vm.prank(address(token));
        token.approve(address(vault), amount);
    }

    function _assertReentrancyBlocked() internal view {
        assertFalse(token.hookSucceeded());
        assertEq(token.hookResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
    }
}
