// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";

import {TokenizedStrategy} from "@tokenized-strategy/TokenizedStrategy.sol";
import {IVault} from "@yearn-vaults/interfaces/IVault.sol";
import {IVaultFactory} from "@yearn-vaults/interfaces/IVaultFactory.sol";
import {Roles as VaultRoles} from "@yearn-vaults/interfaces/Roles.sol";

import {DeployTrancheSystem} from "../../script/Deploy.s.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {VyperDeployer} from "../../lib/yearn-vaults-v3/foundry_tests/utils/VyperDeployer.sol";

contract DeployTrancheSystemHarness is DeployTrancheSystem {
    function configure(address _deployer, address _usdVault, address _wethVault, address _btcVault) external {
        deployer = _deployer;
        expectedChainId = block.chainid;
        configConfirmed = true;
        existingVaultRolesReviewed = true;

        _configureVault(usdConfig, _usdVault, 1 hours, 1_000);
        _configureVault(wethConfig, _wethVault, 2 hours, 2_000);
        _configureVault(btcConfig, _btcVault, 3 hours, 3_000);

        _configureTranche(usdAConfig, 1_100);
        _configureTranche(usdBConfig, 1_200);
        _configureTranche(usdEConfig, 1_300);
        _configureTranche(wethAConfig, 2_100);
        _configureTranche(wethBConfig, 2_200);
        _configureTranche(wethEConfig, 2_300);
        _configureTranche(btcAConfig, 3_100);
        _configureTranche(btcEConfig, 3_200);
    }

    function addRoleRevocations(address _usdHolder, address _wethHolder, address _btcHolder) external {
        usdVaultRoleHoldersToRevoke.push(_usdHolder);
        wethVaultRoleHoldersToRevoke.push(_wethHolder);
        btcVaultRoleHoldersToRevoke.push(_btcHolder);
    }

    function _configureVault(VaultConfig storage _config, address _vault, uint256 _window, uint256 _base) private {
        _config.vault = _vault;
        _config.expectedAsset = IVault(_vault).asset();
        _config.rateLimitWindow = _window;
        _config.open = true;
        _config.depositLimit = _base;
        _config.depositRateLimit = uint128(_base + 1);
        _config.withdrawRateLimit = uint128(_base + 2);
    }

    function _configureTranche(TrancheConfig storage _config, uint256 _base) private {
        _config.open = true;
        _config.lossLimitRatio = 9_999;
        _config.depositLimit = _base;
        _config.depositRateLimit = uint128(_base + 1);
        _config.withdrawRateLimit = uint128(_base + 2);
    }
}

contract DeployTrancheSystemTest is Test {
    address internal constant TOKENIZED_STRATEGY_ADDRESS = 0x310f5Db015E9d6E542fd41bd4542640790791e76;

    MockERC20 internal usd;
    MockERC20 internal weth;
    MockERC20 internal btc;
    IVault internal usdVault;
    IVault internal wethVault;
    IVault internal btcVault;
    DeployTrancheSystemHarness internal deployScript;
    address internal staleUsdRoleHolder = makeAddr("stale USD role holder");
    address internal staleWethRoleHolder = makeAddr("stale WETH role holder");
    address internal staleBtcRoleHolder = makeAddr("stale BTC role holder");

    function setUp() public {
        TokenizedStrategy tokenizedStrategy = new TokenizedStrategy(address(0));
        vm.etch(TOKENIZED_STRATEGY_ADDRESS, address(tokenizedStrategy).code);

        usd = new MockERC20("Mock USD", "mUSD");
        usd.setDecimals(6);
        weth = new MockERC20("Mock WETH", "mWETH");
        btc = new MockERC20("Mock BTC", "mBTC");
        btc.setDecimals(8);

        VyperDeployer vyperDeployer = new VyperDeployer();
        address original = vyperDeployer.deployContract("lib/yearn-vaults-v3/contracts/", "VaultV3");
        IVaultFactory factory = IVaultFactory(
            vyperDeployer.deployContract(
                "lib/yearn-vaults-v3/contracts/",
                "VaultFactory",
                abi.encode("Deployment Test Factory", original, address(this))
            )
        );

        usdVault = _newVault(factory, address(usd), "USD Vault", "yvUSD");
        wethVault = _newVault(factory, address(weth), "WETH Vault", "yvWETH");
        btcVault = _newVault(factory, address(btc), "BTC Vault", "yvBTC");

        usdVault.set_role(staleUsdRoleHolder, VaultRoles.ALL);
        wethVault.set_role(staleWethRoleHolder, VaultRoles.ALL);
        btcVault.set_role(staleBtcRoleHolder, VaultRoles.ALL);

        deployScript = new DeployTrancheSystemHarness();
        deployScript.configure(address(this), address(usdVault), address(wethVault), address(btcVault));
        deployScript.addRoleRevocations(staleUsdRoleHolder, staleWethRoleHolder, staleBtcRoleHolder);
    }

    function test_runDeploysExactTopologyAndConfiguration() public {
        DeployTrancheSystem.Deployment memory deployment = deployScript.run();

        assertEq(deployment.usd.tranches.length, 3, "USD topology");
        assertEq(deployment.weth.tranches.length, 3, "WETH topology");
        assertEq(deployment.btc.tranches.length, 2, "BTC topology");

        assertEq(deployment.usd.asset, address(usd), "USD asset");
        assertEq(deployment.weth.asset, address(weth), "WETH asset");
        assertEq(deployment.btc.asset, address(btc), "BTC asset");

        _assertPriority(deployment.usd);
        _assertPriority(deployment.weth);
        _assertPriority(deployment.btc);

        // The script's internal post-deployment validator checks every role,
        // owner, hook, target rate, health check, and limit before returning.
        assertEq(deployment.shared.multicall.governance(), address(this), "multicall owner");
        assertEq(usdVault.role_manager(), address(this), "USD role manager");
        assertEq(wethVault.role_manager(), address(this), "WETH role manager");
        assertEq(btcVault.role_manager(), address(this), "BTC role manager");
        assertEq(usdVault.roles(address(deployment.shared.multicall)), 0, "USD multicall roles remain");
        assertEq(wethVault.roles(address(deployment.shared.multicall)), 0, "WETH multicall roles remain");
        assertEq(btcVault.roles(address(deployment.shared.multicall)), 0, "BTC multicall roles remain");
        assertEq(usdVault.roles(staleUsdRoleHolder), 0, "stale USD roles");
        assertEq(wethVault.roles(staleWethRoleHolder), 0, "stale WETH roles");
        assertEq(btcVault.roles(staleBtcRoleHolder), 0, "stale BTC roles");
    }

    function _newVault(IVaultFactory _factory, address _asset, string memory _name, string memory _symbol)
        private
        returns (IVault)
    {
        return IVault(_factory.deploy_new_vault(_asset, _name, _symbol, address(this), 0));
    }

    function _assertPriority(DeployTrancheSystem.SystemDeployment memory _system) private view {
        address[] memory priority = _system.controller.getTranchesByPriority();
        assertEq(priority.length, _system.tranches.length, "priority length");
        for (uint256 i; i < priority.length; ++i) {
            assertEq(priority[i], _system.tranches[i], "priority order");
        }
    }
}
