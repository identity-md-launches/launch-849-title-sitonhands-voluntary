// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Test-only token with independently configurable incoming/outgoing behavior.
contract MockIMD is IERC20 {
    enum Mode {
        Normal,
        ReturnFalse,
        RevertTransfer,
        NoReturn,
        Fee,
        NoOp,
        SenderFee
    }

    string public symbol = "IMD";
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    Mode public inboundMode;
    Mode public outboundMode;
    address public hookTarget;
    bytes public hookData;
    bool public hookSucceeded;
    bytes public hookResult;

    error MockTransferReverted();
    error InsufficientAllowance();
    error InsufficientBalance();

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function setSymbol(string calldata value) external {
        symbol = value;
    }

    function setModes(Mode inbound, Mode outbound) external {
        inboundMode = inbound;
        outboundMode = outbound;
    }

    function setHook(address target, bytes calldata data) external {
        hookTarget = target;
        hookData = data;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        return _move(msg.sender, to, amount, outboundMode);
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed < amount) revert InsufficientAllowance();
        allowance[from][msg.sender] = allowed - amount;
        return _move(from, to, amount, inboundMode);
    }

    function _move(address from, address to, uint256 amount, Mode mode) internal returns (bool) {
        if (mode == Mode.RevertTransfer) revert MockTransferReverted();
        if (mode == Mode.ReturnFalse) return false;
        if (mode == Mode.NoOp) return true;
        uint256 fee = (mode == Mode.Fee || mode == Mode.SenderFee) ? amount / 10 : 0;
        uint256 debit = mode == Mode.SenderFee ? amount + fee : amount;
        uint256 credit = mode == Mode.Fee ? amount - fee : amount;
        if (balanceOf[from] < debit) revert InsufficientBalance();
        balanceOf[from] -= debit;
        balanceOf[to] += credit;
        totalSupply -= fee;
        emit Transfer(from, to, credit);
        if (hookTarget != address(0)) {
            (hookSucceeded, hookResult) = hookTarget.call(hookData);
        }
        if (mode == Mode.NoReturn) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        return true;
    }
}
