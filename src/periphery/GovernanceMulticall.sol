// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {Governance} from "@periphery/utils/Governance.sol";

/// @notice Governance-owned executor for atomic cross-contract configuration.
contract GovernanceMulticall is Governance {
    struct Call {
        address target;
        uint256 value;
        bytes data;
    }

    constructor(address _governance) Governance(_governance) {
        require(_governance != address(0), "!governance");
    }

    receive() external payable {}

    function multicall(Call[] calldata _calls) external payable onlyGovernance returns (bytes[] memory results) {
        results = new bytes[](_calls.length);

        for (uint256 i; i < _calls.length;) {
            Call calldata call = _calls[i];
            require(call.target != address(0), "!target");

            (bool success, bytes memory result) = call.target.call{value: call.value}(call.data);
            if (!success) _revert(result);

            results[i] = result;

            unchecked {
                ++i;
            }
        }
    }

    function _revert(bytes memory _reason) private pure {
        if (_reason.length == 0) revert("CALL_FAILED");

        assembly {
            revert(add(_reason, 32), mload(_reason))
        }
    }
}
