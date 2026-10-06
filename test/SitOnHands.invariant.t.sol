// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {SitOnHands} from "../src/SitOnHands.sol";
import {MockIMD} from "./mocks/MockIMD.sol";

contract VaultHandler is Test {
    SitOnHands public immutable vault;
    MockIMD public immutable token;
    address[3] public actors = [address(0xA11CE), address(0xB0B), address(0xCAFE)];
    mapping(address => uint256) public minted;
    mapping(address => uint256) public outstanding;
    uint256 public donated;
    uint256 public latestUnlock;

    struct ExpectedPosition {
        address owner;
        uint256 amount;
        uint256 unlockTime;
        bool withdrawn;
    }

    ExpectedPosition[] public expected;

    constructor(SitOnHands vault_, MockIMD token_) {
        vault = vault_;
        token = token_;
    }

    function deposit(uint256 actorSeed, uint256 amountSeed, uint256 durationSeed) external {
        address actor = actors[actorSeed % actors.length];
        uint256 amount = bound(amountSeed, 1, 1e24);
        uint256 duration = bound(durationSeed, 1 days, 365 days);
        token.mint(actor, amount);
        minted[actor] += amount;
        outstanding[actor] += amount;
        uint256 unlock = vm.getBlockTimestamp() + duration;
        if (unlock > latestUnlock) latestUnlock = unlock;
        vm.startPrank(actor);
        token.approve(address(vault), amount);
        uint256 id = vault.lock(amount, duration);
        vm.stopPrank();
        assertEq(id, expected.length);
        expected.push(ExpectedPosition(actor, amount, unlock, false));
    }

    function advanceTime(uint256 secondsSeed) external {
        vm.warp(vm.getBlockTimestamp() + bound(secondsSeed, 0, 30 days));
    }

    function withdraw(uint256 idSeed) external {
        if (expected.length == 0) return;
        uint256 id = idSeed % expected.length;
        ExpectedPosition storage position = expected[id];
        if (position.withdrawn || vm.getBlockTimestamp() < position.unlockTime) return;
        vm.prank(position.owner);
        vault.withdraw(id);
        position.withdrawn = true;
        outstanding[position.owner] -= position.amount;
    }

    function attemptEarlyOrDuplicateWithdrawal(uint256 idSeed) external {
        if (expected.length == 0) return;
        uint256 id = idSeed % expected.length;
        ExpectedPosition storage position = expected[id];
        if (!position.withdrawn && vm.getBlockTimestamp() >= position.unlockTime) return;
        bytes memory reason = position.withdrawn
            ? abi.encodeWithSelector(SitOnHands.AlreadyWithdrawn.selector)
            : abi.encodeWithSelector(SitOnHands.StillLocked.selector, position.unlockTime);
        vm.expectRevert(reason);
        vm.prank(position.owner);
        vault.withdraw(id);
    }

    function attemptForeignWithdrawal(uint256 idSeed) external {
        if (expected.length == 0) return;
        uint256 id = idSeed % expected.length;
        address thief = expected[id].owner == actors[0] ? actors[1] : actors[0];
        vm.expectRevert(SitOnHands.NotDepositor.selector);
        vm.prank(thief);
        vault.withdraw(id);
    }

    function donate(uint256 amountSeed) external {
        uint256 amount = bound(amountSeed, 1, 1e24);
        token.mint(address(this), amount);
        token.transfer(address(vault), amount);
        donated += amount;
    }

    function count() external view returns (uint256) {
        return expected.length;
    }
}

contract SitOnHandsInvariantTest is StdInvariant, Test {
    MockIMD internal token;
    SitOnHands internal vault;
    VaultHandler internal handler;

    function setUp() public {
        vm.warp(1_000_000);
        token = new MockIMD();
        vault = new SitOnHands(address(token));
        handler = new VaultHandler(vault, token);
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = VaultHandler.deposit.selector;
        selectors[1] = VaultHandler.advanceTime.selector;
        selectors[2] = VaultHandler.withdraw.selector;
        selectors[3] = VaultHandler.attemptEarlyOrDuplicateWithdrawal.selector;
        selectors[4] = VaultHandler.attemptForeignWithdrawal.selector;
        selectors[5] = VaultHandler.donate.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariantPrincipalIsConservedAndPositionsNeverChangeOwnerOrDeadline() public view {
        uint256 sum;
        for (uint256 i; i < 3; ++i) {
            address actor = handler.actors(i);
            uint256 principal = handler.outstanding(actor);
            assertEq(vault.lockedBalance(actor), principal);
            assertEq(token.balanceOf(actor) + principal, handler.minted(actor));
            sum += principal;
        }
        assertEq(vault.totalLocked(), sum);
        assertEq(token.balanceOf(address(vault)), sum + handler.donated());
        assertEq(vault.nextPositionId(), handler.count());

        uint256 positionSum;
        for (uint256 id; id < handler.count(); ++id) {
            (address owner, uint256 amount, uint256 unlock, bool withdrawn) = vault.positions(id);
            (address expectedOwner, uint256 expectedAmount, uint256 expectedUnlock, bool expectedWithdrawn) =
                handler.expected(id);
            assertEq(owner, expectedOwner);
            assertEq(amount, expectedAmount);
            assertEq(unlock, expectedUnlock);
            assertEq(withdrawn, expectedWithdrawn);
            assertEq(vault.canWithdraw(id), !withdrawn && vm.getBlockTimestamp() >= unlock);
            if (!withdrawn) positionSum += amount;
        }
        assertEq(positionSum, sum);
    }

    function afterInvariant() public {
        uint256 latest = handler.latestUnlock();
        if (vm.getBlockTimestamp() < latest) vm.warp(latest);
        for (uint256 id; id < handler.count(); ++id) {
            handler.withdraw(id);
        }
        assertEq(vault.totalLocked(), 0);
        assertEq(token.balanceOf(address(vault)), handler.donated());
        for (uint256 i; i < 3; ++i) {
            address actor = handler.actors(i);
            assertEq(token.balanceOf(actor), handler.minted(actor));
        }
    }
}
