// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

// solhint-disable reason-string, gas-custom-errors

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IL1ERC20Bridge} from "./interfaces/IL1ERC20Bridge.sol";
import {IL1AssetRouter} from "./interfaces/IL1AssetRouter.sol";
import {IL1Nullifier} from "./interfaces/IL1Nullifier.sol";
import {IL2Bridge} from "./interfaces/IL2Bridge.sol";
import {IL2BridgeLegacy} from "./interfaces/IL2BridgeLegacy.sol";
import {IL1AssetHandler} from "./interfaces/IL1AssetHandler.sol";
import {IL1NativeTokenVault} from "./interfaces/IL1NativeTokenVault.sol";

import {IMailbox} from "../state-transition/chain-interfaces/IMailbox.sol";
import {L2Message, TxStatus} from "../common/Messaging.sol";
import {UnsafeBytes} from "../common/libraries/UnsafeBytes.sol";
import {ReentrancyGuard} from "../common/ReentrancyGuard.sol";
import {AddressAliasHelper} from "../vendor/AddressAliasHelper.sol";
import {TWO_BRIDGES_MAGIC_VALUE, ETH_TOKEN_ADDRESS} from "../common/Config.sol";
import {L2_NATIVE_TOKEN_VAULT_ADDRESS} from "../common/L2ContractAddresses.sol";

