// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface Vm {
    struct Log {
        bytes32[] topics;
        bytes data;
        address emitter;
    }

    function prank(address caller) external;
    function startPrank(address caller) external;
    function stopPrank() external;
    function expectRevert(bytes4 selector) external;
    function expectRevert() external;
    function recordLogs() external;
    function getRecordedLogs() external returns (Log[] memory);
}

/// @dev Deliberately small local harness; no external test dependency or environment access.
abstract contract TestBase {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function assertEq(uint256 actual, uint256 expected) internal pure {
        require(actual == expected, "uint mismatch");
    }

    function assertEq(address actual, address expected) internal pure {
        require(actual == expected, "address mismatch");
    }

    function assertTrue(bool condition) internal pure {
        require(condition, "assertion failed");
    }
}
