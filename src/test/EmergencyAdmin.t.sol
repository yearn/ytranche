// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import "forge-std/Test.sol";
import {Setup} from "./utils/Setup.sol";
import {ITrancheStrategy} from "../interfaces/ITrancheStrategy.sol";
import {Authorizer} from "../periphery/Authorizer.sol";
import {EmergencyAdmin} from "../periphery/EmergencyAdmin.sol";

contract MockEmergencyCallTarget {
    error MockFailure(uint256 code);

    address public lastCaller;
    uint256 public value;

    function setValue(uint256 _value) external returns (uint256, address) {
        lastCaller = msg.sender;
        value = _value;
        return (_value, msg.sender);
    }

    function setOtherValue(uint256 _value) external {
        lastCaller = msg.sender;
        value = _value;
    }

    function revertWithReason() external pure {
        revert("boom");
    }

    function revertWithCustomError(uint256 _code) external pure {
        revert MockFailure(_code);
    }
}

/// @notice Central {EmergencyAdmin} — halts the main vault and strategies through
///   the Yearn V3 primitives. Shutdowns are management-gated; emergency actions
///   are emergency-gated. Governance is superuser.
contract EmergencyAdminTest is Setup {
    /// @dev Grant EMERGENCY_ROLE to `_who` (cache the role id before the prank so
    ///      the view call doesn't consume it).
    function _grantEmergency(address _who) internal {
        bytes32 role = emergencyAdmin.EMERGENCY_ROLE();
        vm.prank(management);
        authorizer.grantRole(role, _who);
    }

    function _depositReverts(address _tranche, address _user, uint256 _amt) internal {
        _airdrop(_user, _amt);
        vm.startPrank(_user);
        asset.approve(_tranche, _amt);
        vm.expectRevert();
        ITrancheStrategy(_tranche).deposit(_amt, _user);
        vm.stopPrank();
    }

    function test_pauseVault_blocksDepositsAndWithdrawals() public {
        uint256 shares = _depositA(alice, 50e18);

        _grantEmergency(carol);
        vm.prank(carol);
        emergencyAdmin.pauseVault(address(mainVault));

        // Tranche deposit routes into the paused vault and reverts.
        _depositReverts(address(aTranche), bob, 10e18);

        // Direct main-vault deposit reverts too.
        _airdrop(eve, 10e18);
        vm.startPrank(eve);
        asset.approve(address(mainVault), 10e18);
        vm.expectRevert();
        mainVault.deposit(10e18, eve);
        vm.stopPrank();

        // Withdrawals are blocked while paused.
        vm.prank(alice);
        vm.expectRevert();
        ITrancheStrategy(address(aTranche)).redeem(shares, alice, alice);
    }

    function test_shutdownVault_blocksDepositsAllowsWithdrawals() public {
        uint256 shares = _depositA(alice, 50e18);

        vm.prank(management);
        emergencyAdmin.shutdownVault(address(mainVault));

        // Deposits blocked once shut down.
        _depositReverts(address(aTranche), bob, 10e18);

        // But holders can still exit.
        vm.prank(alice);
        ITrancheStrategy(address(aTranche)).redeem(shares, alice, alice);
        assertApproxEqAbs(asset.balanceOf(alice), 50e18, 1e15, "alice exited after shutdown");
    }

    function test_settleAfterVaultShutdown_doesNotDrawReserve() public {
        _depositA(alice, 70e18);
        _fundReserve(10e18);
        _simulateRiskyPnL(-int256(5e18));

        vm.prank(management);
        emergencyAdmin.shutdownVault(address(mainVault));

        _settle();

        assertApproxEqAbs(controller.reserveAssets(), 10e18, 1, "reserve stays invested");
        assertEq(asset.balanceOf(address(controller)), 0, "controller strands no assets");
        assertApproxEqAbs(controller.vaultAssets(), 65e18, 1, "shutdown vault gets no deposit");
        assertApproxEqAbs(controller.liveAssets(address(aTranche)), 65e18, 1, "tranche absorbs uncovered loss");
        assertTrue(controller.isAccrualPaused(address(aTranche)), "loss pauses tranche accrual");
        assertFalse(controller.reserveDepositInProgress(), "reserve deposit flag stays clear");
    }

    function test_pauseStrategy_isScoped() public {
        _grantEmergency(carol);
        vm.prank(carol);
        emergencyAdmin.pauseVault(address(bTranche));

        assertTrue(ITrancheStrategy(address(bTranche)).isPaused(), "B paused");

        // B is blocked, A is unaffected.
        _depositReverts(address(bTranche), bob, 10e18);
        _depositA(alice, 10e18);
    }

    function test_shutdownStrategy() public {
        vm.prank(management);
        emergencyAdmin.shutdownStrategy(address(aTranche));

        assertTrue(ITrancheStrategy(address(aTranche)).isShutdown(), "A shut down");
        _depositReverts(address(aTranche), bob, 10e18);
    }

    function test_emergencyWithdraw_requiresPausedOrShutdown() public {
        _depositA(alice, 50e18);
        _grantEmergency(carol);

        // Before a halt, emergencyWithdraw reverts.
        vm.prank(carol);
        vm.expectRevert(bytes("not paused or shutdown"));
        emergencyAdmin.emergencyWithdraw(address(aTranche), 1e18);

        // After pausing the strategy it succeeds (a no-op for Tranches today).
        vm.startPrank(carol);
        emergencyAdmin.pauseVault(address(aTranche));
        emergencyAdmin.emergencyWithdraw(address(aTranche), 1e18);
        vm.stopPrank();
    }

    function test_zeroMaxDebtForStrategy() public {
        assertEq(mainVault.strategies(address(riskyStrategy)).max_debt, type(uint256).max, "pre max debt");

        _grantEmergency(carol);
        vm.prank(carol);
        emergencyAdmin.zeroMaxDebtForStrategy(address(mainVault), address(riskyStrategy));

        assertEq(mainVault.strategies(address(riskyStrategy)).max_debt, 0, "max debt zeroed");
    }

    function test_onlyAuthorizedRolesOrGovernance() public {
        // Unprivileged caller is rejected on every entry point.
        vm.startPrank(bob);
        vm.expectRevert(bytes("!authorized"));
        emergencyAdmin.pauseVault(address(mainVault));
        vm.expectRevert(bytes("!authorized"));
        emergencyAdmin.shutdownVault(address(mainVault));
        vm.expectRevert(bytes("!authorized"));
        emergencyAdmin.shutdownStrategy(address(aTranche));
        vm.expectRevert(bytes("!authorized"));
        emergencyAdmin.emergencyWithdraw(address(aTranche), 1e18);
        vm.expectRevert(bytes("!authorized"));
        emergencyAdmin.zeroMaxDebtForStrategy(address(mainVault), address(riskyStrategy));
        vm.stopPrank();

        _grantEmergency(carol);
        vm.startPrank(carol);
        vm.expectRevert(bytes("!authorized"));
        emergencyAdmin.shutdownVault(address(mainVault));
        vm.expectRevert(bytes("!authorized"));
        emergencyAdmin.shutdownStrategy(address(aTranche));
        vm.stopPrank();

        // Governance (the Authorizer superuser) can act without holding the role.
        vm.prank(governance);
        emergencyAdmin.pauseVault(address(aTranche));
        assertTrue(ITrancheStrategy(address(aTranche)).isPaused());
    }
}

