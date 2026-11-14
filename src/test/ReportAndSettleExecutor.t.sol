// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {Setup} from "./utils/Setup.sol";
import {TrancheStrategy} from "../TrancheStrategy.sol";
import {Keeper as PeripheryKeeper} from "../periphery/Keeper.sol";
import {ReportAndSettleExecutor} from "../periphery/ReportAndSettleExecutor.sol";
import {ITrancheStrategy} from "../interfaces/ITrancheStrategy.sol";

import {IStrategy} from "@tokenized-strategy/interfaces/IStrategy.sol";
import {IVault} from "@yearn-vaults/interfaces/IVault.sol";
import {Roles as VaultRoles} from "@yearn-vaults/interfaces/Roles.sol";

import {MockStrategy} from "./mocks/MockStrategy.sol";

contract ReportAndSettleExecutorTest is Setup {
    bytes4 internal constant REPORT_SELECTOR = bytes4(keccak256("report()"));
    address internal automation = address(0xD0);
    PeripheryKeeper internal batchKeeper;
    ReportAndSettleExecutor internal executor;

    event Executed(address indexed caller, address indexed controller, bytes32 indexed operationHash);

    function setUp() public override {
        super.setUp();
        batchKeeper = new PeripheryKeeper(address(authorizer));
        executor = _deploySingleVaultExecutor(address(mainVault), address(riskyStrategy), true);
        _authorizeRoute(executor, address(riskyStrategy), mainVault);
    }

    function _deploySingleVaultExecutor(address vault, address strategy, bool callReport)
        internal
        returns (ReportAndSettleExecutor value)
    {
        address[] memory vaults = new address[](1);
        address[] memory strategies = new address[](1);
        bool[] memory reports = new bool[](1);
        vaults[0] = vault;
        strategies[0] = strategy;
        reports[0] = callReport;
        value = new ReportAndSettleExecutor(
            automation, address(controller), address(batchKeeper), vaults, strategies, reports
        );
    }

    function _authorizeRoute(ReportAndSettleExecutor route, address strategy, IVault vault) internal {
        IStrategy(strategy).setKeeper(address(route));
        vault.add_role(address(route), VaultRoles.REPORTING_MANAGER);
        bytes32 keeperRole = authorizer.KEEPER_ROLE();
        vm.startPrank(management);
        authorizer.grantRole(keeperRole, address(route));
        authorizer.grantRole(keeperRole, address(batchKeeper));
        vm.stopPrank();
        ITrancheStrategy(address(aTranche)).setKeeper(address(batchKeeper));
        ITrancheStrategy(address(bTranche)).setKeeper(address(batchKeeper));
        ITrancheStrategy(address(eTranche)).setKeeper(address(batchKeeper));
    }

    function _seedProfit() internal {
        _depositA(alice, 70e18);
        _depositB(bob, 20e18);
        _depositE(carol, 10e18);
        skip(1);
        asset.mint(address(riskyStrategy), 5e18);
    }

    function test_execute_uses_exact_caller_and_commits_full_real_role_path() public {
        _seedProfit();
        uint256 strategyReport = IStrategy(address(riskyStrategy)).lastReport();
        uint256 vaultReport = mainVault.strategies(address(riskyStrategy)).last_report;

        vm.expectEmit(true, true, true, true, address(executor));
        emit Executed(automation, address(controller), executor.OPERATION_HASH());
        vm.prank(automation);
        executor.execute(address(controller));

        assertGt(IStrategy(address(riskyStrategy)).lastReport(), strategyReport, "strategy report missing");
        assertGt(mainVault.strategies(address(riskyStrategy)).last_report, vaultReport, "vault report missing");
        assertEq(controller.pendingExcess(address(aTranche)), 0, "A not reported");
        assertEq(controller.pendingExcess(address(bTranche)), 0, "B not reported");
        assertEq(controller.pendingExcess(address(eTranche)), 0, "E not reported");
    }

    function test_unauthorized_caller_and_wrong_controller_revert() public {
        vm.expectRevert(ReportAndSettleExecutor.Unauthorized.selector);
        executor.execute(address(controller));

        vm.prank(automation);
        vm.expectRevert(ReportAndSettleExecutor.WrongController.selector);
        executor.execute(address(0xBEEF));
    }

    function test_revoked_vault_role_rolls_back_the_earlier_strategy_report() public {
        _seedProfit();
        uint256 beforeReport = IStrategy(address(riskyStrategy)).lastReport();
        mainVault.remove_role(address(executor), VaultRoles.REPORTING_MANAGER);

        vm.prank(automation);
        vm.expectRevert();
        executor.execute(address(controller));

        assertEq(IStrategy(address(riskyStrategy)).lastReport(), beforeReport, "report was not rolled back");
    }

    function test_revoked_keeper_role_rolls_back_report_and_process_report() public {
        _seedProfit();
        uint256 strategyReport = IStrategy(address(riskyStrategy)).lastReport();
        uint256 vaultReport = mainVault.strategies(address(riskyStrategy)).last_report;
        bytes32 keeperRole = authorizer.KEEPER_ROLE();
        vm.prank(management);
        authorizer.revokeRole(keeperRole, address(executor));

        vm.prank(automation);
        vm.expectRevert(bytes("!authorized"));
        executor.execute(address(controller));

        assertEq(IStrategy(address(riskyStrategy)).lastReport(), strategyReport, "strategy report was not rolled back");
        assertEq(
            mainVault.strategies(address(riskyStrategy)).last_report, vaultReport, "vault report was not rolled back"
        );
    }

    function test_late_tranche_failure_rolls_back_every_prerequisite() public {
        _seedProfit();
        ITrancheStrategy(address(bTranche)).setProfitLimitRatio(1);
        uint256 strategyReport = IStrategy(address(riskyStrategy)).lastReport();
        uint256 vaultReport = mainVault.strategies(address(riskyStrategy)).last_report;

        vm.prank(automation);
        vm.expectRevert();
        executor.execute(address(controller));

        assertEq(IStrategy(address(riskyStrategy)).lastReport(), strategyReport, "strategy report was not rolled back");
        assertEq(
            mainVault.strategies(address(riskyStrategy)).last_report, vaultReport, "vault report was not rolled back"
        );
    }

    function test_false_or_malformed_inner_returns_are_rejected() public {
        vm.mockCall(address(riskyStrategy), abi.encodeWithSelector(REPORT_SELECTOR), abi.encode(false));
        vm.prank(automation);
        vm.expectRevert(
            abi.encodeWithSelector(
                ReportAndSettleExecutor.MalformedReturn.selector, address(riskyStrategy), uint256(64), uint256(32)
            )
        );
        executor.execute(address(controller));
        vm.clearMockedCalls();

        vm.mockCall(
            address(mainVault),
            abi.encodeWithSelector(IVault.process_report.selector, address(riskyStrategy)),
            abi.encode(false)
        );
        vm.prank(automation);
        vm.expectRevert(
            abi.encodeWithSelector(
                ReportAndSettleExecutor.MalformedReturn.selector, address(mainVault), uint256(64), uint256(32)
            )
        );
        executor.execute(address(controller));
        vm.clearMockedCalls();

        vm.mockCall(
            address(batchKeeper),
            abi.encodeWithSelector(PeripheryKeeper.settleAndReport.selector, address(controller)),
            abi.encode(false)
        );
        vm.prank(automation);
        vm.expectRevert(
            abi.encodeWithSelector(
                ReportAndSettleExecutor.MalformedReturn.selector, address(batchKeeper), uint256(0), uint256(32)
            )
        );
        executor.execute(address(controller));
        vm.clearMockedCalls();
    }

    function test_new_outside_queue_debt_is_detected_before_any_call() public {
        mainVault.set_auto_allocate(false);
        _depositA(alice, 10e18);
        MockStrategy outside = new MockStrategy(address(asset));
        IStrategy(address(outside)).setProfitMaxUnlockTime(0);
        IStrategy(address(outside)).setKeeper(address(executor));
        mainVault.add_strategy(address(outside), false);
        mainVault.update_max_debt_for_strategy(address(outside), type(uint256).max);
        mainVault.update_debt(address(outside), 5e18);

        vm.prank(automation);
        vm.expectRevert(
            abi.encodeWithSelector(
                ReportAndSettleExecutor.DebtCoverageChanged.selector, address(mainVault), uint256(0), uint256(5e18)
            )
        );
        executor.execute(address(controller));
    }

    function test_queue_and_tranche_registration_changes_are_detected() public {
        address[] memory emptyQueue = new address[](0);
        mainVault.set_default_queue(emptyQueue);
        ReportAndSettleExecutor changedQueue =
            _deploySingleVaultExecutor(address(mainVault), address(riskyStrategy), true);
        assertNotEq(changedQueue.EXPECTED_QUEUES_HASH(), executor.EXPECTED_QUEUES_HASH(), "queue digest unchanged");
        assertNotEq(changedQueue.OPERATION_HASH(), executor.OPERATION_HASH(), "operation identity ignored queue");
        vm.prank(automation);
        vm.expectRevert(abi.encodeWithSelector(ReportAndSettleExecutor.QueueChanged.selector, address(mainVault)));
        executor.execute(address(controller));

        address[] memory originalQueue = new address[](1);
        originalQueue[0] = address(riskyStrategy);
        mainVault.set_default_queue(originalQueue);
        TrancheStrategy extra = new TrancheStrategy(
            address(asset), "Extra", "EXTRA", address(controller), address(hook), address(authorizer)
        );
        vm.prank(governance);
        controller.registerTranche(address(extra), 0, 0);
        vm.prank(automation);
        vm.expectRevert(ReportAndSettleExecutor.TrancheRegistrationChanged.selector);
        executor.execute(address(controller));
    }

    function test_insufficient_gas_cannot_partially_commit() public {
        _seedProfit();
        uint256 beforeReport = IStrategy(address(riskyStrategy)).lastReport();
        vm.prank(automation);
        (bool success,) = address(executor).call{gas: 80_000}(
            abi.encodeWithSelector(ReportAndSettleExecutor.execute.selector, address(controller))
        );
        assertFalse(success, "low-gas operation succeeded");
        assertEq(IStrategy(address(riskyStrategy)).lastReport(), beforeReport, "partial report committed");
    }

    function test_nested_vault_is_processed_before_main_vault_without_calling_report_on_vault() public {
        IVault child = IVault(vaultFactory.deploy_new_vault(address(asset), "Child", "CHILD", address(this), 0));
        child.set_role(address(this), VaultRoles.ALL);
        child.set_deposit_limit(type(uint256).max);
        child.set_auto_allocate(true);
        child.set_minimum_total_idle(0);
        child.setProfitMaxUnlockTime(0);

        MockStrategy leaf = new MockStrategy(address(asset));
        IStrategy(address(leaf)).setProfitMaxUnlockTime(0);
        child.add_strategy(address(leaf));
        child.update_max_debt_for_strategy(address(leaf), type(uint256).max);
        address[] memory childQueue = new address[](1);
        childQueue[0] = address(leaf);
        child.set_default_queue(childQueue);

        mainVault.add_strategy(address(child));
        mainVault.update_max_debt_for_strategy(address(child), type(uint256).max);
        address[] memory mainQueue = new address[](1);
        mainQueue[0] = address(child);
        mainVault.set_default_queue(mainQueue);

        address[] memory routeVaults = new address[](2);
        address[] memory strategies = new address[](2);
        bool[] memory reports = new bool[](2);
        routeVaults[0] = address(child);
        strategies[0] = address(leaf);
        reports[0] = true;
        routeVaults[1] = address(mainVault);
        strategies[1] = address(child);
        reports[1] = false;
        ReportAndSettleExecutor nested = new ReportAndSettleExecutor(
            automation, address(controller), address(batchKeeper), routeVaults, strategies, reports
        );
        _authorizeRoute(nested, address(leaf), child);
        mainVault.add_role(address(nested), VaultRoles.REPORTING_MANAGER);

        _depositA(alice, 70e18);
        _depositB(bob, 20e18);
        _depositE(carol, 10e18);
        skip(1);
        asset.mint(address(leaf), 1e18);
        uint256 leafReport = IStrategy(address(leaf)).lastReport();
        uint256 childReport = child.strategies(address(leaf)).last_report;
        uint256 mainReport = mainVault.strategies(address(child)).last_report;

        vm.prank(automation);
        nested.execute(address(controller));

        assertGt(IStrategy(address(leaf)).lastReport(), leafReport, "leaf not reported");
        assertGt(child.strategies(address(leaf)).last_report, childReport, "child not processed");
        assertGt(mainVault.strategies(address(child)).last_report, mainReport, "main not processed");
    }

    function test_constructor_rejects_split_or_wrong_order_routes() public {
        address[] memory vaults = new address[](1);
        address[] memory strategies = new address[](1);
        bool[] memory reports = new bool[](1);
        vaults[0] = address(mainVault);
        strategies[0] = address(riskyStrategy);
        reports[0] = false;
        vm.expectRevert(ReportAndSettleExecutor.InvalidConfiguration.selector);
        new ReportAndSettleExecutor(automation, address(controller), address(batchKeeper), vaults, strategies, reports);
    }
}
