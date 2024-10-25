// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {SYSTEM_CONTEXT_CONTRACT} from "./Constants.sol";
import {ISystemContext} from "./interfaces/ISystemContext.sol";
import {InvalidChainId} from "contracts/SystemContractErrors.sol";
import {IL2GenesisUpgrade} from "./interfaces/IL2GenesisUpgrade.sol";

import {L2GatewayUpgradeHelper} from "./L2GatewayUpgradeHelper.sol";

/// @custom:security-contact security@matterlabs.dev
/// @author Matter Labs
/// @notice The contract that can be used for deterministic contract deployment.
contract L2GenesisUpgrade is IL2GenesisUpgrade {
    function genesisUpgrade(
        uint256 _chainId,
        address _ctmDeployer,
        bytes calldata _fixedForceDeploymentsData,
        bytes calldata _additionalForceDeploymentsData
    ) external payable {
        if (_chainId == 0) {
            revert InvalidChainId();
        }
        ISystemContext(SYSTEM_CONTEXT_CONTRACT).setChainId(_chainId);

        L2GatewayUpgradeHelper.performForceDeployedContractsInit(
            _ctmDeployer,
            _fixedForceDeploymentsData,
            _additionalForceDeploymentsData
        );

        emit UpgradeComplete(_chainId);
    }
}
