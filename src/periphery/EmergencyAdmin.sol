// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {IVault} from "@yearn-vaults/interfaces/IVault.sol";
import {IStrategy} from "@tokenized-strategy/interfaces/IStrategy.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

import {Authorized} from "./Authorized.sol";

/**
 * @title EmergencyAdmin
 * @author ytranche
 * @notice Single, central entry point for every emergency halts.
 *         A caller with the relevant role names the target to halt
 *         primitives:
 *           - {pauseVault}        — `setPaused(true)` on a vault OR a strategy
 *           - {shutdownVault}     — `shutdown_vault()` on the main vault
 *           - {shutdownStrategy}  — `shutdownStrategy()` on a strategy
 *           - {emergencyWithdraw} — `emergencyWithdraw()` on a strategy
 *           - {zeroMaxDebtForStrategy} — sets a vault strategy's max debt to 0
 *           - {execute} — forwards calldata to an explicitly authorized target
 *
 *  For these to land, this contract must hold the vault's `EMERGENCY_MANAGER`
 *  and `MAX_DEBT_MANAGER` roles and be set as each strategy's `emergencyAdmin`
 *  (`setEmergencyAdmin`).
 *
 *  The dedicated helpers are halt-only: there is no unpause helper here. An
 *  `execute` role permits every calldata payload sharing its target and selector,
 *  so it must only be granted for deliberately chosen emergency operations.
 */
contract EmergencyAdmin is Authorized {
    constructor(address _authorizer) Authorized(_authorizer) {}

    /// @notice Pause a target — blocks its flows. Works for both the vaults
    ///         and strategies (both expose `setPaused(bool)`). Reversible by
    ///         the target's own pause authority.
    function pauseVault(address _target) external isAuthorized(EMERGENCY_ROLE) {
        IVault(_target).setPaused(true);
    }

    /// @notice Shut a vault down — blocks deposits, leaves withdrawals
    ///         open. Irreversible.
    function shutdownVault(address _vault) external isAuthorized(MANAGEMENT_ROLE) {
        IVault(_vault).shutdown_vault();
    }

    /// @notice Shut a strategy down — blocks deposits. Irreversible.
    function shutdownStrategy(address _strategy) external isAuthorized(MANAGEMENT_ROLE) {
        IStrategy(_strategy).shutdownStrategy();
    }

    /// @notice Pull funds out of a strategy's yield source into its idle balance.
    ///         Requires the strategy to be paused or shut down first.
    function emergencyWithdraw(address _strategy, uint256 _amount) external isAuthorized(EMERGENCY_ROLE) {
        IStrategy(_strategy).emergencyWithdraw(_amount);
    }

    /// @notice Set a vault strategy's max debt to zero.
    ///         Requires this contract to hold the vault's MAX_DEBT_MANAGER role.
    function zeroMaxDebtForStrategy(address _vault, address _strategy) external isAuthorized(EMERGENCY_ROLE) {
        IVault(_vault).update_max_debt_for_strategy(_strategy, 0);
    }

    /// @notice Role required to call `_selector` on `_target` through {execute}.
    /// @dev The fixed-width packed encoding is `target (20 bytes) || selector (4 bytes)`.
    function getRole(address _target, bytes4 _selector) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(_target, _selector));
    }

    /// @notice Forward arbitrary calldata to `_target` after checking the strict
    ///         role for that target and function selector. The role covers every
    ///         argument payload for the selector. No governance bypass applies.
    function execute(address _target, bytes calldata _data)
        external
        hasRole(_getRole(_target, _data))
        returns (bytes memory)
    {
        return Address.functionCall(_target, _data);
    }

    function _getRole(address _target, bytes calldata _data) private pure returns (bytes32) {
        require(_data.length >= 4, "NO_SELECTOR");
        return getRole(_target, bytes4(_data[:4]));
    }
}
