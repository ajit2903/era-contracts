// SPDX-License-Identifier: MIT

pragma solidity ^0.8.21;

import {Test} from "forge-std/Test.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {IBridgehub} from "contracts/bridgehub/IBridgehub.sol";
import {Utils} from "foundry-test/unit/concrete/Utils/Utils.sol";
import {UtilsFacet} from "foundry-test/unit/concrete/Utils/UtilsFacet.sol";
import {AdminFacet} from "contracts/state-transition/chain-deps/facets/Admin.sol";
import {ExecutorFacet} from "contracts/state-transition/chain-deps/facets/Executor.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {DiamondInit} from "contracts/state-transition/chain-deps/DiamondInit.sol";
import {L1GenesisUpgrade as GenesisUpgrade} from "contracts/upgrades/L1GenesisUpgrade.sol";
import {InitializeDataNewChain} from "contracts/state-transition/chain-interfaces/IDiamondInit.sol";
import {ChainTypeManager} from "contracts/state-transition/ChainTypeManager.sol";
import {ChainTypeManagerInitializeData, ChainCreationParams} from "contracts/state-transition/IChainTypeManager.sol";
import {TestnetVerifier} from "contracts/state-transition/TestnetVerifier.sol";
import {DummyBridgehub} from "contracts/dev-contracts/test/DummyBridgehub.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {ZeroAddress} from "contracts/common/L1ContractErrors.sol";

contract ChainTypeManagerTest is Test {
    ChainTypeManager internal chainTypeManager;
    ChainTypeManager internal chainContractAddress;
    GenesisUpgrade internal genesisUpgradeContract;
    address internal bridgehub;
    address internal diamondInit;
    address internal constant governor = address(0x1010101);
    address internal constant admin = address(0x2020202);
    address internal constant baseToken = address(0x3030303);
    address internal constant sharedBridge = address(0x4040404);
    address internal constant validator = address(0x5050505);
    address internal newChainAdmin;
    uint256 chainId = block.chainid;
    address internal testnetVerifier = address(new TestnetVerifier());

    Diamond.FacetCut[] internal facetCuts;

    function setUp() public {
        DummyBridgehub dummyBridgehub = new DummyBridgehub();
        bridgehub = address(dummyBridgehub);
        newChainAdmin = makeAddr("chainadmin");

        vm.startPrank(bridgehub);
        chainTypeManager = new ChainTypeManager(address(IBridgehub(address(bridgehub))));
        diamondInit = address(new DiamondInit());
        genesisUpgradeContract = new GenesisUpgrade();

        facetCuts.push(
            Diamond.FacetCut({
                facet: address(new UtilsFacet()),
                action: Diamond.Action.Add,
                isFreezable: true,
                selectors: Utils.getUtilsFacetSelectors()
            })
        );
        facetCuts.push(
            Diamond.FacetCut({
                facet: address(new AdminFacet(block.chainid)),
                action: Diamond.Action.Add,
                isFreezable: true,
                selectors: Utils.getAdminSelectors()
            })
        );
        facetCuts.push(
            Diamond.FacetCut({
                facet: address(new ExecutorFacet()),
                action: Diamond.Action.Add,
                isFreezable: true,
                selectors: Utils.getExecutorSelectors()
            })
        );
        facetCuts.push(
            Diamond.FacetCut({
                facet: address(new GettersFacet()),
                action: Diamond.Action.Add,
                isFreezable: true,
                selectors: Utils.getGettersSelectors()
            })
        );

        ChainCreationParams memory chainCreationParams = ChainCreationParams({
            genesisUpgrade: address(genesisUpgradeContract),
            genesisBatchHash: bytes32(uint256(0x01)),
            genesisIndexRepeatedStorageChanges: 0x01,
            genesisBatchCommitment: bytes32(uint256(0x01)),
            diamondCut: getDiamondCutData(address(diamondInit)),
            forceDeploymentsData: bytes("")
        });

        ChainTypeManagerInitializeData memory ctmInitializeDataNoGovernor = ChainTypeManagerInitializeData({
            owner: address(0),
            validatorTimelock: validator,
            chainCreationParams: chainCreationParams,
            protocolVersion: 0
        });

        vm.expectRevert(ZeroAddress.selector);
        new TransparentUpgradeableProxy(
            address(chainTypeManager),
            admin,
            abi.encodeCall(ChainTypeManager.initialize, ctmInitializeDataNoGovernor)
        );

        ChainTypeManagerInitializeData memory ctmInitializeData = ChainTypeManagerInitializeData({
            owner: governor,
            validatorTimelock: validator,
            chainCreationParams: chainCreationParams,
            protocolVersion: 0
        });

        TransparentUpgradeableProxy transparentUpgradeableProxy = new TransparentUpgradeableProxy(
            address(chainTypeManager),
            admin,
            abi.encodeCall(ChainTypeManager.initialize, ctmInitializeData)
        );
        chainContractAddress = ChainTypeManager(address(transparentUpgradeableProxy));

        vm.stopPrank();
        vm.startPrank(governor);
    }

    function getDiamondCutData(address _diamondInit) internal view returns (Diamond.DiamondCutData memory) {
        InitializeDataNewChain memory initializeData = Utils.makeInitializeDataForNewChain(testnetVerifier);

        bytes memory initCalldata = abi.encode(initializeData);

        return Diamond.DiamondCutData({facetCuts: facetCuts, initAddress: _diamondInit, initCalldata: initCalldata});
    }

    function createNewChain(Diamond.DiamondCutData memory _diamondCut) internal returns (address) {
        vm.stopPrank();
        vm.startPrank(bridgehub);

        return
            chainContractAddress.createNewChain({
                _chainId: chainId,
                _baseTokenAssetId: DataEncoding.encodeNTVAssetId(block.chainid, baseToken),
                _sharedBridge: sharedBridge,
                _admin: newChainAdmin,
                _initData: abi.encode(abi.encode(_diamondCut), bytes("")),
                _factoryDeps: new bytes[](0)
            });
    }

    // add this to be excluded from coverage report
    function test() internal virtual {}
}