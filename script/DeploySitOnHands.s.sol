// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {SitOnHands} from "../src/SitOnHands.sol";

interface ITokenSymbol {
    function symbol() external view returns (string memory);
}

/// @notice Mainnet deployment with an explicit, independently authenticated IMD address.
/// @dev No environment reads, private keys, defaults, or reliance on the constructor's caller.
contract DeploySitOnHands is Script {
    error WrongChain();
    error MissingTokenCode();
    error WrongTokenSymbol();

    /// @notice Forge simulates by default; the operator controls broadcasting and verification flags.
    function run(address imd) external returns (SitOnHands vault) {
        validate(imd);
        vm.startBroadcast();
        vault = new SitOnHands(imd);
        vm.stopBroadcast();
    }

    /// @notice Checks deployment mistakes; the symbol alone does not authenticate IMD's identity.
    function validate(address imd) public view {
        if (block.chainid != 1) revert WrongChain();
        if (imd.code.length == 0) revert MissingTokenCode();
        try ITokenSymbol(imd).symbol() returns (string memory symbol) {
            if (keccak256(bytes(symbol)) != keccak256("IMD")) revert WrongTokenSymbol();
        } catch {
            revert WrongTokenSymbol();
        }
    }
}
