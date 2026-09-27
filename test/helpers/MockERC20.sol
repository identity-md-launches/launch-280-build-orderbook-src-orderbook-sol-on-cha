// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public transferCalls;
    uint256 public transferFromCalls;

    enum Mode {
        Normal,
        FalseReturn,
        NoReturn,
        Fee,
        RevertTransfer,
        Bonus
    }

    Mode public mode;
    address public callbackTarget;
    bytes public callbackData;
    bool public callbackSucceeded;
    bytes4 public callbackError;

    constructor(string memory name_, string memory symbol_) {
        name = name_;
        symbol = symbol_;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function setMode(Mode value) external {
        mode = value;
    }

    function setCallback(address target, bytes calldata data) external {
        callbackTarget = target;
        callbackData = data;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        ++transferCalls;
        _move(msg.sender, to, amount);
        return _result();
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        ++transferFromCalls;
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _move(from, to, amount);
        return _result();
    }

    function _move(address from, address to, uint256 amount) private {
        balanceOf[from] -= amount;
        if (mode == Mode.Fee) {
            balanceOf[to] += amount - 1;
            --totalSupply;
        } else if (mode == Mode.Bonus) {
            balanceOf[to] += amount + 1;
            ++totalSupply;
        } else {
            balanceOf[to] += amount;
        }
        if (callbackTarget != address(0)) {
            bytes memory result;
            (callbackSucceeded, result) = callbackTarget.call(callbackData);
            callbackError = result.length >= 4 ? bytes4(result) : bytes4(0);
        }
    }

    function _result() private view returns (bool) {
        if (mode == Mode.RevertTransfer) revert("token refused");
        if (mode == Mode.NoReturn) {
            assembly {
                return(0, 0)
            }
        }
        return mode != Mode.FalseReturn;
    }
}
