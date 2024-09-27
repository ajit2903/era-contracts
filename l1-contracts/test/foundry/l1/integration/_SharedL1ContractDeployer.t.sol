// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {StdStorage, stdStorage} from "forge-std/Test.sol";

import {DeployL1Script} from "deploy-scripts/DeployL1.s.sol";
import {Bridgehub} from "contracts/bridgehub/Bridgehub.sol";
import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";
import {L1Nullifier} from "contracts/bridge/L1Nullifier.sol";
import {L1NativeTokenVault} from "contracts/bridge/ntv/L1NativeTokenVault.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {CTMDeploymentTracker} from "contracts/bridgehub/CTMDeploymentTracker.sol";

contract L1ContractDeployer is Test {
    using stdStorage for StdStorage;

    address bridgehubProxyAddress;
    address bridgehubOwnerAddress;
    Bridgehub bridgeHub;

    CTMDeploymentTracker ctmDeploymentTracker;

    L1AssetRouter public sharedBridge;
    L1Nullifier public l1Nullifier;
    L1NativeTokenVault public l1NativeTokenVault;

    DeployL1Script l1Script;

    function _deployL1Contracts() internal {
        vm.setEnv("L1_CONFIG", "/test/foundry/l1/integration/deploy-scripts/script-config/config-deploy-l1.toml");
        vm.setEnv("L1_OUTPUT", "/test/foundry/l1/integration/deploy-scripts/script-out/output-deploy-l1.toml");
        vm.setEnv(
            "ZK_CHAIN_CONFIG",
            "/test/foundry/l1/integration/deploy-scripts/script-config/config-deploy-zk-chain-era.toml"
        );
        vm.setEnv(
            "ZK_CHAIN_OUT",
            "/test/foundry/l1/integration/deploy-scripts/script-out/output-deploy-zk-chain-era.toml"
        );

        l1Script = new DeployL1Script();
        l1Script.runForTest();

        bridgehubProxyAddress = l1Script.getBridgehubProxyAddress();
        bridgeHub = Bridgehub(bridgehubProxyAddress);

        address sharedBridgeProxyAddress = l1Script.getSharedBridgeProxyAddress();
        sharedBridge = L1AssetRouter(sharedBridgeProxyAddress);

        address l1NullifierProxyAddress = l1Script.getL1NullifierProxyAddress();
        l1Nullifier = L1Nullifier(l1NullifierProxyAddress);

        address l1NativeTokenVaultProxyAddress = l1Script.getNativeTokenVaultProxyAddress();
        l1NativeTokenVault = L1NativeTokenVault(payable(l1NativeTokenVaultProxyAddress));

        ctmDeploymentTracker = CTMDeploymentTracker(l1Script.getCTMDeploymentTrackerAddress());

        _acceptOwnership();
        _setEraBatch();

        bridgehubOwnerAddress = bridgeHub.owner();
    }

    function _acceptOwnership() private {
        vm.startPrank(bridgeHub.pendingOwner());
        bridgeHub.acceptOwnership();
        sharedBridge.acceptOwnership();
        ctmDeploymentTracker.acceptOwnership();
        vm.stopPrank();
    }

    function _setEraBatch() private {
        vm.startPrank(sharedBridge.owner());
        // sharedBridge.setEraPostLegacyBridgeUpgradeFirstBatch(1);
        // sharedBridge.setEraPostDiamondUpgradeFirstBatch(1);
        vm.stopPrank();
    }

    function _registerNewToken(address _tokenAddress) internal {
        bytes32 tokenAssetId = DataEncoding.encodeNTVAssetId(block.chainid, _tokenAddress);
        if (!bridgeHub.assetIdIsRegistered(tokenAssetId)) {
            vm.prank(bridgehubOwnerAddress);
            bridgeHub.addTokenAssetId(tokenAssetId);
        }
    }

    function _registerNewTokens(address[] memory _tokens) internal {
        for (uint256 i = 0; i < _tokens.length; i++) {
            _registerNewToken(_tokens[i]);
        }
    }

    function _setSharedBridgeChainBalance(uint256 _chainId, address _token, uint256 _value) internal {
        stdstore
            .target(address(l1Nullifier))
            .sig(l1Nullifier.chainBalance.selector)
            .with_key(_chainId)
            .with_key(_token)
            .checked_write(_value);
    }

    function _setSharedBridgeIsWithdrawalFinalized(
        uint256 _chainId,
        uint256 _l2BatchNumber,
        uint256 _l2ToL1MessageNumber,
        bool _isFinalized
    ) internal {
        stdstore
            .target(address(l1Nullifier))
            .sig(l1Nullifier.isWithdrawalFinalized.selector)
            .with_key(_chainId)
            .with_key(_l2BatchNumber)
            .with_key(_l2ToL1MessageNumber)
            .checked_write(_isFinalized);
    }

    // add this to be excluded from coverage report
    function test() internal virtual {}
}
