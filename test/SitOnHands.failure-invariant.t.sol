// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SitOnHands} from "src/SitOnHands.sol";
import {MockIMD} from "./mocks/MockIMD.sol";

/// @dev Fixed inventory: only the constructor mints. The oracle uses call inputs,
/// never balances or position data read back from the vault to update expectations.
contract FixedInventoryHandler is Test {
    uint256 public constant INITIAL = 1e24;
    address[3] public actors = [address(0xA11CE), address(0xB0B), address(0xCAFE)];
    SitOnHands public immutable vault;
    MockIMD public immutable token;
    mapping(address => uint256) public deposited;
    mapping(address => uint256) public paid;
    mapping(address => uint256) public donations;
    mapping(address => uint256) public expectedAllowance;
    uint256 public failedDeposits;
    uint256 public failedWithdrawals;
    uint256 public successfulWithdrawals;

    struct Claim {
        address owner;
        uint256 amount;
        uint256 deadline;
        bool paid;
    }

    Claim[] public claims;

    constructor(SitOnHands vault_, MockIMD token_) {
        vault = vault_;
        token = token_;
        for (uint256 i; i < actors.length; ++i) {
            token.mint(actors[i], INITIAL);
        }
    }

    function approve(uint256 actorSeed, uint256 amountSeed) public {
        address actor = actors[actorSeed % actors.length];
        uint256 allowance = bound(amountSeed, 0, INITIAL);
        vm.prank(actor);
        token.approve(address(vault), allowance);
        expectedAllowance[actor] = allowance;
    }

    function deposit(uint256 actorSeed, uint256 amountSeed, uint256 durationSeed) public {
        address actor = actors[actorSeed % actors.length];
        uint256 available = availableTo(actor);
        if (available == 0) return;
        uint256 amount = bound(amountSeed, 1, available);
        uint256 duration = bound(durationSeed, 1 days, 365 days);
        if (expectedAllowance[actor] < amount) {
            vm.expectRevert(MockIMD.InsufficientAllowance.selector);
            vm.prank(actor);
            vault.lock(amount, duration);
            ++failedDeposits;
            return;
        }

        uint256 deadline = vm.getBlockTimestamp() + duration;
        vm.prank(actor);
        uint256 id = vault.lock(amount, duration);
        assertEq(id, claims.length, "failed calls must not consume IDs");
        claims.push(Claim(actor, amount, deadline, false));
        deposited[actor] += amount;
        expectedAllowance[actor] -= amount;
    }

    function withdraw(uint256 idSeed) public {
        uint256 id = idSeed % claims.length;
        Claim storage claim = claims[id];
        if (claim.paid) {
            vm.expectRevert(SitOnHands.AlreadyWithdrawn.selector);
        } else if (vm.getBlockTimestamp() < claim.deadline) {
            vm.expectRevert(abi.encodeWithSelector(SitOnHands.StillLocked.selector, claim.deadline));
        } else {
            vm.prank(claim.owner);
            vault.withdraw(id);
            claim.paid = true;
            paid[claim.owner] += claim.amount;
            ++successfulWithdrawals;
            return;
        }
        vm.prank(claim.owner);
        vault.withdraw(id);
        ++failedWithdrawals;
    }

    function advanceTime(uint256 secondsSeed) external {
        vm.warp(vm.getBlockTimestamp() + bound(secondsSeed, 0, 365 days));
    }

    function withdrawAtBoundary(uint256 idSeed, bool exact) public {
        uint256 id = idSeed % claims.length;
        uint256 target = claims[id].deadline - (exact ? 0 : 1);
        if (vm.getBlockTimestamp() < target) vm.warp(target);
        withdraw(id);
    }

    function donate(uint256 actorSeed, uint256 amountSeed) public {
        address actor = actors[actorSeed % actors.length];
        uint256 available = availableTo(actor);
        // Leave some inventory to keep later deposits and transfer faults reachable.
        if (available < 10) return;
        uint256 amount = bound(amountSeed, 1, available / 10);
        vm.prank(actor);
        token.transfer(address(vault), amount);
        donations[actor] += amount;
    }

    function rejectForeignWithdrawal(uint256 idSeed, uint256 actorSeed) public {
        uint256 id = idSeed % claims.length;
        uint256 actorIndex = actorSeed % actors.length;
        if (actors[actorIndex] == claims[id].owner) actorIndex = (actorIndex + 1) % actors.length;
        vm.expectRevert(SitOnHands.NotDepositor.selector);
        vm.prank(actors[actorIndex]);
        vault.withdraw(id);
        ++failedWithdrawals;
    }

    function rejectUnknownWithdrawal(uint256 idSeed) public {
        uint256 id = bound(idSeed, claims.length, type(uint256).max);
        assertFalse(vault.canWithdraw(id));
        vm.expectRevert(SitOnHands.UnknownPosition.selector);
        vm.prank(actors[0]);
        vault.withdraw(id);
        ++failedWithdrawals;
    }

    function rejectInvalidLock(uint256 actorSeed, uint256 durationSeed, uint8 kind) public {
        uint256 amount = kind % 3 == 0 ? 0 : 1;
        uint256 duration = kind % 3 == 0
            ? 1 days
            : kind % 3 == 1 ? bound(durationSeed, 0, 1 days - 1) : bound(durationSeed, 365 days + 1, type(uint256).max);
        vm.expectRevert(amount == 0 ? SitOnHands.ZeroAmount.selector : SitOnHands.InvalidDuration.selector);
        vm.prank(actors[actorSeed % actors.length]);
        vault.lock(amount, duration);
        ++failedDeposits;
    }

    function failedTokenDeposit(uint256 actorSeed, uint256 amountSeed, uint256 modeSeed) public {
        address actor = actors[actorSeed % actors.length];
        uint256 available = availableTo(actor);
        if (available < 20) return;
        // At least 10 ensures fee modes cannot silently round their fee to zero.
        // Half the balance leaves enough headroom for the mock's extra sender fee.
        uint256 amount = bound(amountSeed, 10, available / 2);
        approve(actorSeed, amount);
        MockIMD.Mode mode = _failureMode(modeSeed, amount);
        token.setModes(mode, MockIMD.Mode.Normal);
        vm.expectRevert(_errorFor(mode));
        vm.prank(actor);
        vault.lock(amount, 1 days);
        token.setModes(MockIMD.Mode.Normal, MockIMD.Mode.Normal);
        ++failedDeposits;
    }

    function failedTokenWithdrawal(uint256 idSeed, uint256 modeSeed) public {
        uint256 id = idSeed % claims.length;
        Claim storage claim = claims[id];
        if (claim.paid) return;
        if (vm.getBlockTimestamp() < claim.deadline) vm.warp(claim.deadline);
        MockIMD.Mode mode = _failureMode(modeSeed, claim.amount);
        bytes memory reason = _errorFor(mode);
        if (mode == MockIMD.Mode.SenderFee && token.balanceOf(address(vault)) < claim.amount + claim.amount / 10) {
            reason = abi.encodeWithSelector(MockIMD.InsufficientBalance.selector);
        }
        token.setModes(MockIMD.Mode.Normal, mode);
        vm.expectRevert(reason);
        vm.prank(claim.owner);
        vault.withdraw(id);
        token.setModes(MockIMD.Mode.Normal, MockIMD.Mode.Normal);
        ++failedWithdrawals;
        // The model is unchanged. The next invariant checks every claim, balance,
        // allowance and the supply, including rollback of mock fees/burns.
    }

    function availableTo(address actor) public view returns (uint256) {
        return INITIAL + paid[actor] - deposited[actor] - donations[actor];
    }

    function count() external view returns (uint256) {
        return claims.length;
    }

    function _failureMode(uint256 seed, uint256 amount) internal pure returns (MockIMD.Mode) {
        uint256 index = seed % 5;
        if (index == 0) return MockIMD.Mode.ReturnFalse;
        if (index == 1) return MockIMD.Mode.RevertTransfer;
        if (index == 2) return MockIMD.Mode.NoOp;
        if (amount < 10) return MockIMD.Mode.ReturnFalse;
        return index == 3 ? MockIMD.Mode.Fee : MockIMD.Mode.SenderFee;
    }

    function _errorFor(MockIMD.Mode mode) internal view returns (bytes memory) {
        if (mode == MockIMD.Mode.ReturnFalse) {
            return abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token));
        }
        if (mode == MockIMD.Mode.RevertTransfer) {
            return abi.encodeWithSelector(MockIMD.MockTransferReverted.selector);
        }
        return abi.encodeWithSelector(SitOnHands.UnexpectedTokenBalance.selector);
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract SitOnHandsFailureInvariantTest is StdInvariant, Test {
    MockIMD internal token;
    SitOnHands internal vault;
    FixedInventoryHandler internal handler;

    function setUp() public {
        vm.warp(1_700_000_123);
        token = new MockIMD();
        vault = new SitOnHands(address(token));
        handler = new FixedInventoryHandler(vault, token);
        // Nonempty from the first fuzz call; includes independently timed owners.
        for (uint256 i; i < 3; ++i) {
            handler.approve(i, handler.INITIAL());
            handler.deposit(i, (i + 1) * 1000, (i + 1) * 1 days);
        }

        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = FixedInventoryHandler.approve.selector;
        selectors[1] = FixedInventoryHandler.deposit.selector;
        selectors[2] = FixedInventoryHandler.withdraw.selector;
        selectors[3] = FixedInventoryHandler.advanceTime.selector;
        selectors[4] = FixedInventoryHandler.withdrawAtBoundary.selector;
        selectors[5] = FixedInventoryHandler.donate.selector;
        selectors[6] = FixedInventoryHandler.rejectForeignWithdrawal.selector;
        selectors[7] = FixedInventoryHandler.rejectUnknownWithdrawal.selector;
        selectors[8] = FixedInventoryHandler.rejectInvalidLock.selector;
        selectors[9] = FixedInventoryHandler.failedTokenDeposit.selector;
        selectors[10] = FixedInventoryHandler.failedTokenWithdrawal.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_FixedSupplyClaimsAndAllowancesMatchIndependentLedger() public view {
        uint256 sumOutstanding;
        uint256 sumDonated;
        uint256 held = token.balanceOf(address(vault));
        for (uint256 i; i < 3; ++i) {
            address actor = handler.actors(i);
            uint256 deposited = handler.deposited(actor);
            uint256 paid = handler.paid(actor);
            assertLe(paid, deposited, "no actor receives more than their own principal");
            uint256 outstanding = deposited - paid;
            assertEq(vault.lockedBalance(actor), outstanding, "user debt");
            assertEq(token.balanceOf(actor), handler.availableTo(actor), "user cash");
            assertEq(token.allowance(actor, address(vault)), handler.expectedAllowance(actor), "allowance rollback");
            sumOutstanding += outstanding;
            sumDonated += handler.donations(actor);
            held += token.balanceOf(actor);
        }
        assertEq(token.totalSupply(), 3 * handler.INITIAL(), "no mint or fee burn during sequence");
        assertEq(held, token.totalSupply(), "closed inventory");
        assertEq(vault.totalLocked(), sumOutstanding, "aggregate debt");
        assertEq(token.balanceOf(address(vault)), sumOutstanding + sumDonated, "backing including donations");
        assertEq(vault.nextPositionId(), handler.count(), "IDs only advance on successful locks");
        assertEq(address(vault.imd()), address(token), "fixed asset");

        uint256 claimSum;
        for (uint256 id; id < handler.count(); ++id) {
            (address owner, uint256 amount, uint256 deadline, bool paid) = handler.claims(id);
            (address actualOwner, uint256 actualAmount, uint256 actualDeadline, bool actualPaid) = vault.positions(id);
            assertEq(actualOwner, owner, "immutable depositor");
            assertEq(actualAmount, amount, "immutable principal");
            assertEq(actualDeadline, deadline, "immutable deadline");
            assertEq(actualPaid, paid, "paid claims cannot reopen; failed payouts remain owed");
            assertEq(vault.canWithdraw(id), !paid && vm.getBlockTimestamp() >= deadline, "eligibility");
            if (!paid) claimSum += amount;
        }
        assertEq(claimSum, sumOutstanding, "all positions accounted for");
    }

    function afterInvariant() public {
        uint256 latest = vm.getBlockTimestamp();
        for (uint256 id; id < handler.count(); ++id) {
            (,, uint256 deadline,) = handler.claims(id);
            if (deadline > latest) latest = deadline;
        }
        vm.warp(latest);
        for (uint256 id; id < handler.count(); ++id) {
            (,,, bool paid) = handler.claims(id);
            if (!paid) handler.withdraw(id);
        }
        invariant_FixedSupplyClaimsAndAllowancesMatchIndependentLedger();
        assertEq(vault.totalLocked(), 0, "all debts redeemable after faults clear");
        for (uint256 i; i < 3; ++i) {
            address actor = handler.actors(i);
            assertEq(token.balanceOf(actor), handler.INITIAL() - handler.donations(actor), "full eventual refund");
        }
    }

    /// @dev A deterministic reachability check complements random selector counts:
    /// all five transfer-failure modes run with otherwise-valid funded claims.
    function testHandlerExercisesFailuresRecoveryAndRelocking() public {
        for (uint256 mode; mode < 5; ++mode) {
            handler.failedTokenDeposit(0, 100, mode);
            handler.failedTokenWithdrawal(0, mode);
            invariant_FixedSupplyClaimsAndAllowancesMatchIndependentLedger();
        }
        handler.approve(1, 0);
        handler.deposit(1, 100, 1 days);
        handler.withdrawAtBoundary(1, false);
        handler.rejectForeignWithdrawal(1, 0);
        handler.rejectUnknownWithdrawal(type(uint256).max);
        for (uint8 kind; kind < 3; ++kind) {
            handler.rejectInvalidLock(1, 0, kind);
        }
        handler.withdrawAtBoundary(1, true);
        handler.withdraw(1); // Replay against other users' still-outstanding funds.
        handler.approve(1, 2000);
        handler.deposit(1, 2000, 365 days);
        handler.donate(2, 100);
        invariant_FixedSupplyClaimsAndAllowancesMatchIndependentLedger();
        assertEq(handler.failedDeposits(), 9);
        assertEq(handler.failedWithdrawals(), 9);
        assertEq(handler.successfulWithdrawals(), 1);
        assertEq(handler.count(), 4);
        afterInvariant();
    }
}
