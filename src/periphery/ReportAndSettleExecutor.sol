// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IVault} from "@yearn-vaults/interfaces/IVault.sol";

import {ITrancheController} from "../interfaces/ITrancheController.sol";

interface IAuthorizedView {
    function AUTHORIZER() external view returns (address);
}

/// @notice One-system, one-caller report/process-report/settlement executor.
/// @dev The complete route is fixed at construction. It has no forwarding,
///      management, value, delegatecall, fallback, or partial-execution mode.
contract ReportAndSettleExecutor {
    struct ReportStep {
        address vault;
        address strategy;
        bool callReport;
    }

    error Unauthorized();
    error ReentrantExecution();
    error WrongController();
    error InvalidConfiguration();
    error TrancheRegistrationChanged();
    error StrategyRegistrationChanged(address vault, address strategy);
    error DebtCoverageChanged(address vault, uint256 plannedDebt, uint256 totalDebt);
    error QueueChanged(address vault);
    error MalformedReturn(address target, uint256 expectedLength, uint256 actualLength);

    event Executed(address indexed caller, address indexed controller, bytes32 indexed operationHash);

    bytes4 internal constant REPORT_SELECTOR = bytes4(keccak256("report()"));
    bytes4 internal constant PROCESS_REPORT_SELECTOR = bytes4(keccak256("process_report(address)"));
    bytes4 internal constant SETTLE_AND_REPORT_SELECTOR = bytes4(keccak256("settleAndReport(address)"));

    address public immutable CALLER;
    address public immutable CONTROLLER;
    address public immutable MAIN_VAULT;
    address public immutable KEEPER;
    address public immutable AUTHORIZER;
    bytes32 public immutable EXPECTED_TRANCHES_HASH;
    bytes32 public immutable OPERATION_HASH;

    ReportStep[] internal reportSteps;
    address[] internal vaults;
    mapping(address => bytes32) public expectedQueueHash;
    bool internal entered;

    constructor(
        address _caller,
        address _controller,
        address _keeper,
        address[] memory _vaults,
        address[] memory _strategies,
        bool[] memory _callReport
    ) {
        uint256 length = _vaults.length;
        if (
            _caller == address(0) || _controller.code.length == 0 || _keeper.code.length == 0 || length == 0
                || length != _strategies.length || length != _callReport.length
        ) revert InvalidConfiguration();

        address mainVault = ITrancheController(_controller).VAULT();
        if (mainVault.code.length == 0) revert InvalidConfiguration();
        address authorizer = IAuthorizedView(_controller).AUTHORIZER();
        if (authorizer == address(0) || IAuthorizedView(_keeper).AUTHORIZER() != authorizer) {
            revert InvalidConfiguration();
        }

        bool reachedMainVault;
        for (uint256 i; i < length; ++i) {
            address vault = _vaults[i];
            address strategy = _strategies[i];
            if (vault.code.length == 0 || strategy.code.length == 0 || vault == strategy) {
                revert InvalidConfiguration();
            }
            if (vault == mainVault) {
                reachedMainVault = true;
            } else if (reachedMainVault) {
                // Every nested-vault report must be processed before its
                // parent is folded into the controller's main vault.
                revert InvalidConfiguration();
            }
            for (uint256 j; j < i; ++j) {
                if (_vaults[j] == vault && _strategies[j] == strategy) revert InvalidConfiguration();
            }
            if (!_callReport[i]) {
                bool processedEarlier;
                for (uint256 j; j < length; ++j) {
                    if (_vaults[j] == strategy) {
                        if (j >= i) revert InvalidConfiguration();
                        processedEarlier = true;
                    }
                }
                // Skipping report() is supported only for a nested vault
                // whose own debt-bearing strategies were processed first.
                if (!processedEarlier) revert InvalidConfiguration();
            }
            if (IERC4626(vault).asset() != IERC4626(strategy).asset()) revert InvalidConfiguration();
            if (IVault(vault).strategies(strategy).activation == 0) {
                revert StrategyRegistrationChanged(vault, strategy);
            }

            reportSteps.push(ReportStep(vault, strategy, _callReport[i]));
            bool seenVault;
            for (uint256 j; j < vaults.length; ++j) {
                if (vaults[j] == vault) {
                    seenVault = true;
                    break;
                }
            }
            if (!seenVault) {
                vaults.push(vault);
                expectedQueueHash[vault] = keccak256(abi.encode(IVault(vault).get_default_queue()));
            }
        }
        if (!reachedMainVault) revert InvalidConfiguration();

        CALLER = _caller;
        CONTROLLER = _controller;
        MAIN_VAULT = mainVault;
        KEEPER = _keeper;
        AUTHORIZER = authorizer;
        EXPECTED_TRANCHES_HASH = keccak256(abi.encode(ITrancheController(_controller).getTranchesByPriority()));
        OPERATION_HASH = keccak256(
            abi.encode(
                block.chainid,
                _caller,
                _controller,
                mainVault,
                _keeper,
                _vaults,
                _strategies,
                _callReport,
                EXPECTED_TRANCHES_HASH
            )
        );
        _validateSystem();
    }

    /// @notice Execute the one configured operation for the one controller.
    function execute(address _controller) external {
        if (msg.sender != CALLER) revert Unauthorized();
        if (_controller != CONTROLLER) revert WrongController();
        if (entered) revert ReentrantExecution();

        _validateSystem();
        entered = true;
        uint256 length = reportSteps.length;
        for (uint256 i; i < length; ++i) {
            ReportStep memory current = reportSteps[i];
            if (current.callReport) {
                _callExact(current.strategy, abi.encodeWithSelector(REPORT_SELECTOR), 64);
            }
            _callExact(current.vault, abi.encodeWithSelector(PROCESS_REPORT_SELECTOR, current.strategy), 64);
        }
        _callExact(KEEPER, abi.encodeWithSelector(SETTLE_AND_REPORT_SELECTOR, CONTROLLER), 0);
        entered = false;

        emit Executed(msg.sender, CONTROLLER, OPERATION_HASH);
    }

    function stepsLength() external view returns (uint256) {
        return reportSteps.length;
    }

    function step(uint256 index) external view returns (address vault, address strategy, bool callReport) {
        ReportStep memory value = reportSteps[index];
        return (value.vault, value.strategy, value.callReport);
    }

    function coveredVaults() external view returns (address[] memory) {
        return vaults;
    }

    function _validateSystem() internal view {
        if (ITrancheController(CONTROLLER).VAULT() != MAIN_VAULT) revert InvalidConfiguration();
        if (IAuthorizedView(CONTROLLER).AUTHORIZER() != AUTHORIZER) revert InvalidConfiguration();
        if (IAuthorizedView(KEEPER).AUTHORIZER() != AUTHORIZER) revert InvalidConfiguration();
        if (keccak256(abi.encode(ITrancheController(CONTROLLER).getTranchesByPriority())) != EXPECTED_TRANCHES_HASH) {
            revert TrancheRegistrationChanged();
        }

        uint256 vaultCount = vaults.length;
        uint256 stepCount = reportSteps.length;
        for (uint256 i; i < vaultCount; ++i) {
            address vault = vaults[i];
            if (keccak256(abi.encode(IVault(vault).get_default_queue())) != expectedQueueHash[vault]) {
                revert QueueChanged(vault);
            }
            uint256 plannedDebt;
            for (uint256 j; j < stepCount; ++j) {
                ReportStep memory current = reportSteps[j];
                if (current.vault != vault) continue;
                IVault.StrategyParams memory params = IVault(vault).strategies(current.strategy);
                if (params.activation == 0 || IERC4626(vault).asset() != IERC4626(current.strategy).asset()) {
                    revert StrategyRegistrationChanged(vault, current.strategy);
                }
                plannedDebt += params.current_debt;
            }
            uint256 totalDebt = IVault(vault).totalDebt();
            if (plannedDebt != totalDebt) revert DebtCoverageChanged(vault, plannedDebt, totalDebt);
        }
    }

    function _callExact(address target, bytes memory data, uint256 expectedLength) internal {
        (bool success, bytes memory result) = target.call(data);
        if (!success) {
            assembly {
                revert(add(result, 32), mload(result))
            }
        }
        if (result.length != expectedLength) {
            revert MalformedReturn(target, expectedLength, result.length);
        }
    }
}