/// @notice Selector-scoped arbitrary call permissions. This fixture stays tiny;
///         authorization tests should not need a whale-sized vault deployment.
contract EmergencyAdminPassthroughTest is Test {
    Authorizer internal authorizer;
    EmergencyAdmin internal emergencyAdmin;
    MockEmergencyCallTarget internal target;
    MockEmergencyCallTarget internal otherTarget;

    address internal governance = makeAddr("passthrough governance");
    address internal management = makeAddr("passthrough management");
    address internal operator = makeAddr("passthrough operator");

    function setUp() public {
        authorizer = new Authorizer(governance, management);
        emergencyAdmin = new EmergencyAdmin(address(authorizer));
        target = new MockEmergencyCallTarget();
        otherTarget = new MockEmergencyCallTarget();
    }

    function _grant(address _account, address _target, bytes4 _selector) internal {
        bytes32 role = keccak256(abi.encodePacked(_target, _selector));
        vm.prank(governance);
        authorizer.grantRole(role, _account);
    }

    function test_getRole_hashesPackedTargetAndSelector() public view {
        bytes4 selector = MockEmergencyCallTarget.setValue.selector;
        bytes32 expected = keccak256(abi.encodePacked(address(target), selector));

        assertEq(emergencyAdmin.getRole(address(target), selector), expected);
    }

    function test_execute_forwardsCalldataAndReturnsData() public {
        bytes memory data = abi.encodeCall(MockEmergencyCallTarget.setValue, (42));
        _grant(operator, address(target), MockEmergencyCallTarget.setValue.selector);

        vm.expectCall(address(target), data);
        vm.prank(operator);
        bytes memory result = emergencyAdmin.execute(address(target), data);

        (uint256 returnedValue, address seenCaller) = abi.decode(result, (uint256, address));
        assertEq(returnedValue, 42, "return value");
        assertEq(seenCaller, address(emergencyAdmin), "returned caller");
        assertEq(target.lastCaller(), address(emergencyAdmin), "target caller");
        assertEq(target.value(), 42, "forwarded argument");
    }

    function testFuzz_execute_roleAllowsAnyArgumentsForSelector(uint256 _first, uint256 _second) public {
        _grant(operator, address(target), MockEmergencyCallTarget.setValue.selector);

        vm.startPrank(operator);
        emergencyAdmin.execute(address(target), abi.encodeCall(MockEmergencyCallTarget.setValue, (_first)));
        emergencyAdmin.execute(address(target), abi.encodeCall(MockEmergencyCallTarget.setValue, (_second)));
        vm.stopPrank();

        assertEq(target.value(), _second, "second argument forwarded");
    }

    function test_execute_rejectsWrongTarget() public {
        bytes memory data = abi.encodeCall(MockEmergencyCallTarget.setValue, (42));
        _grant(operator, address(target), MockEmergencyCallTarget.setValue.selector);

        vm.prank(operator);
        vm.expectRevert(bytes("!authorized"));
        emergencyAdmin.execute(address(otherTarget), data);
    }

    function test_execute_rejectsWrongSelector() public {
        bytes memory data = abi.encodeCall(MockEmergencyCallTarget.setOtherValue, (42));
        _grant(operator, address(target), MockEmergencyCallTarget.setValue.selector);

        vm.prank(operator);
        vm.expectRevert(bytes("!authorized"));
        emergencyAdmin.execute(address(target), data);
    }

    function test_execute_rejectsUngrantedCaller() public {
        bytes memory data = abi.encodeCall(MockEmergencyCallTarget.setValue, (42));

        vm.prank(operator);
        vm.expectRevert(bytes("!authorized"));
        emergencyAdmin.execute(address(target), data);
    }

    function test_execute_governanceHasNoBypass() public {
        bytes memory data = abi.encodeCall(MockEmergencyCallTarget.setValue, (42));

        vm.prank(governance);
        vm.expectRevert(bytes("!authorized"));
        emergencyAdmin.execute(address(target), data);
    }

    function test_execute_governanceCanUseExplicitRole() public {
        bytes memory data = abi.encodeCall(MockEmergencyCallTarget.setValue, (42));
        _grant(governance, address(target), MockEmergencyCallTarget.setValue.selector);

        vm.prank(governance);
        emergencyAdmin.execute(address(target), data);

        assertEq(target.value(), 42);
    }

    function test_execute_rejectsCalldataWithoutSelector() public {
        _expectNoSelector(hex"");
        _expectNoSelector(hex"01");
        _expectNoSelector(hex"0102");
        _expectNoSelector(hex"010203");
    }

    function test_execute_rejectsNonContractTarget() public {
        address nonContract = makeAddr("not a contract");
        bytes memory data = abi.encodeCall(MockEmergencyCallTarget.setValue, (42));
        _grant(operator, nonContract, MockEmergencyCallTarget.setValue.selector);

        vm.prank(operator);
        vm.expectRevert(bytes("Address: call to non-contract"));
        emergencyAdmin.execute(nonContract, data);
    }

    function test_execute_bubblesStringRevert() public {
        bytes memory data = abi.encodeCall(MockEmergencyCallTarget.revertWithReason, ());
        _grant(operator, address(target), MockEmergencyCallTarget.revertWithReason.selector);

        vm.prank(operator);
        vm.expectRevert(bytes("boom"));
        emergencyAdmin.execute(address(target), data);
    }

    function test_execute_bubblesCustomError() public {
        uint256 code = 73;
        bytes memory data = abi.encodeCall(MockEmergencyCallTarget.revertWithCustomError, (code));
        _grant(operator, address(target), MockEmergencyCallTarget.revertWithCustomError.selector);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(MockEmergencyCallTarget.MockFailure.selector, code));
        emergencyAdmin.execute(address(target), data);
    }

    function _expectNoSelector(bytes memory _data) internal {
        vm.expectRevert(bytes("NO_SELECTOR"));
        emergencyAdmin.execute(address(target), _data);
    }
}