import {IBridgehub, L2TransactionRequestTwoBridgesInner, L2TransactionRequestDirect} from "../bridgehub/IBridgehub.sol";
import {L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, L2_ASSET_ROUTER_ADDR} from "../common/L2ContractAddresses.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev Bridges assets between L1 and ZK chain, supporting both ETH and ERC20 tokens.
/// @dev Designed for use with a proxy for upgradability.
contract L1Nullifier is IL1Nullifier, ReentrancyGuard, Ownable2StepUpgradeable, PausableUpgradeable {
    using SafeERC20 for IERC20;

    /// @dev The address of the WETH token on L1.
    address public immutable override L1_WETH_TOKEN;

    /// @dev Bridgehub smart contract that is used to operate with L2 via asynchronous L2 <-> L1 communication.
    IBridgehub public immutable override BRIDGE_HUB;

    /// @dev Era's chainID
    uint256 internal immutable ERA_CHAIN_ID;

    /// @dev The address of zkSync Era diamond proxy contract.
    address internal immutable ERA_DIAMOND_PROXY;

    /// @dev Stores the first batch number on the zkSync Era Diamond Proxy that was settled after Diamond proxy upgrade.
    /// This variable is used to differentiate between pre-upgrade and post-upgrade Eth withdrawals. Withdrawals from batches older
    /// than this value are considered to have been finalized prior to the upgrade and handled separately.
    uint256 internal eraPostDiamondUpgradeFirstBatch;

    /// @dev Stores the first batch number on the zkSync Era Diamond Proxy that was settled after L1ERC20 Bridge upgrade.
    /// This variable is used to differentiate between pre-upgrade and post-upgrade ERC20 withdrawals. Withdrawals from batches older
    /// than this value are considered to have been finalized prior to the upgrade and handled separately.
    uint256 internal eraPostLegacyBridgeUpgradeFirstBatch;

    /// @dev Stores the zkSync Era batch number that processes the last deposit tx initiated by the legacy bridge.
    /// This variable (together with eraLegacyBridgeLastDepositTxNumber) is used to differentiate between pre-upgrade and post-upgrade deposits. Deposits processed in older batches
    /// than this value are considered to have been processed prior to the upgrade and handled separately.
    /// We use this both for Eth and erc20 token deposits, so we need to update the diamond and bridge simultaneously.
    uint256 internal eraLegacyBridgeLastDepositBatch;

    /// @dev The tx number in the _eraLegacyBridgeLastDepositBatch of the last deposit tx initiated by the legacy bridge.
    /// This variable (together with eraLegacyBridgeLastDepositBatch) is used to differentiate between pre-upgrade and post-upgrade deposits. Deposits processed in older txs
    /// than this value are considered to have been processed prior to the upgrade and handled separately.
    /// We use this both for Eth and erc20 token deposits, so we need to update the diamond and bridge simultaneously.
    uint256 internal eraLegacyBridgeLastDepositTxNumber;

    /// @dev Legacy bridge smart contract that used to hold ERC20 tokens.
    IL1ERC20Bridge public override legacyBridge;

    /// @dev A mapping chainId => bridgeProxy. Used to store the bridge proxy's address, and to see if it has been deployed yet.
    mapping(uint256 chainId => address l2Bridge) public __DEPRECATED_l2BridgeAddress;

    /// @dev A mapping chainId => L2 deposit transaction hash => keccak256(abi.encode(account, tokenAddress, amount)).
    /// @dev Tracks deposit transactions from L2 to enable users to claim their funds if a deposit fails.
    mapping(uint256 chainId => mapping(bytes32 l2DepositTxHash => bytes32 depositDataHash))
        public
        override depositHappened;

    /// @dev Tracks the processing status of L2 to L1 messages, indicating whether a message has already been finalized.
    mapping(uint256 chainId => mapping(uint256 l2BatchNumber => mapping(uint256 l2ToL1MessageNumber => bool isFinalized)))
        public isWithdrawalFinalized;

    /// @dev Indicates whether the hyperbridging is enabled for a given chain.
    // slither-disable-next-line uninitialized-state
    mapping(uint256 chainId => bool enabled) public hyperbridgingEnabled;

    /// @dev Maps token balances for each chain to prevent unauthorized spending across ZK chain.
    /// This serves as a security measure until hyperbridging is implemented.
    /// NOTE: this function may be removed in the future, don't rely on it!
    mapping(uint256 chainId => mapping(address l1Token => uint256 balance)) public chainBalance;

    /// @dev Address of native token vault.
    IL1NativeTokenVault public nativeTokenVault;

    /// @dev Address of L1 asset router.
    IL1AssetRouter public l1AssetRouter;

    /// @notice Checks that the message sender is the bridgehub.
    modifier onlyAssetRouter() {
        require(msg.sender == address(BRIDGE_HUB), "Nullifier: not asset router");
        _;
    }

    /// @notice Checks that the message sender is the bridgehub or zkSync Era Diamond Proxy.
    modifier onlyBridgehubOrEra(uint256 _chainId) {
        require(
            msg.sender == address(BRIDGE_HUB) || (_chainId == ERA_CHAIN_ID && msg.sender == ERA_DIAMOND_PROXY),
            "L1AssetRouter: msg.sender not equal to bridgehub or era chain"
        );
        _;
    }

    /// @notice Checks that the message sender is the legacy bridge.
    modifier onlyLegacyBridge() {
        require(msg.sender == address(legacyBridge), "ShB not legacy bridge");
        _;
    }

    /// @dev Contract is expected to be used as proxy implementation.
    /// @dev Initialize the implementation to prevent Parity hack.
    constructor(
        address _l1WethAddress,
        IBridgehub _bridgehub,
        uint256 _eraChainId,
        address _eraDiamondProxy
    ) reentrancyGuardInitializer {
        _disableInitializers();
        L1_WETH_TOKEN = _l1WethAddress;
        BRIDGE_HUB = _bridgehub;
        ERA_CHAIN_ID = _eraChainId;
        ERA_DIAMOND_PROXY = _eraDiamondProxy;
    }

    /// @dev Initializes a contract bridge for later use. Expected to be used in the proxy.
    /// @dev Used for testing purposes only, as the contract has been initialized on mainnet.
    /// @param _owner The address which can change L2 token implementation and upgrade the bridge implementation.
    /// The owner is the Governor and separate from the ProxyAdmin from now on, so that the Governor can call the bridge.
    /// @param _eraPostDiamondUpgradeFirstBatch The first batch number on the zkSync Era Diamond Proxy that was settled after diamond proxy upgrade.
    /// @param _eraPostLegacyBridgeUpgradeFirstBatch The first batch number on the zkSync Era Diamond Proxy that was settled after legacy bridge upgrade.
    /// @param _eraLegacyBridgeLastDepositBatch The the zkSync Era batch number that processes the last deposit tx initiated by the legacy bridge.
    /// @param _eraLegacyBridgeLastDepositTxNumber The tx number in the _eraLegacyBridgeLastDepositBatch of the last deposit tx initiated by the legacy bridge.
    function initialize(
        address _owner,
        uint256 _eraPostDiamondUpgradeFirstBatch,
        uint256 _eraPostLegacyBridgeUpgradeFirstBatch,
        uint256 _eraLegacyBridgeLastDepositBatch,
        uint256 _eraLegacyBridgeLastDepositTxNumber
    ) external reentrancyGuardInitializer initializer {
        require(_owner != address(0), "ShB owner 0");
        _transferOwnership(_owner);
        if (eraPostDiamondUpgradeFirstBatch == 0) {
            eraPostDiamondUpgradeFirstBatch = _eraPostDiamondUpgradeFirstBatch;
            eraPostLegacyBridgeUpgradeFirstBatch = _eraPostLegacyBridgeUpgradeFirstBatch;
            eraLegacyBridgeLastDepositBatch = _eraLegacyBridgeLastDepositBatch;
            eraLegacyBridgeLastDepositTxNumber = _eraLegacyBridgeLastDepositTxNumber;
        }
    }

    /// @notice Transfers tokens from shared bridge to native token vault.
    /// @dev This function is part of the upgrade process used to transfer liquidity.
    /// @param _token The address of the token to be transferred to NTV.
    function transferTokenToNTV(address _token) external {
        address ntvAddress = address(nativeTokenVault);
        require(msg.sender == ntvAddress, "ShB: not NTV");
        if (ETH_TOKEN_ADDRESS == _token) {
            uint256 amount = address(this).balance;
            bool callSuccess;
            // Low-level assembly call, to avoid any memory copying (save gas)
            assembly {
                callSuccess := call(gas(), ntvAddress, amount, 0, 0, 0, 0)
            }
            require(callSuccess, "ShB: eth transfer failed");
        } else {
            IERC20(_token).safeTransfer(ntvAddress, IERC20(_token).balanceOf(address(this)));
        }
    }

    /// @notice Clears chain balance for specific token.
    /// @dev This function is part of the upgrade process used to nullify chain balances once they are credited to NTV.
    /// @param _chainId The ID of the ZK chain.
    /// @param _token The address of the token which was previously deposit to shared bridge.
    function clearChainBalance(uint256 _chainId, address _token) external {
        require(msg.sender == address(nativeTokenVault), "ShB: not NTV");
        chainBalance[_chainId][_token] = 0;
    }

    /// @notice Sets the L1ERC20Bridge contract address.
    /// @dev Should be called only once by the owner.
    /// @param _legacyBridge The address of the legacy bridge.
    function setL1Erc20Bridge(address _legacyBridge) external onlyOwner {
        require(address(legacyBridge) == address(0), "ShB: legacy bridge already set");
        require(_legacyBridge != address(0), "ShB: legacy bridge 0");
        legacyBridge = IL1ERC20Bridge(_legacyBridge);
    }

    /// @notice Sets the L1ERC20Bridge contract address.
    /// @dev Should be called only once by the owner.
    /// @param _nativeTokenVault The address of the native token vault.
    function setNativeTokenVault(IL1NativeTokenVault _nativeTokenVault) external onlyOwner {
        require(address(nativeTokenVault) == address(0), "Nullifier: native token vault already set");
        require(address(_nativeTokenVault) != address(0), "Nullifier: native token vault 0");
        nativeTokenVault = _nativeTokenVault;
    }

    /// @notice Sets the L1 asset router contract address.
    /// @dev Should be called only once by the owner.
    /// @param _l1AssetRouter The address of the native token vault.
    function setL1AssetRouter(IL1AssetRouter _l1AssetRouter) external onlyOwner {
        require(address(nativeTokenVault) == address(0), "Nullifier: l1 asset router already set");
        require(address(_l1AssetRouter) != address(0), "Nullifier: l1 asset router 0");
        l1AssetRouter = _l1AssetRouter;
    }

    /// @notice Confirms the acceptance of a transaction by the Mailbox, as part of the L2 transaction process within Bridgehub.
    /// This function is utilized by `requestL2TransactionTwoBridges` to validate the execution of a transaction.
    /// @param _chainId The chain ID of the ZK chain to which confirm the deposit.
    /// @param _txDataHash The keccak256 hash of 0x01 || abi.encode(bytes32, bytes) to identify deposits.
    /// @param _txHash The hash of the L1->L2 transaction to confirm the deposit.
    function bridgehubConfirmL2Transaction(
        uint256 _chainId,
        bytes32 _txDataHash,
        bytes32 _txHash
    ) external override onlyAssetRouter whenNotPaused {
        require(depositHappened[_chainId][_txHash] == 0x00, "ShB tx hap");
        depositHappened[_chainId][_txHash] = _txDataHash;
        emit BridgehubDepositFinalized(_chainId, _txDataHash, _txHash);
    }

    /// @dev Withdraw funds from the initiated deposit, that failed when finalizing on L2.
    /// @param _assetId The address of the deposited L1 ERC20 token.
    /// @param _transferData The encoded data, which is used by the asset handler to determine L2 recipient and amount. Might include extra information.
    /// @param _l2TxHash The L2 transaction hash of the failed deposit finalization.
    /// @param _l2BatchNumber The L2 batch number where the deposit finalization was processed.
    /// @param _l2MessageIndex The position in the L2 logs Merkle tree of the l2Log that was sent with the message.
    /// @param _l2TxNumberInBatch The L2 transaction number in a batch, in which the log was sent.
    /// @param _merkleProof The Merkle proof of the processing L1 -> L2 transaction with deposit finalization.
    /// @dev Processes claims of failed deposit, whether they originated from the legacy bridge or the current system.
    function bridgeVerifyFailedTransfer(
        uint256 _chainId,
        bytes32 _assetId,
        bytes memory _transferData,
        bytes32 _l2TxHash,
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes32[] calldata _merkleProof
    ) public onlyAssetRouter nonReentrant whenNotPaused {
        {
            bool proofValid = BRIDGE_HUB.proveL1ToL2TransactionStatus({
                _chainId: _chainId,
                _l2TxHash: _l2TxHash,
                _l2BatchNumber: _l2BatchNumber,
                _l2MessageIndex: _l2MessageIndex,
                _l2TxNumberInBatch: _l2TxNumberInBatch,
                _merkleProof: _merkleProof,
                _status: TxStatus.Failure
            });
            require(proofValid, "yn");
        }

        require(!_isEraLegacyDeposit(_chainId, _l2BatchNumber, _l2TxNumberInBatch), "ShB: legacy cFD");
        {
            bytes32 dataHash = depositHappened[_chainId][_l2TxHash];
            address l1Token = nativeTokenVault.tokenAddress(_assetId);
            (uint256 amount, address prevMsgSender) = abi.decode(_transferData, (uint256, address));
            bytes32 txDataHash = keccak256(abi.encode(prevMsgSender, l1Token, amount));
            require(dataHash == txDataHash, "ShB: d.it not hap");
        }
        delete depositHappened[_chainId][_l2TxHash];
    }

    /// @dev Determines if an eth withdrawal was initiated on zkSync Era before the upgrade to the Shared Bridge.
    /// @param _chainId The chain ID of the transaction to check.
    /// @param _l2BatchNumber The L2 batch number for the withdrawal.
    /// @return Whether withdrawal was initiated on zkSync Era before diamond proxy upgrade.
    function _isEraLegacyEthWithdrawal(uint256 _chainId, uint256 _l2BatchNumber) internal view returns (bool) {
        require((_chainId != ERA_CHAIN_ID) || eraPostDiamondUpgradeFirstBatch != 0, "ShB: diamondUFB not set for Era");
        return (_chainId == ERA_CHAIN_ID) && (_l2BatchNumber < eraPostDiamondUpgradeFirstBatch);
    }

    /// @dev Determines if a token withdrawal was initiated on zkSync Era before the upgrade to the Shared Bridge.
    /// @param _chainId The chain ID of the transaction to check.
    /// @param _l2BatchNumber The L2 batch number for the withdrawal.
    /// @return Whether withdrawal was initiated on zkSync Era before Legacy Bridge upgrade.
    function _isEraLegacyTokenWithdrawal(uint256 _chainId, uint256 _l2BatchNumber) internal view returns (bool) {
        require(
            (_chainId != ERA_CHAIN_ID) || eraPostLegacyBridgeUpgradeFirstBatch != 0,
            "ShB: LegacyUFB not set for Era"
        );
        return (_chainId == ERA_CHAIN_ID) && (_l2BatchNumber < eraPostLegacyBridgeUpgradeFirstBatch);
    }

    /// @dev Determines if a deposit was initiated on zkSync Era before the upgrade to the Shared Bridge.
    /// @param _chainId The chain ID of the transaction to check.
    /// @param _l2BatchNumber The L2 batch number for the deposit where it was processed.
    /// @param _l2TxNumberInBatch The L2 transaction number in the batch, in which the deposit was processed.
    /// @return Whether deposit was initiated on zkSync Era before Shared Bridge upgrade.
    function _isEraLegacyDeposit(
        uint256 _chainId,
        uint256 _l2BatchNumber,
        uint256 _l2TxNumberInBatch
    ) internal view returns (bool) {
        require(
            (_chainId != ERA_CHAIN_ID) || (eraLegacyBridgeLastDepositBatch != 0),
            "ShB: last deposit time not set for Era"
        );
        return
            (_chainId == ERA_CHAIN_ID) &&
            (_l2BatchNumber < eraLegacyBridgeLastDepositBatch ||
                (_l2TxNumberInBatch < eraLegacyBridgeLastDepositTxNumber &&
                    _l2BatchNumber == eraLegacyBridgeLastDepositBatch));
    }

    struct MessageParams {
        uint256 l2BatchNumber;
        uint256 l2MessageIndex;
        uint16 l2TxNumberInBatch;
    }

    /// @notice Internal function that handles the logic for finalizing withdrawals, supporting both the current bridge system and the legacy ERC20 bridge.
    /// @param _chainId The chain ID of the transaction to check.
    /// @param _l2BatchNumber The L2 batch number where the withdrawal was processed.
    /// @param _l2MessageIndex The position in the L2 logs Merkle tree of the l2Log that was sent with the message.
    /// @param _l2TxNumberInBatch The L2 transaction number in the batch, in which the log was sent.
    /// @param _message The L2 withdraw data, stored in an L2 -> L1 message.
    /// @param _merkleProof The Merkle proof of the inclusion L2 -> L1 message about withdrawal initialization.
    /// @return assetId The bridged asset ID.
    /// @return transferData The encoded transfer data.
    function verifyAndGetWithdrawalData(
        uint256 _chainId,
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes calldata _message,
        bytes32[] calldata _merkleProof
    ) external onlyAssetRouter nonReentrant whenNotPaused returns (bytes32 assetId, bytes memory transferData) {
        require(!isWithdrawalFinalized[_chainId][_l2BatchNumber][_l2MessageIndex], "Withdrawal is already finalized");
        isWithdrawalFinalized[_chainId][_l2BatchNumber][_l2MessageIndex] = true;

        // Handling special case for withdrawal from zkSync Era initiated before Shared Bridge.
        require(!_isEraLegacyEthWithdrawal(_chainId, _l2BatchNumber), "ShB: legacy eth withdrawal");
        require(!_isEraLegacyTokenWithdrawal(_chainId, _l2BatchNumber), "ShB: legacy token withdrawal");
        {
            MessageParams memory messageParams = MessageParams({
                l2BatchNumber: _l2BatchNumber,
                l2MessageIndex: _l2MessageIndex,
                l2TxNumberInBatch: _l2TxNumberInBatch
            });
            (assetId, transferData) = _checkWithdrawal(_chainId, messageParams, _message, _merkleProof);
        }
    }

    /// @notice Verifies the validity of a withdrawal message from L2 and returns withdrawal details.
    /// @param _chainId The chain ID of the transaction to check.
    /// @param _messageParams The message params, which include batch number, message index, and L2 tx number in batch.
    /// @param _message The L2 withdraw data, stored in an L2 -> L1 message.
    /// @param _merkleProof The Merkle proof of the inclusion L2 -> L1 message about withdrawal initialization.
    /// @return assetId The ID of the bridged asset.
    /// @return transferData The transfer data used to finalize withdawal.
    function _checkWithdrawal(
        uint256 _chainId,
        MessageParams memory _messageParams,
        bytes calldata _message,
        bytes32[] calldata _merkleProof
    ) internal view returns (bytes32 assetId, bytes memory transferData) {
        (assetId, transferData) = _parseL2WithdrawalMessage(_chainId, _message);
        L2Message memory l2ToL1Message;
        {
            bool baseTokenWithdrawal = (assetId == BRIDGE_HUB.baseTokenAssetId(_chainId));
            address l2Sender = baseTokenWithdrawal ? L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR : L2_ASSET_ROUTER_ADDR;

            l2ToL1Message = L2Message({
                txNumberInBatch: _messageParams.l2TxNumberInBatch,
                sender: l2Sender,
                data: _message
            });
        }

        bool success = BRIDGE_HUB.proveL2MessageInclusion({
            _chainId: _chainId,
            _batchNumber: _messageParams.l2BatchNumber,
            _index: _messageParams.l2MessageIndex,
            _message: l2ToL1Message,
            _proof: _merkleProof
        });
        require(success, "ShB withd w proof"); // withdrawal wrong proof
    }

    /// @notice Parses the withdrawal message and returns withdrawal details.
    /// @dev Currently, 3 different encoding versions are supported: legacy mailbox withdrawal, ERC20 bridge withdrawal,
    /// @dev and the latest version supported by shared bridge. Selectors are used for versioning.
    /// @param _chainId The ZK chain ID.
    /// @param _l2ToL1message The encoded L2 -> L1 message.
    /// @return assetId The ID of the bridged asset.
    /// @return transferData The transfer data used to finalize withdawal.
    function _parseL2WithdrawalMessage(
        uint256 _chainId,
        bytes memory _l2ToL1message
    ) internal view returns (bytes32 assetId, bytes memory transferData) {
        // We check that the message is long enough to read the data.
        // Please note that there are two versions of the message:
        // 1. The message that is sent by `withdraw(address _l1Receiver)`
        // It should be equal to the length of the bytes4 function signature + address l1Receiver + uint256 amount = 4 + 20 + 32 = 56 (bytes).
        // 2. The message that is encoded by `getL1WithdrawMessage(bytes32 _assetId, bytes memory _bridgeMintData)`
        // No length is assume. The assetId is decoded and the mintData is passed to respective assetHandler

        // So the data is expected to be at least 56 bytes long.
        require(_l2ToL1message.length >= 56, "ShB wrong msg len"); // wrong message length
        uint256 amount;
        address l1Receiver;

        (uint32 functionSignature, uint256 offset) = UnsafeBytes.readUint32(_l2ToL1message, 0);
        if (bytes4(functionSignature) == IMailbox.finalizeEthWithdrawal.selector) {
            // this message is a base token withdrawal
            (l1Receiver, offset) = UnsafeBytes.readAddress(_l2ToL1message, offset);
            (amount, offset) = UnsafeBytes.readUint256(_l2ToL1message, offset);
            assetId = BRIDGE_HUB.baseTokenAssetId(_chainId);
            transferData = abi.encode(amount, l1Receiver);
        } else if (bytes4(functionSignature) == IL1ERC20Bridge.finalizeWithdrawal.selector) {
            // We use the IL1ERC20Bridge for backward compatibility with old withdrawals.
            address l1Token;
            // this message is a token withdrawal

            // Check that the message length is correct.
            // It should be equal to the length of the function signature + address + address + uint256 = 4 + 20 + 20 + 32 =
            // 76 (bytes).
            require(_l2ToL1message.length == 76, "ShB wrong msg len 2");
            (l1Receiver, offset) = UnsafeBytes.readAddress(_l2ToL1message, offset);
            (l1Token, offset) = UnsafeBytes.readAddress(_l2ToL1message, offset);
            (amount, offset) = UnsafeBytes.readUint256(_l2ToL1message, offset);

            assetId = keccak256(abi.encode(block.chainid, L2_NATIVE_TOKEN_VAULT_ADDRESS, l1Token));
            transferData = abi.encode(amount, l1Receiver);
        } else if (bytes4(functionSignature) == IL1AssetRouter.finalizeWithdrawal.selector) {
            //todo
            (assetId, offset) = UnsafeBytes.readBytes32(_l2ToL1message, offset);
            transferData = UnsafeBytes.readRemainingBytes(_l2ToL1message, offset);
        } else {
            revert("ShB Incorrect message function selector");
        }
    }

    /*//////////////////////////////////////////////////////////////
            SHARED BRIDGE TOKEN BRIDGING LEGACY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev Withdraw funds from the initiated deposit, that failed when finalizing on L2.
    /// @param _depositSender The address of the deposit initiator.
    /// @param _l1Token The address of the deposited L1 ERC20 token.
    /// @param _amount The amount of the deposit that failed.
    /// @param _l2TxHash The L2 transaction hash of the failed deposit finalization.
    /// @param _l2BatchNumber The L2 batch number where the deposit finalization was processed.
    /// @param _l2MessageIndex The position in the L2 logs Merkle tree of the l2Log that was sent with the message.
    /// @param _l2TxNumberInBatch The L2 transaction number in a batch, in which the log was sent.
    /// @param _merkleProof The Merkle proof of the processing L1 -> L2 transaction with deposit finalization.
    function claimFailedDeposit(
        uint256 _chainId,
        address _depositSender,
        address _l1Token,
        uint256 _amount,
        bytes32 _l2TxHash,
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes32[] calldata _merkleProof
    ) external override {
        bytes32 assetId = nativeTokenVault.getAssetId(_l1Token);
        bytes memory transferData = abi.encode(_amount, _depositSender);
        l1AssetRouter.bridgeRecoverFailedTransfer({
            _chainId: _chainId,
            _depositSender: _depositSender,
            _assetId: assetId,
            _tokenData: transferData,
            _l2TxHash: _l2TxHash,
            _l2BatchNumber: _l2BatchNumber,
            _l2MessageIndex: _l2MessageIndex,
            _l2TxNumberInBatch: _l2TxNumberInBatch,
            _merkleProof: _merkleProof
        });
    }

    /// @notice Ensures that token is registered with native token vault.
    /// @dev Only used when deposit is made with legacy data encoding format.
    /// @param _l1Token The L1 token address which should be registered with native token vault.
    /// @return assetId The asset ID of the token provided.
    function _ensureTokenRegisteredWithNTV(address _l1Token) internal returns (bytes32 assetId) {
        assetId = nativeTokenVault.getAssetId(_l1Token);
        if (nativeTokenVault.tokenAddress(assetId) == address(0)) {
            nativeTokenVault.registerToken(_l1Token);
        }
    }

    /// @notice Receives and parses (name, symbol, decimals) from the token contract.
    /// @param _token The address of token of interest.
    /// @return Returns encoded name, symbol, and decimals for specific token.
    function getERC20Getters(address _token) public view returns (bytes memory) {
        if (_token == ETH_TOKEN_ADDRESS) {
            bytes memory name = bytes("Ether");
            bytes memory symbol = bytes("ETH");
            bytes memory decimals = abi.encode(uint8(18));
            return abi.encode(name, symbol, decimals); // when depositing eth to a non-eth based chain it is an ERC20
        }

        (, bytes memory data1) = _token.staticcall(abi.encodeCall(IERC20Metadata.name, ()));
        (, bytes memory data2) = _token.staticcall(abi.encodeCall(IERC20Metadata.symbol, ()));
        (, bytes memory data3) = _token.staticcall(abi.encodeCall(IERC20Metadata.decimals, ()));
        return abi.encode(data1, data2, data3);
    }

    /*//////////////////////////////////////////////////////////////
                    ERA ERC20 LEGACY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Initiates a deposit by locking funds on the contract and sending the request
    /// of processing an L2 transaction where tokens would be minted.
    /// @dev If the token is bridged for the first time, the L2 token contract will be deployed. Note however, that the
    /// newly-deployed token does not support any custom logic, i.e. rebase tokens' functionality is not supported.
    /// @param _prevMsgSender The `msg.sender` address from the external call that initiated current one.
    /// @param _l2Receiver The account address that should receive funds on L2.
    /// @param _l1Token The L1 token address which is deposited.
    /// @param _amount The total amount of tokens to be bridged.
    /// @param _l2TxGasLimit The L2 gas limit to be used in the corresponding L2 transaction.
    /// @param _l2TxGasPerPubdataByte The gasPerPubdataByteLimit to be used in the corresponding L2 transaction.
    /// @param _refundRecipient The address on L2 that will receive the refund for the transaction.
    /// @dev If the L2 deposit finalization transaction fails, the `_refundRecipient` will receive the `_l2Value`.
    /// Please note, the contract may change the refund recipient's address to eliminate sending funds to addresses
    /// out of control.
    /// - If `_refundRecipient` is a contract on L1, the refund will be sent to the aliased `_refundRecipient`.
    /// - If `_refundRecipient` is set to `address(0)` and the sender has NO deployed bytecode on L1, the refund will
    /// be sent to the `msg.sender` address.
    /// - If `_refundRecipient` is set to `address(0)` and the sender has deployed bytecode on L1, the refund will be
    /// sent to the aliased `msg.sender` address.
    /// @dev The address aliasing of L1 contracts as refund recipient on L2 is necessary to guarantee that the funds
    /// are controllable through the Mailbox, since the Mailbox applies address aliasing to the from address for the
    /// L2 tx if the L1 msg.sender is a contract. Without address aliasing for L1 contracts as refund recipients they
    /// would not be able to make proper L2 tx requests through the Mailbox to use or withdraw the funds from L2, and
    /// the funds would be lost.
    /// @return l2TxHash The L2 transaction hash of deposit finalization.
    function depositLegacyErc20Bridge(
        address _prevMsgSender,
        address _l2Receiver,
        address _l1Token,
        uint256 _amount,
        uint256 _l2TxGasLimit,
        uint256 _l2TxGasPerPubdataByte,
        address _refundRecipient
    ) external payable override onlyLegacyBridge nonReentrant whenNotPaused returns (bytes32 l2TxHash) {
        require(_l1Token != L1_WETH_TOKEN, "ShB: WETH deposit not supported 2");

        bytes32 _assetId;
        bytes memory l2BridgeMintCalldata;

        {
            // Inner call to encode data to decrease local var numbers
            _assetId = _ensureTokenRegisteredWithNTV(_l1Token);

            // solhint-disable-next-line func-named-parameters
            l2BridgeMintCalldata = abi.encode(
                _amount,
                _prevMsgSender,
                _l2Receiver,
                getERC20Getters(_l1Token),
                _l1Token
            );
        }

        {
            bytes memory l2TxCalldata = l1AssetRouter._getDepositL2Calldata(
                _prevMsgSender,
                _assetId,
                l2BridgeMintCalldata
            );

            // If the refund recipient is not specified, the refund will be sent to the sender of the transaction.
            // Otherwise, the refund will be sent to the specified address.
            // If the recipient is a contract on L1, the address alias will be applied.
            address refundRecipient = AddressAliasHelper.actualRefundRecipient(_refundRecipient, _prevMsgSender);

            L2TransactionRequestDirect memory request = L2TransactionRequestDirect({
                chainId: ERA_CHAIN_ID,
                l2Contract: L2_ASSET_ROUTER_ADDR,
                mintValue: msg.value, // l2 gas + l2 msg.Value the bridgehub will withdraw the mintValue from the base token bridge for gas
                l2Value: 0, // L2 msg.value, this contract doesn't support base token deposits or wrapping functionality, for direct deposits use bridgehub
                l2Calldata: l2TxCalldata,
                l2GasLimit: _l2TxGasLimit,
                l2GasPerPubdataByteLimit: _l2TxGasPerPubdataByte,
                factoryDeps: new bytes[](0),
                refundRecipient: refundRecipient
            });
            l2TxHash = BRIDGE_HUB.requestL2TransactionDirect{value: msg.value}(request);
        }

        // Save the deposited amount to claim funds on L1 if the deposit failed on L2
        depositHappened[ERA_CHAIN_ID][l2TxHash] = keccak256(abi.encode(_prevMsgSender, _l1Token, _amount));

        emit LegacyDepositInitiated({
            chainId: ERA_CHAIN_ID,
            l2DepositTxHash: l2TxHash,
            from: _prevMsgSender,
            to: _l2Receiver,
            l1Asset: _l1Token,
            amount: _amount
        });
    }

    /// @notice Finalizes the withdrawal for transactions initiated via the legacy ERC20 bridge.
    /// @param _l2BatchNumber The L2 batch number where the withdrawal was processed.
    /// @param _l2MessageIndex The position in the L2 logs Merkle tree of the l2Log that was sent with the message.
    /// @param _l2TxNumberInBatch The L2 transaction number in the batch, in which the log was sent.
    /// @param _message The L2 withdraw data, stored in an L2 -> L1 message.
    /// @param _merkleProof The Merkle proof of the inclusion L2 -> L1 message about withdrawal initialization.
    ///
    /// @return l1Receiver The address on L1 that will receive the withdrawn funds.
    /// @return l1Asset The address of the L1 token being withdrawn.
    /// @return amount The amount of the token being withdrawn.
    function finalizeWithdrawalLegacyErc20Bridge(
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes calldata _message,
        bytes32[] calldata _merkleProof
    ) external override onlyLegacyBridge returns (address l1Receiver, address l1Asset, uint256 amount) {
        bytes32 assetId;
        (l1Receiver, assetId, amount) = l1AssetRouter.finalizeWithdrawal({
            _chainId: ERA_CHAIN_ID,
            _l2BatchNumber: _l2BatchNumber,
            _l2MessageIndex: _l2MessageIndex,
            _l2TxNumberInBatch: _l2TxNumberInBatch,
            _message: _message,
            _merkleProof: _merkleProof
        });
        l1Asset = nativeTokenVault.tokenAddress(assetId);
    }

    /// @notice Withdraw funds from the initiated deposit, that failed when finalizing on zkSync Era chain.
    /// This function is specifically designed for maintaining backward-compatibility with legacy `claimFailedDeposit`
    /// method in `L1ERC20Bridge`.
    ///
    /// @param _depositSender The address of the deposit initiator.
    /// @param _l1Asset The address of the deposited L1 ERC20 token.
    /// @param _amount The amount of the deposit that failed.
    /// @param _l2TxHash The L2 transaction hash of the failed deposit finalization.
    /// @param _l2BatchNumber The L2 batch number where the deposit finalization was processed.
    /// @param _l2MessageIndex The position in the L2 logs Merkle tree of the l2Log that was sent with the message.
    /// @param _l2TxNumberInBatch The L2 transaction number in a batch, in which the log was sent.
    /// @param _merkleProof The Merkle proof of the processing L1 -> L2 transaction with deposit finalization.
    function claimFailedDepositLegacyErc20Bridge(
        address _depositSender,
        address _l1Asset,
        uint256 _amount,
        bytes32 _l2TxHash,
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes32[] calldata _merkleProof
    ) external override onlyLegacyBridge {
        bytes memory transferData = abi.encode(_amount, _depositSender);
        l1AssetRouter.bridgeRecoverFailedTransfer({
            _chainId: ERA_CHAIN_ID,
            _depositSender: _depositSender,
            _assetId: nativeTokenVault.getAssetId(_l1Asset),
            _tokenData: transferData,
            _l2TxHash: _l2TxHash,
            _l2BatchNumber: _l2BatchNumber,
            _l2MessageIndex: _l2MessageIndex,
            _l2TxNumberInBatch: _l2TxNumberInBatch,
            _merkleProof: _merkleProof
        });
    }

    /*//////////////////////////////////////////////////////////////
                            PAUSE
    //////////////////////////////////////////////////////////////*/

    /// @notice Pauses all functions marked with the `whenNotPaused` modifier.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpauses the contract, allowing all functions marked with the `whenNotPaused` modifier to be called again.
    function unpause() external onlyOwner {
        _unpause();
    }
}