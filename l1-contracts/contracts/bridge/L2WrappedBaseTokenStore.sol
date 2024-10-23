// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-v4/access/Ownable2Step.sol";

import { ZeroAddress, Unauthorized } from "../common/L1ContractErrors.sol";

/// @title L2WrappedBaseTokenStore
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
contract L2WrappedBaseTokenStore is Ownable2Step {
    /// @notice Mapping from chain ID to L2 wrapped base token address.
    mapping(uint256 chainId => address l2WBaseTokenAddress) public l2WBaseTokenAddress;

    /// @notice Admin address with specific permissions.
    address public admin;

    /// @notice used to accept the admin role
    address public pendingAdmin;

    /// @notice Admin changed
    event NewAdmin(address indexed oldAdmin, address indexed newAdmin);

    /// @notice pendingAdmin is changed
    /// @dev Also emitted when new admin is accepted and in this case, `newPendingAdmin` would be zero address
    event NewPendingAdmin(address indexed oldPendingAdmin, address indexed newPendingAdmin);

    /// @notice Emitted when the L2 wrapped base token address is set for a chain
    /// @param chainId The id of the chain.
    /// @param l2WBaseTokenAddress The L2 wrapped base token address.
    event NewWBaseTokenAddress(uint256 indexed chainId, address indexed l2WBaseTokenAddress);

    /// @notice Sets the initial owner and admin.
    /// @param _initialOwner The initial owner.
    /// @param _admin The address of the admin.
    constructor(address _initialOwner, address _admin) {
        if (_admin == address(0) || _initialOwner == address(0)) {
            revert ZeroAddress();
        }
        admin = _admin;
        _transferOwnership(_initialOwner);
    }

    /// @notice Throws if called by any account other than the owner or admin.
    modifier onlyOwnerOrAdmin() {
        if (msg.sender != owner() && msg.sender != admin) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    /// @notice Initializes the L2 WBaseToken address for a specific chain ID.
    /// @dev Can be called by the owner or the admin.
    /// @param _chainId The ID of the blockchain network.
    /// @param _l2WBaseToken The address of the L2 WBaseToken token.
    function initializeChain(uint256 _chainId, address _l2WBaseToken) external onlyOwnerOrAdmin {
        if (_l2WBaseToken == address(0)) {
            revert ZeroAddress();
        }
        _setWBaseTokenAddress(_chainId, _l2WBaseToken);
    }

    /// @notice Reinitializes the L2 WBaseToken address for a specific chain ID.
    /// @dev Can only be called by the owner. It can not be called by the admin second time 
    /// to prevent retroactively damaging existing chains.
    /// @param _chainId The ID of the blockchain network.
    /// @param _l2WBaseToken The new address of the L2 WBaseToken token.
    function reinitializeChain(uint256 _chainId, address _l2WBaseToken) external onlyOwner {
        if (_l2WBaseToken == address(0)) {
            revert ZeroAddress();
        }
        _setWBaseTokenAddress(_chainId, _l2WBaseToken);
    }

    function _setWBaseTokenAddress(uint256 _chainId, address _l2WBaseToken) internal {
        l2WBaseTokenAddress[_chainId] = _l2WBaseToken;
        emit NewWBaseTokenAddress(_chainId, _l2WBaseToken);
    }

    /// @notice Starts the transfer of admin rights. Only the current admin or owner can propose a new pending one.
    /// @notice New admin can accept admin rights by calling `acceptAdmin` function.
    /// @param _newPendingAdmin Address of the new admin
    /// @dev Please note, if the owner wants to enforce the admin change it must execute both `setPendingAdmin` and
    /// `acceptAdmin` atomically. Otherwise `admin` can set different pending admin and so fail to accept the admin rights.
    function setPendingAdmin(address _newPendingAdmin) external onlyOwnerOrAdmin {
        if (_newPendingAdmin == address(0)) {
            revert ZeroAddress();
        }
        // Save previous value into the stack to put it into the event later
        address oldPendingAdmin = pendingAdmin;
        // Change pending admin
        pendingAdmin = _newPendingAdmin;
        emit NewPendingAdmin(oldPendingAdmin, _newPendingAdmin);
    }

    /// @notice Accepts transfer of admin rights. Only pending admin can accept the role.
    function acceptAdmin() external {
        address currentPendingAdmin = pendingAdmin;
        // Only proposed by current admin address can claim the admin rights
        if (msg.sender != currentPendingAdmin) {
            revert Unauthorized(msg.sender);
        }

        address previousAdmin = admin;
        admin = currentPendingAdmin;
        delete pendingAdmin;

        emit NewPendingAdmin(currentPendingAdmin, address(0));
        emit NewAdmin(previousAdmin, currentPendingAdmin);
    }
}
