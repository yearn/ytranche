// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {Authorized} from "./Authorized.sol";
import {ITrancheController} from "../interfaces/ITrancheController.sol";
import {ITrancheStrategy} from "../interfaces/ITrancheStrategy.sol";

/// @notice Batch keeper helper for settlement plus per-Tranche reports.
contract Keeper is Authorized {
    event SettledAndReported(address indexed caller, address indexed controller, uint256 trancheCount);

    constructor(address _authorizer) Authorized(_authorizer) {}

    /// @notice Settle and report every Tranche registered with `_controller`.
    /// @dev One Keeper can service every controller sharing its Authorizer.
    function settleAndReport(address _controller) external isAuthorized(KEEPER_ROLE) {
        require(_controller != address(0), "ZERO controller");
        ITrancheController controller = ITrancheController(_controller);
        controller.settle();

        address[] memory tranches = controller.getTranchesByPriority();
        uint256 trancheCount = tranches.length;
        for (uint256 i = 0; i < trancheCount; ++i) {
            ITrancheStrategy(tranches[i]).report();
        }

        emit SettledAndReported(msg.sender, _controller, trancheCount);
    }
}
