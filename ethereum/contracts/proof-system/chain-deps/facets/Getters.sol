// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "./Base.sol";
import "../../../common/libraries/Diamond.sol";
// import "../../bridgehead/libraries/PriorityQueue.sol";
import "../../../common/libraries/UncheckedMath.sol";
import "../../chain-interfaces/IGetters.sol";

/// @title Getters Contract implements functions for getting contract state from outside the blockchain.
/// @author Matter Labs
contract GettersFacet is ProofChainBase, IGetters {
    using UncheckedMath for uint256;

    // using PriorityQueue for PriorityQueue.Queue;

    string public constant override getName = "GettersFacet";

    /*//////////////////////////////////////////////////////////////
                            CUSTOM GETTERS
    //////////////////////////////////////////////////////////////*/

    /// @return The address of the current governor
    function getBridgehead() external view returns (address) {
        return address(chainStorage.bridgeheadChainContract);
    }

    /// @return The address of the verifier smart contract
    function getVerifier() external view returns (address) {
        return address(chainStorage.verifier);
    }

    /// @return The address of the current governor
    function getGovernor() external view returns (address) {
        return chainStorage.governor;
    }

    /// @return The address of the pending governor
    function getPendingGovernor() external view returns (address) {
        return chainStorage.pendingGovernor;
    }

    /// @return The total number of blocks that were committed
    function getTotalBlocksCommitted() external view returns (uint256) {
        return chainStorage.totalBlocksCommitted;
    }

    /// @return The total number of blocks that were committed & verified
    function getTotalBlocksVerified() external view returns (uint256) {
        return chainStorage.totalBlocksVerified;
    }

    /// @return The total number of blocks that were committed & verified & executed
    function getTotalBlocksExecuted() external view returns (uint256) {
        return chainStorage.totalBlocksExecuted;
    }

    // /// @return The total number of priority operations that were added to the priority queue, including all processed ones
    // function getTotalPriorityTxs() external view returns (uint256) {
    //     return chainStorage.priorityQueue.getTotalPriorityTxs();
    // }

    // /// @notice Returns zero if and only if no operations were processed from the queue
    // /// @notice Reverts if there are no unprocessed priority transactions
    // /// @return Index of the oldest priority operation that wasn't processed yet
    // function getFirstUnprocessedPriorityTx() external view returns (uint256) {
    //     return chainStorage.priorityQueue.getFirstUnprocessedPriorityTx();
    // }

    // /// @return The number of priority operations currently in the queue
    // function getPriorityQueueSize() external view returns (uint256) {
    //     return chainStorage.priorityQueue.getSize();
    // }

    // /// @return The first unprocessed priority operation from the queue
    // function priorityQueueFrontOperation() external view returns (PriorityOperation memory) {
    //     return chainStorage.priorityQueue.front();
    // }

    /// @return Whether the address has a validator access
    function isValidator(address _address) external view returns (bool) {
        return chainStorage.validators[_address];
    }

    /// @notice For unfinalized (non executed) blocks may change
    /// @dev returns zero for non-committed blocks
    /// @return The hash of committed L2 block.
    function storedBlockHash(uint256 _blockNumber) external view returns (bytes32) {
        return chainStorage.storedBlockHashes[_blockNumber];
    }

    /// @return Bytecode hash of bootloader program.
    function getL2BootloaderBytecodeHash() external view returns (bytes32) {
        return chainStorage.l2BootloaderBytecodeHash;
    }

    /// @return Bytecode hash of default account (bytecode for EOA).
    function getL2DefaultAccountBytecodeHash() external view returns (bytes32) {
        return chainStorage.l2DefaultAccountBytecodeHash;
    }

    /// @return Verifier parameters.
    function getVerifierParams() external view returns (VerifierParams memory) {
        return chainStorage.verifierParams;
    }

    /// @return The address of the security council multisig
    function getSecurityCouncil() external view returns (address) {
        return chainStorage.upgrades.securityCouncil;
    }

    /// @return Current upgrade proposal state
    function getUpgradeProposalState() external view returns (ProofUpgradeState) {
        return chainStorage.upgrades.state;
    }

    /// @return The upgrade proposal hash if there is an active one and zero otherwise
    function getProposedUpgradeHash() external view returns (bytes32) {
        return chainStorage.upgrades.proposedUpgradeHash;
    }

    /// @return The timestamp when the upgrade was proposed, zero if there are no active proposals
    function getProposedUpgradeTimestamp() external view returns (uint256) {
        return chainStorage.upgrades.proposedUpgradeTimestamp;
    }

    /// @return The serial number of a proposed upgrade, increments when proposing a new one
    function getCurrentProposalId() external view returns (uint256) {
        return chainStorage.upgrades.currentProposalId;
    }

    /// @return The current protocol version
    function getProtocolVersion() external view returns (uint256) {
        return chainStorage.protocolVersion;
    }

    /// @return The upgrade system contract transaction hash, 0 if the upgrade is not initialized
    function getL2SystemContractsUpgradeTxHash() external view returns (bytes32) {
        return chainStorage.l2SystemContractsUpgradeTxHash;
    }

    /// @return The L2 block number in which the upgrade transaction was processed.
    /// @dev It is equal to 0 in the following two cases:
    /// - No upgrade transaction has ever been processed.
    /// - The upgrade transaction has been processed and the block with such transaction has been
    /// executed (i.e. finalized).
    function getL2SystemContractsUpgradeBlockNumber() external view returns (uint256) {
        return chainStorage.l2SystemContractsUpgradeBlockNumber;
    }

    /// @return The number of received upgrade approvals from the security council
    function isApprovedBySecurityCouncil() external view returns (bool) {
        return chainStorage.upgrades.approvedBySecurityCouncil;
    }

    /// @return Whether the diamond is frozen or not
    function isDiamondStorageFrozen() external view returns (bool) {
        Diamond.DiamondStorage storage ds = Diamond.getDiamondStorage();
        return ds.isFrozen;
    }

    /// @return isFreezable Whether the facet can be frozen by the governor or always accessible
    function isFacetFreezable(address _facet) external view returns (bool isFreezable) {
        Diamond.DiamondStorage storage ds = Diamond.getDiamondStorage();

        // There is no direct way to get whether the facet address is freezable,
        // so we get it from one of the selectors that are associated with the facet.
        uint256 selectorsArrayLen = ds.facetToSelectors[_facet].selectors.length;
        if (selectorsArrayLen != 0) {
            bytes4 selector0 = ds.facetToSelectors[_facet].selectors[0];
            isFreezable = ds.selectorToFacet[selector0].isFreezable;
        }
    }

    /// @return The maximum number of L2 gas that a user can request for L1 -> L2 transactions
    function getPriorityTxMaxGasLimit() external view returns (uint256) {
        return chainStorage.priorityTxMaxGasLimit;
    }

    /// @return The allow list smart contract
    function getAllowList() external view returns (address) {
        return address(chainStorage.allowList);
    }

    /// @return Whether the selector can be frozen by the governor or always accessible
    function isFunctionFreezable(bytes4 _selector) external view returns (bool) {
        Diamond.DiamondStorage storage ds = Diamond.getDiamondStorage();
        require(ds.selectorToFacet[_selector].facetAddress != address(0), "g2");
        return ds.selectorToFacet[_selector].isFreezable;
    }

    /*//////////////////////////////////////////////////////////////
                            DIAMOND LOUPE
     //////////////////////////////////////////////////////////////*/

    /// @return result All facet addresses and their function selectors
    function facets() external view returns (Facet[] memory result) {
        Diamond.DiamondStorage storage ds = Diamond.getDiamondStorage();

        uint256 facetsLen = ds.facets.length;
        result = new Facet[](facetsLen);

        for (uint256 i = 0; i < facetsLen; i = i.uncheckedInc()) {
            address facetAddr = ds.facets[i];
            Diamond.FacetToSelectors memory facetToSelectors = ds.facetToSelectors[facetAddr];

            result[i] = Facet(facetAddr, facetToSelectors.selectors);
        }
    }

    /// @return NON-sorted array with function selectors supported by a specific facet
    function facetFunctionSelectors(address _facet) external view returns (bytes4[] memory) {
        Diamond.DiamondStorage storage ds = Diamond.getDiamondStorage();
        return ds.facetToSelectors[_facet].selectors;
    }

    /// @return NON-sorted array of facet addresses supported on diamond
    function facetAddresses() external view returns (address[] memory) {
        Diamond.DiamondStorage storage ds = Diamond.getDiamondStorage();
        return ds.facets;
    }

    /// @return Facet address associated with a selector. Zero if the selector is not added to the diamond
    function facetAddress(bytes4 _selector) external view returns (address) {
        Diamond.DiamondStorage storage ds = Diamond.getDiamondStorage();
        return ds.selectorToFacet[_selector].facetAddress;
    }
}
