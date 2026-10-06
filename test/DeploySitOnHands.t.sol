// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeploySitOnHands} from "../script/DeploySitOnHands.s.sol";
import {SitOnHands} from "../src/SitOnHands.sol";
import {MockIMD} from "./mocks/MockIMD.sol";

contract VaultFactory {
    function deploy(address token) external returns (SitOnHands) {
        return new SitOnHands{salt: bytes32(uint256(1))}(token);
    }
}

contract DeploySitOnHandsTest is Test {
    DeploySitOnHands internal script;
    MockIMD internal token;

    function setUp() public {
        vm.chainId(1);
        script = new DeploySitOnHands();
        token = new MockIMD();
    }

    function testRunUsesExplicitTokenOnMainnet() public {
        SitOnHands vault = script.run(address(token));
        assertEq(address(vault.imd()), address(token));
        assertGt(address(vault).code.length, 0);
        assertEq(vault.nextPositionId(), 0);
        assertEq(vault.MAX_DURATION(), 365 days);
    }

    function testRunRejectsWrongChain() public {
        vm.chainId(11_155_111);
        vm.expectRevert(DeploySitOnHands.WrongChain.selector);
        script.run(address(token));
    }

    function testRunRejectsZeroTokenAndAddressWithoutCode() public {
        vm.expectRevert(DeploySitOnHands.MissingTokenCode.selector);
        script.run(address(0));
        vm.expectRevert(DeploySitOnHands.MissingTokenCode.selector);
        script.run(address(0x1234));
    }

    function testRunRejectsWrongSymbol() public {
        token.setSymbol("OTHER");
        vm.expectRevert(DeploySitOnHands.WrongTokenSymbol.selector);
        script.run(address(token));
    }

    function testRunRejectsMissingSymbol() public {
        VaultFactory factory = new VaultFactory();
        vm.expectRevert(DeploySitOnHands.WrongTokenSymbol.selector);
        script.run(address(factory));
    }

    function testFactoryDeploymentAndFullUserLifecycle() public {
        VaultFactory factory = new VaultFactory();
        SitOnHands vault = factory.deploy(address(token));
        address depositor = address(0xA11CE);
        token.mint(depositor, 100);
        vm.startPrank(depositor);
        token.approve(address(vault), 100);
        uint256 id = vault.lock(100, 1 days);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vault.withdraw(id);
        vm.stopPrank();
        assertEq(token.balanceOf(depositor), 100);
        assertEq(vault.totalLocked(), 0);
    }

    function testConstructorIsIndependentOfExternalTokenState() public {
        VaultFactory factory = new VaultFactory();
        // Offline deployment rehearsals have no mainnet state; operations still need a real ERC-20.
        SitOnHands vault = factory.deploy(address(0x1234));
        assertEq(address(vault.imd()), address(0x1234));
        vm.expectRevert();
        vault.lock(1, 1 days);
        assertEq(vault.totalLocked(), 0);
    }

    function testApplicationRuntimeMatchesProtectedOpcodeAndSizeRules() public {
        SitOnHands vault = new SitOnHands(address(token));
        bytes memory code = address(vault).code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 opcode = uint8(code[i]);
            if (opcode >= 0x60 && opcode <= 0x7f) {
                i += opcode - 0x5f;
                continue;
            }
            assertTrue(opcode != 0xf4 && opcode != 0xf2 && opcode != 0xff);
        }
    }
}
