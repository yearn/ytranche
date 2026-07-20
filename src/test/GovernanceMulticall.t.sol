// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {GovernanceMulticall} from "../periphery/GovernanceMulticall.sol";

contract MockGovernanceMulticallTarget {
    error Boom(uint256 code);

    address public lastCaller;
    uint256 public storedValue;
    uint256 public totalValueReceived;

    function record(uint256 _value) external payable returns (uint256, address, uint256) {
        lastCaller = msg.sender;
        storedValue = _value;
        totalValueReceived += msg.value;

        return (_value, msg.sender, msg.value);
    }

    function revertWithCustomError(uint256 _code) external pure {
        revert Boom(_code);
    }

    function revertWithReason() external pure {
        revert("boom");
    }

    function revertWithoutData() external pure {
        assembly {
            revert(0, 0)
        }
    }
}

contract GovernanceMulticallTest is Test {
    GovernanceMulticall internal multicall;
    MockGovernanceMulticallTarget internal target;

    address internal governance = makeAddr("governance");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        multicall = new GovernanceMulticall(governance);
        target = new MockGovernanceMulticallTarget();
    }

    function test_onlyGovernance() public {
        GovernanceMulticall.Call[] memory calls = new GovernanceMulticall.Call[](0);

        vm.prank(stranger);
        vm.expectRevert(bytes("!governance"));
        multicall.multicall(calls);
    }

    function test_targetObservesMulticallAsSender() public {
        GovernanceMulticall.Call[] memory calls = new GovernanceMulticall.Call[](1);
        calls[0] = GovernanceMulticall.Call({
            target: address(target), value: 0, data: abi.encodeCall(MockGovernanceMulticallTarget.record, (17))
        });

        vm.prank(governance);
        bytes[] memory results = multicall.multicall(calls);

        (uint256 returnedValue, address returnedCaller, uint256 returnedEth) =
            abi.decode(results[0], (uint256, address, uint256));
        assertEq(target.lastCaller(), address(multicall));
        assertEq(returnedCaller, address(multicall));
        assertEq(returnedValue, 17);
        assertEq(returnedEth, 0);
    }

    function test_forwardsValueAndReturnsEachResult() public {
        GovernanceMulticall.Call[] memory calls = new GovernanceMulticall.Call[](2);
        calls[0] = GovernanceMulticall.Call({
            target: address(target), value: 0.4 ether, data: abi.encodeCall(MockGovernanceMulticallTarget.record, (11))
        });
        calls[1] = GovernanceMulticall.Call({
            target: address(target), value: 0.6 ether, data: abi.encodeCall(MockGovernanceMulticallTarget.record, (22))
        });

        vm.deal(governance, 1 ether);
        vm.prank(governance);
        bytes[] memory results = multicall.multicall{value: 1 ether}(calls);

        (uint256 firstValue, address firstCaller, uint256 firstEth) =
            abi.decode(results[0], (uint256, address, uint256));
        (uint256 secondValue, address secondCaller, uint256 secondEth) =
            abi.decode(results[1], (uint256, address, uint256));

        assertEq(firstValue, 11);
        assertEq(firstCaller, address(multicall));
        assertEq(firstEth, 0.4 ether);
        assertEq(secondValue, 22);
        assertEq(secondCaller, address(multicall));
        assertEq(secondEth, 0.6 ether);
        assertEq(target.totalValueReceived(), 1 ether);
        assertEq(address(target).balance, 1 ether);
        assertEq(address(multicall).balance, 0);
    }

    function test_bubblesRevertData() public {
        GovernanceMulticall.Call[] memory calls = new GovernanceMulticall.Call[](1);
        calls[0] = GovernanceMulticall.Call({
            target: address(target),
            value: 0,
            data: abi.encodeCall(MockGovernanceMulticallTarget.revertWithCustomError, (42))
        });

        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(MockGovernanceMulticallTarget.Boom.selector, 42));
        multicall.multicall(calls);
    }

    function test_emptyRevertUsesFallbackReason() public {
        GovernanceMulticall.Call[] memory calls = new GovernanceMulticall.Call[](1);
        calls[0] = GovernanceMulticall.Call({
            target: address(target), value: 0, data: abi.encodeCall(MockGovernanceMulticallTarget.revertWithoutData, ())
        });

        vm.prank(governance);
        vm.expectRevert(bytes("CALL_FAILED"));
        multicall.multicall(calls);
    }

    function test_revertRollsBackEarlierCalls() public {
        target.record(3);

        GovernanceMulticall.Call[] memory calls = new GovernanceMulticall.Call[](2);
        calls[0] = GovernanceMulticall.Call({
            target: address(target), value: 0, data: abi.encodeCall(MockGovernanceMulticallTarget.record, (99))
        });
        calls[1] = GovernanceMulticall.Call({
            target: address(target), value: 0, data: abi.encodeCall(MockGovernanceMulticallTarget.revertWithReason, ())
        });

        vm.prank(governance);
        vm.expectRevert(bytes("boom"));
        multicall.multicall(calls);

        assertEq(target.storedValue(), 3);
        assertEq(target.lastCaller(), address(this));
    }
}
