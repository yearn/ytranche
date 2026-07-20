// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {Setup} from "./utils/Setup.sol";
import {Hook} from "../Hook.sol";
import {TrancheController} from "../TrancheController.sol";
import {Keeper as PeripheryKeeper} from "../periphery/Keeper.sol";
import {TrancheStrategy} from "../TrancheStrategy.sol";
import {ITrancheStrategy} from "../interfaces/ITrancheStrategy.sol";

contract KeeperTest is Setup {
    PeripheryKeeper public batchKeeper;

    event SettledAndReported(address indexed caller, address indexed controller, uint256 trancheCount);

    function setUp() public override {
        super.setUp();

        batchKeeper = new PeripheryKeeper(address(authorizer));

        bytes32 keeperRole = authorizer.KEEPER_ROLE();
        vm.prank(management);
        authorizer.grantRole(keeperRole, address(batchKeeper));

        ITrancheStrategy(address(aTranche)).setKeeper(address(batchKeeper));
        ITrancheStrategy(address(bTranche)).setKeeper(address(batchKeeper));
        ITrancheStrategy(address(eTranche)).setKeeper(address(batchKeeper));
    }

    function test_settleAndReport_requiresKeeperRole() public {
        vm.prank(alice);
        vm.expectRevert(bytes("!authorized"));
        batchKeeper.settleAndReport(address(controller));
    }

    function test_settleAndReport_allowsKeeperRoleHolder() public {
        bytes32 keeperRole = authorizer.KEEPER_ROLE();
        vm.prank(management);
        authorizer.grantRole(keeperRole, alice);

        vm.prank(alice);
        batchKeeper.settleAndReport(address(controller));
    }

    function test_settleAndReport_settlesAndReportsEveryTranche() public {
        _depositA(alice, 70e18);
        _depositB(bob, 20e18);
        _depositE(carol, 10e18);
        skip(SECONDS_PER_YEAR);
        _simulateRiskyPnL(int256(54e17));

        uint256 aLastReport = ITrancheStrategy(address(aTranche)).lastReport();
        uint256 bLastReport = ITrancheStrategy(address(bTranche)).lastReport();
        uint256 eLastReport = ITrancheStrategy(address(eTranche)).lastReport();

        vm.prank(keeper);
        batchKeeper.settleAndReport(address(controller));

        assertEq(controller.pendingExcess(address(aTranche)), 0, "A pending");
        assertEq(controller.pendingExcess(address(bTranche)), 0, "B pending");
        assertEq(controller.pendingExcess(address(eTranche)), 0, "E pending");

        assertGt(ITrancheStrategy(address(aTranche)).lastReport(), aLastReport, "A reported");
        assertGt(ITrancheStrategy(address(bTranche)).lastReport(), bLastReport, "B reported");
        assertGt(ITrancheStrategy(address(eTranche)).lastReport(), eLastReport, "E reported");
    }

    /// §6.7 — emits SettledAndReported(caller, controller, trancheCount) with the live count.
    function test_settleAndReport_emitsEventWithCount() public {
        _depositA(alice, 10e18);
        vm.expectEmit(true, true, false, true, address(batchKeeper));
        emit SettledAndReported(keeper, address(controller), 3); // A, B, E registered
        vm.prank(keeper);
        batchKeeper.settleAndReport(address(controller));
    }

    /// §6.7 — governance is a superuser via `isAuthorized`, so it can call too.
    function test_settleAndReport_allowsGovernanceCaller() public {
        _depositA(alice, 10e18);
        vm.prank(governance);
        batchKeeper.settleAndReport(address(controller));
    }

    /// §6.7 — the batch is driven by the controller's live priority list, so a
    /// tranche registered after the Keeper was wired is reported too.
    function test_settleAndReport_includesNewlyRegisteredTranche() public {
        ITrancheStrategy d = ITrancheStrategy(
            address(
                new TrancheStrategy(
                    address(asset), "Tranche D", "trD", address(controller), address(hook), address(authorizer)
                )
            )
        );

        // Register before configuring: the strategy's totalAssets routes to
        // controller.liveAssets, which reverts "!tranche" until registered.
        vm.prank(governance);
        controller.registerTranche(address(d), 0, 0);

        // This test contract is `d`'s strategy-management (it deployed it).
        d.setProfitMaxUnlockTime(0);
        d.setKeeper(address(batchKeeper));
        d.setOpen(true);
        d.setProfitLimitRatio(type(uint16).max);
        d.setLossLimitRatio(uint16(MAX_BPS - 1));

        vm.startPrank(management);
        hook.setDepositLimit(address(d), type(uint256).max);
        hook.setDepositRateLimit(address(d), type(uint128).max);
        hook.setWithdrawRateLimit(address(d), type(uint128).max);
        vm.stopPrank();

        uint256 before = d.lastReport();
        skip(1);
        vm.prank(keeper);
        batchKeeper.settleAndReport(address(controller));
        assertGt(d.lastReport(), before, "D reported");
    }

    function test_settleAndReport_rejectsZeroController() public {
        vm.prank(keeper);
        vm.expectRevert(bytes("ZERO controller"));
        batchKeeper.settleAndReport(address(0));
    }

    function test_settleAndReport_servicesOnlySelectedController() public {
        TrancheController secondController =
            new TrancheController(address(asset), address(mainVault), address(authorizer));
        Hook secondHook = new Hook(address(authorizer), address(secondController));
        ITrancheStrategy secondTranche = ITrancheStrategy(
            address(
                new TrancheStrategy(
                    address(asset),
                    "Second Controller Tranche",
                    "trSECOND",
                    address(secondController),
                    address(secondHook),
                    address(authorizer)
                )
            )
        );

        vm.prank(governance);
        secondController.registerTranche(address(secondTranche), 0, 0);

        secondTranche.setProfitMaxUnlockTime(0);
        secondTranche.setKeeper(address(batchKeeper));
        secondTranche.setProfitLimitRatio(type(uint16).max);
        secondTranche.setLossLimitRatio(uint16(MAX_BPS - 1));

        uint256 aLastReport = ITrancheStrategy(address(aTranche)).lastReport();
        uint256 bLastReport = ITrancheStrategy(address(bTranche)).lastReport();
        uint256 eLastReport = ITrancheStrategy(address(eTranche)).lastReport();
        uint256 secondLastReport = secondTranche.lastReport();

        assertEq(controller.tranchesLength(), 3, "primary count");
        assertEq(secondController.tranchesLength(), 1, "second count");

        skip(1);
        vm.expectEmit(true, true, false, true, address(batchKeeper));
        emit SettledAndReported(keeper, address(secondController), 1);
        vm.prank(keeper);
        batchKeeper.settleAndReport(address(secondController));

        assertGt(secondTranche.lastReport(), secondLastReport, "second reported");
        assertEq(ITrancheStrategy(address(aTranche)).lastReport(), aLastReport, "primary A untouched");
        assertEq(ITrancheStrategy(address(bTranche)).lastReport(), bLastReport, "primary B untouched");
        assertEq(ITrancheStrategy(address(eTranche)).lastReport(), eLastReport, "primary E untouched");
    }
}
