// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IBaseHealthCheck} from "@periphery/Bases/HealthCheck/IBaseHealthCheck.sol";
import {ITokenizedStrategy} from "@tokenized-strategy/interfaces/ITokenizedStrategy.sol";
import {IVault} from "@yearn-vaults/interfaces/IVault.sol";
import {Roles as VaultRoles} from "@yearn-vaults/interfaces/Roles.sol";

import {Hook} from "../src/Hook.sol";
import {TrancheController} from "../src/TrancheController.sol";
import {TrancheFactory} from "../src/TrancheFactory.sol";
import {ITrancheStrategy} from "../src/interfaces/ITrancheStrategy.sol";
import {Authorizer} from "../src/periphery/Authorizer.sol";
import {EmergencyAdmin} from "../src/periphery/EmergencyAdmin.sol";
import {GovernanceMulticall} from "../src/periphery/GovernanceMulticall.sol";
import {Keeper} from "../src/periphery/Keeper.sol";

/// @notice Deploys the USD, WETH, and BTC Tranche systems around live Yearn vaults.
/// @dev Contract creation happens in individual transactions. Narrow live-vault
///      role grants are staged individually because only the Yearn role manager
///      can grant them, then removed immediately after the atomic configuration
///      call. The deployer remains role manager throughout.
contract DeployTrancheSystem is Script {
    uint256 internal constant MAX_BPS = 10_000;
    uint256 internal constant SECONDS_PER_YEAR = 31_556_952;
    uint256 internal constant BASE_CONFIG_CALL_COUNT = 100;
    uint256 internal constant VAULT_HOOK_MANAGER_ROLES =
        VaultRoles.DEPOSIT_LIMIT_MANAGER | VaultRoles.WITHDRAW_LIMIT_MANAGER;

    bytes32 internal constant MANAGEMENT_ROLE = keccak256("MANAGEMENT_ROLE");
    bytes32 internal constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    bytes32 internal constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");

    struct VaultConfig {
        address vault;
        address expectedAsset;
        address reserveVault;
        uint256 rateLimitWindow;
        bool open;
        uint256 depositLimit;
        uint128 depositRateLimit;
        uint128 withdrawRateLimit;
    }

    struct TrancheConfig {
        string name;
        string symbol;
        uint16 targetBps;
        uint16 excessShareBps;
        uint256 cooldownDuration;
        uint256 withdrawalWindow;
        uint256 profitMaxUnlockTime;
        bool open;
        uint256 profitLimitRatio;
        uint256 lossLimitRatio;
        uint256 depositLimit;
        uint128 depositRateLimit;
        uint128 withdrawRateLimit;
    }

    struct SharedDeployment {
        GovernanceMulticall multicall;
        Authorizer authorizer;
        EmergencyAdmin emergencyAdmin;
        Keeper keeper;
        TrancheFactory factory;
    }

    struct SystemDeployment {
        IVault vault;
        address asset;
        TrancheController controller;
        Hook hook;
        address[] tranches;
    }

    struct Deployment {
        SharedDeployment shared;
        SystemDeployment usd;
        SystemDeployment weth;
        SystemDeployment btc;
    }

    /*//////////////////////////////////////////////////////////////
                         FILL THESE BEFORE DEPLOYING
    //////////////////////////////////////////////////////////////*/

    /// @dev The configured Foundry signer must match this address.
    address public deployer = address(0); // FILL_ME

    /// @dev Refuses to run against the wrong network, even if every address has code.
    uint256 public expectedChainId = 0; // FILL_ME

    /// @dev Flip only after reviewing every address and limit below. Dead-man switch.
    bool public configConfirmed = false; // FILL_ME

    /// @dev Keep false for a live launch. True explicitly permits frozen zero-limit targets.
    bool public allowZeroLimits = false;

    /// @dev Review historical RoleSet events for all three live vaults first.
    bool public existingVaultRolesReviewed = false; // FILL_ME

    /// @dev Populate these with old operational role holders that must lose access.
    ///      Any omitted holder keeps its existing vault roles.
    address[] internal usdVaultRoleHoldersToRevoke;
    address[] internal wethVaultRoleHoldersToRevoke;
    address[] internal btcVaultRoleHoldersToRevoke;

    VaultConfig internal usdConfig = VaultConfig({
        vault: address(0xDa87123895a043Ed3610155550177C54ce8ba49B), // FILL_ME
        expectedAsset: address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48), // FILL_ME
        reserveVault: address(0), // Optional
        rateLimitWindow: 1 hours,
        open: true,
        depositLimit: 1_000_000e6, // FILL_ME
        depositRateLimit: 100_000e6, // FILL_ME
        withdrawRateLimit: 100_000e6 // FILL_ME
    });

    VaultConfig internal wethConfig = VaultConfig({
        vault: address(0xf632554A9B23ce6E1EA314c9640E831170015f77), // FILL_ME
        expectedAsset: address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2), // FILL_ME
        reserveVault: address(0), // Optional
        rateLimitWindow: 1 hours,
        open: true,
        depositLimit: 10e8, // FILL_ME
        depositRateLimit: 1e8, // FILL_ME
        withdrawRateLimit: 1e8 // FILL_ME
    });

    VaultConfig internal btcConfig = VaultConfig({
        vault: address(0xF9e2bB1C632CD55806bF283aC8A51d37DB9D010B), // FILL_ME
        expectedAsset: address(0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf), // FILL_ME
        reserveVault: address(0), // Optional
        rateLimitWindow: 1 hours,
        open: true,
        depositLimit: 500e18, // FILL_ME
        depositRateLimit: 50e18, // FILL_ME
        withdrawRateLimit: 50e18 // FILL_ME
    });

    TrancheConfig internal usdAConfig = TrancheConfig({
        name: "yvUSD Fixed",
        symbol: "yvUSD-A",
        targetBps: 500,
        excessShareBps: 0,
        cooldownDuration: 0,
        withdrawalWindow: 0,
        profitMaxUnlockTime: 360 days,
        open: true,
        profitLimitRatio: 100,
        lossLimitRatio: 0,
        depositLimit: 1_000_000e6, // FILL_ME
        depositRateLimit: 100_000e6, // FILL_ME
        withdrawRateLimit: 100_000e6 // FILL_ME
    });

    TrancheConfig internal usdBConfig = TrancheConfig({
        name: "yvUSD Levered",
        symbol: "yvUSD-B",
        targetBps: 500,
        excessShareBps: 6_000,
        cooldownDuration: 7 days,
        withdrawalWindow: 3 days,
        profitMaxUnlockTime: 3 days,
        open: true,
        profitLimitRatio: 1_000,
        lossLimitRatio: 100,
        depositLimit: 1_000_000e6, // FILL_ME
        depositRateLimit: 100_000e6, // FILL_ME
        withdrawRateLimit: 100_000e6 // FILL_ME
    });

    TrancheConfig internal usdEConfig = TrancheConfig({
        name: "yvUSD Equity",
        symbol: "yvUSD-E",
        targetBps: 0,
        excessShareBps: 4_000,
        cooldownDuration: 14 days,
        withdrawalWindow: 7 days,
        profitMaxUnlockTime: 3 days,
        open: false,
        profitLimitRatio: 1_000,
        lossLimitRatio: 1_000,
        depositLimit: 100_000e6, // FILL_ME
        depositRateLimit: 100_000e6, // FILL_ME
        withdrawRateLimit: 100_000e6 // FILL_ME
    });

    TrancheConfig internal wethAConfig = TrancheConfig({
        name: "yvETH Fixed",
        symbol: "yvETH-A",
        targetBps: 300,
        excessShareBps: 0,
        cooldownDuration: 0,
        withdrawalWindow: 0,
        profitMaxUnlockTime: 360 days,
        open: true,
        profitLimitRatio: 1_000,
        lossLimitRatio: 0,
        depositLimit: 100e8, // FILL_ME
        depositRateLimit: 10e8, // FILL_ME
        withdrawRateLimit: 10e8 // FILL_ME
    });

    TrancheConfig internal wethBConfig = TrancheConfig({
        name: "yvETH Levered",
        symbol: "yvETH-B",
        targetBps: 300,
        excessShareBps: 6_000,
        cooldownDuration: 7 days,
        withdrawalWindow: 3 days,
        profitMaxUnlockTime: 3 days,
        open: true,
        profitLimitRatio: 1_000,
        lossLimitRatio: 100,
        depositLimit: 100e8, // FILL_ME
        depositRateLimit: 10e8, // FILL_ME
        withdrawRateLimit: 10e8 // FILL_ME
    });

    TrancheConfig internal wethEConfig = TrancheConfig({
        name: "yvETH Equity",
        symbol: "yvETH-E",
        targetBps: 0,
        excessShareBps: 4_000,
        cooldownDuration: 14 days,
        withdrawalWindow: 7 days,
        profitMaxUnlockTime: 3 days,
        open: false,
        profitLimitRatio: 1_000,
        lossLimitRatio: 1_000,
        depositLimit: 10e18, // FILL_ME
        depositRateLimit: 10e18, // FILL_ME
        withdrawRateLimit: 10e18 // FILL_ME
    });

    TrancheConfig internal btcAConfig = TrancheConfig({
        name: "yvBTC Fixed",
        symbol: "yvBTC-A",
        targetBps: 150,
        excessShareBps: 0,
        cooldownDuration: 0,
        withdrawalWindow: 0,
        profitMaxUnlockTime: 360 days,
        open: true,
        profitLimitRatio: 1_000,
        lossLimitRatio: 0,
        depositLimit: 10e8, // FILL_ME
        depositRateLimit: 1e8, // FILL_ME
        withdrawRateLimit: 1e8 // FILL_ME
    });

    TrancheConfig internal btcEConfig = TrancheConfig({
        name: "yvBTC Equity",
        symbol: "yvBTC-E",
        targetBps: 0,
        excessShareBps: 10_000,
        cooldownDuration: 14 days,
        withdrawalWindow: 7 days,
        profitMaxUnlockTime: 3 days,
        open: false,
        profitLimitRatio: 1_000,
        lossLimitRatio: 1_000,
        depositLimit: 10e18, // FILL_ME
        depositRateLimit: 10e18, // FILL_ME
        withdrawRateLimit: 10e18 // FILL_ME
    });

    function run() external returns (Deployment memory d) {
        _validateInputs();

        vm.startBroadcast(deployer);

        // Every `new` and every Factory call below is its own transaction.
        d.shared.multicall = new GovernanceMulticall(deployer);
        d.shared.authorizer = new Authorizer(address(d.shared.multicall), address(d.shared.multicall));
        d.shared.emergencyAdmin = new EmergencyAdmin(address(d.shared.authorizer));
        d.shared.keeper = new Keeper(address(d.shared.authorizer));
        d.shared.factory = new TrancheFactory(
            address(d.shared.multicall),
            address(d.shared.keeper),
            address(d.shared.emergencyAdmin),
            address(d.shared.authorizer),
            deployer
        );

        // Controllers first. Hooks second. Tranches last. Clean assembly line.
        d.usd = _deployController(usdConfig, d.shared.authorizer);
        d.weth = _deployController(wethConfig, d.shared.authorizer);
        d.btc = _deployController(btcConfig, d.shared.authorizer);

        d.usd.hook = new Hook(address(d.shared.authorizer), address(d.usd.controller));
        d.weth.hook = new Hook(address(d.shared.authorizer), address(d.weth.controller));
        d.btc.hook = new Hook(address(d.shared.authorizer), address(d.btc.controller));

        d.usd.tranches = _deployThreeTranches(d.shared.factory, d.usd, usdAConfig, usdBConfig, usdEConfig);
        d.weth.tranches = _deployThreeTranches(d.shared.factory, d.weth, wethAConfig, wethBConfig, wethEConfig);
        d.btc.tranches = _deployTwoTranches(d.shared.factory, d.btc, btcAConfig, btcEConfig);

        // Yearn `set_role` is role-manager-only. The deployer keeps that key and
        // stages only the narrow permissions needed by the final multicall.
        _stageVaultAccess(d.usd.vault, d.shared, usdVaultRoleHoldersToRevoke);
        _stageVaultAccess(d.weth.vault, d.shared, wethVaultRoleHoldersToRevoke);
        _stageVaultAccess(d.btc.vault, d.shared, btcVaultRoleHoldersToRevoke);

        GovernanceMulticall.Call[] memory calls = _buildConfigurationCalls(d);
        d.shared.multicall.multicall(calls); // One atomic configuration transaction.

        // The hook-manager grants were scaffolding, not permanent power.
        _removeMulticallVaultAccess(d.usd.vault, d.shared.multicall);
        _removeMulticallVaultAccess(d.weth.vault, d.shared.multicall);
        _removeMulticallVaultAccess(d.btc.vault, d.shared.multicall);

        vm.stopBroadcast();

        _validateDeployment(d);
        _logDeployment(d);
    }

    /*//////////////////////////////////////////////////////////////
                              DEPLOYMENT
    //////////////////////////////////////////////////////////////*/

    function _deployController(VaultConfig storage _config, Authorizer _authorizer)
        internal
        returns (SystemDeployment memory system)
    {
        system.vault = IVault(_config.vault);
        system.asset = system.vault.asset();
        system.controller = new TrancheController(system.asset, _config.vault, address(_authorizer));
    }

    function _deployThreeTranches(
        TrancheFactory _factory,
        SystemDeployment memory _system,
        TrancheConfig storage _a,
        TrancheConfig storage _b,
        TrancheConfig storage _e
    ) internal returns (address[] memory tranches) {
        tranches = new address[](3);
        tranches[0] = _deployAtomicTranche(_factory, _system, _a);
        tranches[1] = _deployLockedTranche(_factory, _system, _b);
        tranches[2] = _deployLockedTranche(_factory, _system, _e);
    }

    function _deployTwoTranches(
        TrancheFactory _factory,
        SystemDeployment memory _system,
        TrancheConfig storage _a,
        TrancheConfig storage _e
    ) internal returns (address[] memory tranches) {
        tranches = new address[](2);
        tranches[0] = _deployAtomicTranche(_factory, _system, _a);
        tranches[1] = _deployLockedTranche(_factory, _system, _e);
    }

    function _deployAtomicTranche(
        TrancheFactory _factory,
        SystemDeployment memory _system,
        TrancheConfig storage _config
    ) internal returns (address) {
        return _factory.newTrancheStrategy(
            _system.asset, _config.name, _config.symbol, address(_system.controller), address(_system.hook)
        );
    }

    function _deployLockedTranche(
        TrancheFactory _factory,
        SystemDeployment memory _system,
        TrancheConfig storage _config
    ) internal returns (address) {
        return _factory.newLockedTrancheStrategy(
            _system.asset,
            _config.name,
            _config.symbol,
            address(_system.controller),
            address(_system.hook),
            _config.cooldownDuration,
            _config.withdrawalWindow
        );
    }

    function _stageVaultAccess(IVault _vault, SharedDeployment memory _shared, address[] storage _roleHoldersToRevoke)
        internal
    {
        _vault.set_role(address(_shared.multicall), VAULT_HOOK_MANAGER_ROLES);
        _vault.set_role(address(_shared.emergencyAdmin), VaultRoles.EMERGENCY_MANAGER | VaultRoles.MAX_DEBT_MANAGER);

        for (uint256 i; i < _roleHoldersToRevoke.length; ++i) {
            _vault.set_role(_roleHoldersToRevoke[i], 0);
        }

        require(_vault.role_manager() == deployer, "!deployer role manager");
        require(_vault.roles(address(_shared.multicall)) == VAULT_HOOK_MANAGER_ROLES, "!multicall vault roles");
        require(
            _vault.roles(address(_shared.emergencyAdmin)) == VaultRoles.EMERGENCY_MANAGER | VaultRoles.MAX_DEBT_MANAGER,
            "!emergency vault roles"
        );
    }

    function _removeMulticallVaultAccess(IVault _vault, GovernanceMulticall _multicall) internal {
        _vault.set_role(address(_multicall), 0);
        require(_vault.roles(address(_multicall)) == 0, "multicall vault roles remain");
    }

    /*//////////////////////////////////////////////////////////////
                         ATOMIC CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    function _buildConfigurationCalls(Deployment memory _deployment)
        internal
        view
        returns (GovernanceMulticall.Call[] memory calls)
    {
        calls = new GovernanceMulticall.Call[](BASE_CONFIG_CALL_COUNT);
        uint256 index;

        index = _appendAuthorizerCalls(calls, index, _deployment.shared);

        index = _appendThreeSystemCalls(calls, index, _deployment.usd, usdConfig, usdAConfig, usdBConfig, usdEConfig);
        index =
            _appendThreeSystemCalls(calls, index, _deployment.weth, wethConfig, wethAConfig, wethBConfig, wethEConfig);
        index = _appendTwoSystemCalls(calls, index, _deployment.btc, btcConfig, btcAConfig, btcEConfig);

        require(index == calls.length, "!configuration call count");
    }

    function _appendAuthorizerCalls(
        GovernanceMulticall.Call[] memory _calls,
        uint256 _index,
        SharedDeployment memory _shared
    ) internal view returns (uint256) {
        _index = _appendCall(
            _calls,
            _index,
            address(_shared.authorizer),
            abi.encodeWithSelector(Authorizer.grantRole.selector, KEEPER_ROLE, address(_shared.keeper))
        );
        _index = _appendCall(
            _calls,
            _index,
            address(_shared.authorizer),
            abi.encodeWithSelector(Authorizer.grantRole.selector, KEEPER_ROLE, deployer)
        );
        _index = _appendCall(
            _calls,
            _index,
            address(_shared.authorizer),
            abi.encodeWithSelector(Authorizer.grantRole.selector, EMERGENCY_ROLE, deployer)
        );
        return _appendCall(
            _calls,
            _index,
            address(_shared.authorizer),
            abi.encodeWithSelector(Authorizer.grantRole.selector, MANAGEMENT_ROLE, deployer)
        );
    }

    function _appendThreeSystemCalls(
        GovernanceMulticall.Call[] memory _calls,
        uint256 _index,
        SystemDeployment memory _system,
        VaultConfig storage _vaultConfig,
        TrancheConfig storage _a,
        TrancheConfig storage _b,
        TrancheConfig storage _e
    ) internal view returns (uint256) {
        _index = _appendSystemStart(_calls, _index, _system, _vaultConfig);
        _index = _appendTrancheCalls(_calls, _index, _system, _system.tranches[0], _a);
        _index = _appendTrancheCalls(_calls, _index, _system, _system.tranches[1], _b);
        _index = _appendTrancheCalls(_calls, _index, _system, _system.tranches[2], _e);
        _index = _appendHookConfigCalls(_calls, _index, _system, _vaultConfig);
        _index = _appendTargetLimitCalls(_calls, _index, _system.hook, address(_system.vault), _vaultConfig);
        _index = _appendTargetLimitCalls(_calls, _index, _system.hook, _system.tranches[0], _a);
        _index = _appendTargetLimitCalls(_calls, _index, _system.hook, _system.tranches[1], _b);
        _index = _appendTargetLimitCalls(_calls, _index, _system.hook, _system.tranches[2], _e);
        return _appendVaultHookCalls(_calls, _index, _system);
    }

    function _appendTwoSystemCalls(
        GovernanceMulticall.Call[] memory _calls,
        uint256 _index,
        SystemDeployment memory _system,
        VaultConfig storage _vaultConfig,
        TrancheConfig storage _a,
        TrancheConfig storage _e
    ) internal view returns (uint256) {
        _index = _appendSystemStart(_calls, _index, _system, _vaultConfig);
        _index = _appendTrancheCalls(_calls, _index, _system, _system.tranches[0], _a);
        _index = _appendTrancheCalls(_calls, _index, _system, _system.tranches[1], _e);
        _index = _appendHookConfigCalls(_calls, _index, _system, _vaultConfig);
        _index = _appendTargetLimitCalls(_calls, _index, _system.hook, address(_system.vault), _vaultConfig);
        _index = _appendTargetLimitCalls(_calls, _index, _system.hook, _system.tranches[0], _a);
        _index = _appendTargetLimitCalls(_calls, _index, _system.hook, _system.tranches[1], _e);
        return _appendVaultHookCalls(_calls, _index, _system);
    }

    function _appendSystemStart(
        GovernanceMulticall.Call[] memory _calls,
        uint256 _index,
        SystemDeployment memory _system,
        VaultConfig storage _config
    ) internal view returns (uint256) {
        return _appendCall(
            _calls,
            _index,
            address(_system.controller),
            abi.encodeCall(TrancheController.setReserveVault, (_config.reserveVault))
        );
    }

    function _appendTrancheCalls(
        GovernanceMulticall.Call[] memory _calls,
        uint256 _index,
        SystemDeployment memory _system,
        address _tranche,
        TrancheConfig storage _config
    ) internal view returns (uint256) {
        _index = _appendCall(
            _calls,
            _index,
            address(_system.controller),
            abi.encodeCall(TrancheController.registerTranche, (_tranche, _config.targetBps, _config.excessShareBps))
        );
        _index = _appendCall(_calls, _index, _tranche, abi.encodeCall(ITokenizedStrategy.acceptManagement, ()));
        _index = _appendCall(
            _calls,
            _index,
            _tranche,
            abi.encodeCall(ITokenizedStrategy.setProfitMaxUnlockTime, (_config.profitMaxUnlockTime))
        );
        _index = _appendCall(_calls, _index, _tranche, abi.encodeCall(IBaseHealthCheck.setOpen, (_config.open)));
        _index = _appendCall(
            _calls, _index, _tranche, abi.encodeCall(IBaseHealthCheck.setProfitLimitRatio, (_config.profitLimitRatio))
        );
        return _appendCall(
            _calls, _index, _tranche, abi.encodeCall(IBaseHealthCheck.setLossLimitRatio, (_config.lossLimitRatio))
        );
    }

    function _appendHookConfigCalls(
        GovernanceMulticall.Call[] memory _calls,
        uint256 _index,
        SystemDeployment memory _system,
        VaultConfig storage _config
    ) internal view returns (uint256) {
        _index = _appendCall(
            _calls, _index, address(_system.hook), abi.encodeCall(Hook.setRateLimitWindow, (_config.rateLimitWindow))
        );
        return _appendCall(_calls, _index, address(_system.hook), abi.encodeCall(Hook.setOpen, (_config.open)));
    }

    function _appendTargetLimitCalls(
        GovernanceMulticall.Call[] memory _calls,
        uint256 _index,
        Hook _hook,
        address _target,
        VaultConfig storage _config
    ) internal view returns (uint256) {
        return _appendTargetLimitCalls(
            _calls, _index, _hook, _target, _config.depositLimit, _config.depositRateLimit, _config.withdrawRateLimit
        );
    }

    function _appendTargetLimitCalls(
        GovernanceMulticall.Call[] memory _calls,
        uint256 _index,
        Hook _hook,
        address _target,
        TrancheConfig storage _config
    ) internal view returns (uint256) {
        return _appendTargetLimitCalls(
            _calls, _index, _hook, _target, _config.depositLimit, _config.depositRateLimit, _config.withdrawRateLimit
        );
    }

    function _appendTargetLimitCalls(
        GovernanceMulticall.Call[] memory _calls,
        uint256 _index,
        Hook _hook,
        address _target,
        uint256 _depositLimit,
        uint128 _depositRateLimit,
        uint128 _withdrawRateLimit
    ) internal pure returns (uint256) {
        _index = _appendCall(
            _calls, _index, address(_hook), abi.encodeCall(Hook.setDepositLimit, (_target, _depositLimit))
        );
        _index = _appendCall(
            _calls, _index, address(_hook), abi.encodeCall(Hook.setDepositRateLimit, (_target, _depositRateLimit))
        );
        return _appendCall(
            _calls, _index, address(_hook), abi.encodeCall(Hook.setWithdrawRateLimit, (_target, _withdrawRateLimit))
        );
    }

    function _appendVaultHookCalls(
        GovernanceMulticall.Call[] memory _calls,
        uint256 _index,
        SystemDeployment memory _system
    ) internal pure returns (uint256) {
        _index = _appendCall(
            _calls,
            _index,
            address(_system.vault),
            abi.encodeWithSignature("set_deposit_hook(address,bool)", address(_system.hook), true)
        );
        return _appendCall(
            _calls, _index, address(_system.vault), abi.encodeCall(IVault.set_withdraw_hook, (address(_system.hook)))
        );
    }

    function _appendCall(GovernanceMulticall.Call[] memory _calls, uint256 _index, address _target, bytes memory _data)
        internal
        pure
        returns (uint256)
    {
        _calls[_index] = GovernanceMulticall.Call({target: _target, value: 0, data: _data});
        return _index + 1;
    }

    /*//////////////////////////////////////////////////////////////
                              VALIDATION
    //////////////////////////////////////////////////////////////*/

    function _validateInputs() internal view {
        require(configConfirmed, "CONFIG_NOT_CONFIRMED");
        require(deployer != address(0), "ZERO deployer");
        require(expectedChainId != 0 && block.chainid == expectedChainId, "WRONG_CHAIN");
        require(existingVaultRolesReviewed, "VAULT_ROLES_NOT_REVIEWED");

        _validateVaultInput(usdConfig);
        _validateVaultInput(wethConfig);
        _validateVaultInput(btcConfig);

        require(
            usdConfig.vault != wethConfig.vault && usdConfig.vault != btcConfig.vault
                && wethConfig.vault != btcConfig.vault,
            "duplicate vault"
        );
        require(
            usdConfig.expectedAsset != wethConfig.expectedAsset && usdConfig.expectedAsset != btcConfig.expectedAsset
                && wethConfig.expectedAsset != btcConfig.expectedAsset,
            "duplicate asset"
        );

        _validateRoleRevocations(IVault(usdConfig.vault), usdVaultRoleHoldersToRevoke);
        _validateRoleRevocations(IVault(wethConfig.vault), wethVaultRoleHoldersToRevoke);
        _validateRoleRevocations(IVault(btcConfig.vault), btcVaultRoleHoldersToRevoke);

        _validateTrancheInput(usdAConfig, false);
        _validateTrancheInput(usdBConfig, true);
        _validateTrancheInput(usdEConfig, true);
        require(
            uint256(usdAConfig.excessShareBps) + usdBConfig.excessShareBps + usdEConfig.excessShareBps <= MAX_BPS,
            "USD excess > MAX_BPS"
        );

        _validateTrancheInput(wethAConfig, false);
        _validateTrancheInput(wethBConfig, true);
        _validateTrancheInput(wethEConfig, true);
        require(
            uint256(wethAConfig.excessShareBps) + wethBConfig.excessShareBps + wethEConfig.excessShareBps <= MAX_BPS,
            "WETH excess > MAX_BPS"
        );

        _validateTrancheInput(btcAConfig, false);
        _validateTrancheInput(btcEConfig, true);
        require(uint256(btcAConfig.excessShareBps) + btcEConfig.excessShareBps <= MAX_BPS, "BTC excess > MAX_BPS");
    }

    function _validateVaultInput(VaultConfig storage _config) internal view {
        require(_config.vault != address(0) && _config.vault.code.length != 0, "bad vault");
        require(_config.rateLimitWindow != 0, "zero rate window");

        IVault vault = IVault(_config.vault);
        address asset = vault.asset();
        require(asset != address(0) && asset.code.length != 0, "bad asset");
        require(asset == _config.expectedAsset, "unexpected asset");
        require(vault.role_manager() == deployer, "deployer not role manager");
        require(vault.future_role_manager() == address(0), "pending role manager");
        _validateLimits(_config.depositLimit, _config.depositRateLimit, _config.withdrawRateLimit);

        if (_config.reserveVault != address(0)) {
            require(_config.reserveVault.code.length != 0, "bad reserve vault");
            require(IERC4626(_config.reserveVault).asset() == asset, "reserve asset mismatch");
        }
    }

    function _validateTrancheInput(TrancheConfig storage _config, bool _locked) internal view {
        require(bytes(_config.name).length != 0, "empty tranche name");
        require(bytes(_config.symbol).length != 0, "empty tranche symbol");
        require(_config.targetBps < MAX_BPS, "target > MAX_BPS");
        require(_config.profitMaxUnlockTime <= type(uint32).max, "profit unlock too long");
        require(_config.profitLimitRatio != 0 && _config.profitLimitRatio <= type(uint16).max, "bad profit limit ratio");
        require(_config.lossLimitRatio < MAX_BPS, "bad loss limit ratio");
        _validateLimits(_config.depositLimit, _config.depositRateLimit, _config.withdrawRateLimit);

        if (_locked) {
            require(_config.cooldownDuration <= 30 days, "cooldown too long");
            require(_config.withdrawalWindow >= 1 days, "window too short");
        } else {
            require(_config.cooldownDuration == 0 && _config.withdrawalWindow == 0, "atomic lock config");
        }
    }

    function _validateRoleRevocations(IVault _vault, address[] storage _roleHolders) internal view {
        for (uint256 i; i < _roleHolders.length; ++i) {
            address roleHolder = _roleHolders[i];
            require(roleHolder != address(0) && roleHolder != deployer, "bad role revocation");
            require(_vault.roles(roleHolder) != 0, "role holder has no roles");

            for (uint256 j; j < i; ++j) {
                require(_roleHolders[j] != roleHolder, "duplicate role revocation");
            }
        }
    }

    function _validateLimits(uint256 _depositLimit, uint128 _depositRateLimit, uint128 _withdrawRateLimit)
        internal
        view
    {
        if (allowZeroLimits) return;
        require(_depositLimit != 0 && _depositRateLimit != 0 && _withdrawRateLimit != 0, "ZERO_LIMIT");
    }

    function _validateDeployment(Deployment memory _deployment) internal view {
        SharedDeployment memory shared = _deployment.shared;

        require(shared.multicall.governance() == deployer, "!multicall governance");
        require(shared.authorizer.governance() == address(shared.multicall), "!authorizer governance");
        require(shared.authorizer.defaultAdmin() == address(shared.multicall), "!authorizer admin");
        require(shared.authorizer.hasRole(MANAGEMENT_ROLE, address(shared.multicall)), "!multicall management");
        require(shared.authorizer.hasRole(MANAGEMENT_ROLE, deployer), "!deployer management");
        require(shared.authorizer.hasRole(KEEPER_ROLE, address(shared.keeper)), "!keeper role");
        require(shared.authorizer.hasRole(KEEPER_ROLE, deployer), "!deployer keeper role");
        require(shared.authorizer.hasRole(EMERGENCY_ROLE, deployer), "!deployer emergency role");

        require(shared.factory.management() == address(shared.multicall), "!factory management");
        require(shared.factory.keeper() == address(shared.keeper), "!factory keeper");
        require(shared.factory.emergencyAdmin() == address(shared.emergencyAdmin), "!factory emergency");
        require(shared.factory.AUTHORIZER() == address(shared.authorizer), "!factory authorizer");
        require(shared.factory.performanceFeeRecipient() == deployer, "!factory fee recipient");

        _validateThreeSystem(_deployment.usd, shared, usdConfig, usdAConfig, usdBConfig, usdEConfig);
        _validateThreeSystem(_deployment.weth, shared, wethConfig, wethAConfig, wethBConfig, wethEConfig);
        _validateTwoSystem(_deployment.btc, shared, btcConfig, btcAConfig, btcEConfig);

        _validateRoleRevocationsApplied(_deployment.usd.vault, usdVaultRoleHoldersToRevoke);
        _validateRoleRevocationsApplied(_deployment.weth.vault, wethVaultRoleHoldersToRevoke);
        _validateRoleRevocationsApplied(_deployment.btc.vault, btcVaultRoleHoldersToRevoke);
    }

    function _validateRoleRevocationsApplied(IVault _vault, address[] storage _roleHolders) internal view {
        for (uint256 i; i < _roleHolders.length; ++i) {
            require(_vault.roles(_roleHolders[i]) == 0, "role revocation failed");
        }
    }

    function _validateThreeSystem(
        SystemDeployment memory _system,
        SharedDeployment memory _shared,
        VaultConfig storage _vaultConfig,
        TrancheConfig storage _a,
        TrancheConfig storage _b,
        TrancheConfig storage _e
    ) internal view {
        _validateSystemBase(_system, _shared, _vaultConfig, 3);
        _validateTrancheDeployment(_system, _shared, _system.tranches[0], _a, false);
        _validateTrancheDeployment(_system, _shared, _system.tranches[1], _b, true);
        _validateTrancheDeployment(_system, _shared, _system.tranches[2], _e, true);
    }

    function _validateTwoSystem(
        SystemDeployment memory _system,
        SharedDeployment memory _shared,
        VaultConfig storage _vaultConfig,
        TrancheConfig storage _a,
        TrancheConfig storage _e
    ) internal view {
        _validateSystemBase(_system, _shared, _vaultConfig, 2);
        _validateTrancheDeployment(_system, _shared, _system.tranches[0], _a, false);
        _validateTrancheDeployment(_system, _shared, _system.tranches[1], _e, true);
    }

    function _validateSystemBase(
        SystemDeployment memory _system,
        SharedDeployment memory _shared,
        VaultConfig storage _config,
        uint256 _trancheCount
    ) internal view {
        require(address(_system.vault) == _config.vault, "!vault");
        require(_system.vault.asset() == _system.asset, "!asset");
        require(_system.asset == _config.expectedAsset, "!expected asset");
        require(_system.vault.role_manager() == deployer, "!deployer role manager");
        require(_system.vault.future_role_manager() == address(0), "!future role manager");
        require(_system.vault.roles(address(_shared.multicall)) == 0, "multicall vault roles remain");
        require(
            _system.vault.roles(address(_shared.emergencyAdmin))
                == VaultRoles.EMERGENCY_MANAGER | VaultRoles.MAX_DEBT_MANAGER,
            "!emergency vault roles"
        );
        require(_system.vault.deposit_hook() == address(_system.hook), "!deposit hook");
        require(_system.vault.withdraw_hook() == address(_system.hook), "!withdraw hook");

        require(address(_system.controller.ASSET()) == _system.asset, "!controller asset");
        require(address(_system.controller.VAULT()) == address(_system.vault), "!controller vault");
        require(address(_system.controller.reserveVault()) == _config.reserveVault, "!reserve vault");
        require(address(_system.hook.CONTROLLER()) == address(_system.controller), "!hook controller");
        require(address(_system.hook.VAULT()) == address(_system.vault), "!hook vault");
        require(_system.hook.rateLimitWindow() == _config.rateLimitWindow, "!rate window");
        require(_system.hook.open() == _config.open, "!vault open");
        require(_system.tranches.length == _trancheCount, "!tranche count");

        address[] memory priority = _system.controller.getTranchesByPriority();
        require(priority.length == _trancheCount, "!priority count");
        for (uint256 i; i < _trancheCount; ++i) {
            require(priority[i] == _system.tranches[i], "!priority");
        }

        _validateTargetLimits(
            _system.hook,
            address(_system.vault),
            _config.depositLimit,
            _config.depositRateLimit,
            _config.withdrawRateLimit
        );
    }

    function _validateTrancheDeployment(
        SystemDeployment memory _system,
        SharedDeployment memory _shared,
        address _tranche,
        TrancheConfig storage _config,
        bool _locked
    ) internal view {
        ITrancheStrategy tranche = ITrancheStrategy(_tranche);
        require(_system.controller.isTranche(_tranche), "!registered tranche");
        require(tranche.management() == address(_shared.multicall), "!tranche management");
        require(tranche.pendingManagement() == address(0), "!pending management");
        require(tranche.keeper() == address(_shared.keeper), "!tranche keeper");
        require(tranche.emergencyAdmin() == address(_shared.emergencyAdmin), "!tranche emergency");
        require(tranche.performanceFee() == 0, "!tranche fee");
        require(tranche.performanceFeeRecipient() == deployer, "!tranche fee recipient");
        require(tranche.profitMaxUnlockTime() == _config.profitMaxUnlockTime, "!profit unlock");
        require(tranche.open() == _config.open, "!tranche open");
        require(tranche.profitLimitRatio() == _config.profitLimitRatio, "!profit ratio");
        require(tranche.lossLimitRatio() == _config.lossLimitRatio, "!loss ratio");
        require(tranche.hook() == address(_system.hook), "!tranche hook");

        if (_locked) {
            require(_shared.factory.isDeployedLockedTranche(_tranche), "!factory locked tranche");
        } else {
            require(_shared.factory.isDeployedTranche(_tranche), "!factory tranche");
        }

        (bool registered,, uint16 excessShareBps, uint256 targetRate,,,) = _system.controller.tranches(_tranche);
        require(registered, "!controller tranche");
        require(targetRate == _targetRate(_config.targetBps), "!target rate");
        require(excessShareBps == _config.excessShareBps, "!excess share");

        _validateTargetLimits(
            _system.hook, _tranche, _config.depositLimit, _config.depositRateLimit, _config.withdrawRateLimit
        );
    }

    function _validateTargetLimits(
        Hook _hook,
        address _target,
        uint256 _depositLimit,
        uint128 _depositRateLimit,
        uint128 _withdrawRateLimit
    ) internal view {
        require(_hook.depositLimits(_target) == _depositLimit, "!deposit limit");
        (,, uint128 actualDepositRateLimit) = _hook.depositRateLimit(_target);
        (,, uint128 actualWithdrawRateLimit) = _hook.withdrawRateLimit(_target);
        require(actualDepositRateLimit == _depositRateLimit, "!deposit rate limit");
        require(actualWithdrawRateLimit == _withdrawRateLimit, "!withdraw rate limit");
    }

    function _targetRate(uint16 _targetBps) internal pure returns (uint256) {
        return (uint256(_targetBps) * 1e18) / (MAX_BPS * SECONDS_PER_YEAR);
    }

    /*//////////////////////////////////////////////////////////////
                                LOGS
    //////////////////////////////////////////////////////////////*/

    function _logDeployment(Deployment memory _deployment) internal view {
        console2.log("Deployer / multicall governance:", deployer);
        console2.log("GovernanceMulticall:", address(_deployment.shared.multicall));
        console2.log("Authorizer:", address(_deployment.shared.authorizer));
        console2.log("EmergencyAdmin:", address(_deployment.shared.emergencyAdmin));
        console2.log("Keeper:", address(_deployment.shared.keeper));
        console2.log("TrancheFactory:", address(_deployment.shared.factory));

        _logSystem("USD", _deployment.usd);
        _logSystem("WETH", _deployment.weth);
        _logSystem("BTC", _deployment.btc);
    }

    function _logSystem(string memory _label, SystemDeployment memory _system) internal view {
        console2.log(string.concat(_label, " vault:"), address(_system.vault));
        console2.log(string.concat(_label, " controller:"), address(_system.controller));
        console2.log(string.concat(_label, " hook:"), address(_system.hook));
        for (uint256 i; i < _system.tranches.length; ++i) {
            console2.log(string.concat(_label, " tranche", vm.toString(i), ":"), _system.tranches[i]);
        }
    }
}
