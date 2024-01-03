import type { BigNumberish, BytesLike, Wallet } from "ethers";
import { BigNumber, ethers } from "ethers";
import type { Address } from "zksync-web3/build/src/types";
import type { FacetCut } from "../../src.ts/diamondCut";

import { Deployer } from "../../src.ts/deploy";
import { deployTestnetTokens } from "../../src.ts/deploy-testnet-token";
import { initializeWethBridge } from "../../src.ts/weth-initialize";
import { initializeErc20Bridge } from "../../src.ts/erc20-initialize";

import { GovernanceFactory } from "../../typechain";

import { IBridgehub } from "../../typechain/IBridgehub";
import { IMailbox } from "../../typechain/IMailbox";

import * as fs from "fs";

const testConfigPath = "./test/test_config/constant";
export const ethTestConfig = JSON.parse(fs.readFileSync(`${testConfigPath}/eth.json`, { encoding: "utf-8" }));
const addressConfig = JSON.parse(fs.readFileSync(`${testConfigPath}/addresses.json`, { encoding: "utf-8" }));
const testnetTokenPath = `${testConfigPath}/hardhat.json`;
const testnetTokens = JSON.parse(fs.readFileSync(testnetTokenPath, { encoding: "utf-8" }));

export const CONTRACTS_LATEST_PROTOCOL_VERSION = (20).toString();
// eslint-disable-next-line @typescript-eslint/no-var-requires
export const IERC20_INTERFACE = require("@openzeppelin/contracts/build/contracts/IERC20");
export const DEFAULT_REVERT_REASON = "VM did not revert";

export const EMPTY_STRING_KECCAK = "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470";
export const DEFAULT_L2_LOGS_TREE_ROOT_HASH = "0x0000000000000000000000000000000000000000000000000000000000000000";
export const L2_SYSTEM_CONTEXT_ADDRESS = "0x000000000000000000000000000000000000800b";
export const L2_BOOTLOADER_ADDRESS = "0x0000000000000000000000000000000000008001";
export const L2_KNOWN_CODE_STORAGE_ADDRESS = "0x0000000000000000000000000000000000008004";
export const L2_TO_L1_MESSENGER = "0x0000000000000000000000000000000000008008";
export const L2_ETH_TOKEN_SYSTEM_CONTRACT_ADDR = "0x000000000000000000000000000000000000800a";
export const L2_BYTECODE_COMPRESSOR_ADDRESS = "0x000000000000000000000000000000000000800e";

const zeroHash = "0x0000000000000000000000000000000000000000000000000000000000000000";

const L2_BOOTLOADER_BYTECODE_HASH = "0x1000100000000000000000000000000000000000000000000000000000000000";
const L2_DEFAULT_ACCOUNT_BYTECODE_HASH = "0x1001000000000000000000000000000000000000000000000000000000000000";

export enum SYSTEM_LOG_KEYS {
  L2_TO_L1_LOGS_TREE_ROOT_KEY,
  TOTAL_L2_TO_L1_PUBDATA_KEY,
  STATE_DIFF_HASH_KEY,
  PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY,
  PREV_BATCH_HASH_KEY,
  CHAINED_PRIORITY_TXN_HASH_KEY,
  NUMBER_OF_LAYER_1_TXS_KEY,
  EXPECTED_SYSTEM_CONTRACT_UPGRADE_TX_HASH_KEY,
}

// The default price for the pubdata in L2 gas to be used in L1->L2 transactions
export const REQUIRED_L2_GAS_PRICE_PER_PUBDATA =
  // eslint-disable-next-line @typescript-eslint/no-var-requires
  require("../../../SystemConfig.json").REQUIRED_L2_GAS_PRICE_PER_PUBDATA;

/// Set of parameters that are needed to test the processing of priority operations
export class DummyOp {
  constructor(
    public id: number,
    public expirationBatch: BigNumber,
    public layer2Tip: number
  ) {}
}

export async function getCallRevertReason(promise) {
  let revertReason = DEFAULT_REVERT_REASON;
  try {
    await promise;
  } catch (e) {
    try {
      await promise;
    } catch (e) {
      // KL todo. The error messages are messed up. So we need all these cases.
      try {
        revertReason = e.reason.match(/reverted with reason string '([^']*)'/)?.[1] || e.reason;
        if (
          revertReason === "cannot estimate gas; transaction may fail or may require manual gas limit" ||
          revertReason === DEFAULT_REVERT_REASON
        ) {
          revertReason = e.error.toString().match(/revert with reason \"([^']*)\"/)[1] || "PLACEHOLDER_STRING";
        }
      } catch (_) {
        try {
          if (
            revertReason === "cannot estimate gas; transaction may fail or may require manual gas limit" ||
            revertReason === DEFAULT_REVERT_REASON
          ) {
            if (e.error) {
              revertReason =
                e.error.toString().match(/reverted with reason string '([^']*)'/)[1] || "PLACEHOLDER_STRING";
            } else {
              revertReason = e.toString().match(/reverted with reason string '([^']*)'/)[1] || "PLACEHOLDER_STRING";
            }
          }
        } catch (_) {
          throw e;
        }
      }
    }
  }
  return revertReason;
}

export async function executeUpgrade(
  deployer: Deployer,
  deployWallet: Wallet,
  targetAddress: string,
  value: BigNumberish,
  callData: string
) {
  const governance = GovernanceFactory.connect(deployer.addresses.Governance, deployWallet);
  const operation = {
    calls: [{ target: targetAddress, value: value, data: callData }],
    predecessor: ethers.constants.HashZero,
    salt: ethers.constants.HashZero,
  };
  await governance.scheduleTransparent(operation, 0);
  await governance.execute(operation);
  if (deployer.verbose) {
    console.log(
      "Upgrade with target ",
      targetAddress,
      "executed: ",
      await governance.isOperationDone(await governance.hashOperation(operation))
    );
  }
}

export async function requestExecute(
  chainId: ethers.BigNumberish,
  bridgehub: IBridgehub,
  to: Address,
  l2Value: ethers.BigNumber,
  calldata: ethers.BytesLike,
  l2GasLimit: ethers.BigNumber,
  factoryDeps: BytesLike[],
  refundRecipient: string,
  overrides?: ethers.PayableOverrides
) {
  overrides ??= {};
  overrides.gasPrice ??= bridgehub.provider.getGasPrice();
  // overrides.gasLimit ??= 30000000;
  if (!overrides.value) {
    const baseCost = await bridgehub.l2TransactionBaseCost(
      chainId,
      await overrides.gasPrice,
      l2GasLimit,
      REQUIRED_L2_GAS_PRICE_PER_PUBDATA
    );
    overrides.value = baseCost.add(l2Value);
  }

  return await bridgehub.requestL2Transaction(
    chainId,
    to,
    await overrides.value,
    l2Value,
    calldata,
    l2GasLimit,
    REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
    factoryDeps,
    refundRecipient,
    overrides
  );
}

// due to gas reasons we call tha chains's contract directly, instead of the bridgehub.
export async function requestExecuteDirect(
  mailbox: IMailbox,
  to: Address,
  l2Value: ethers.BigNumber,
  calldata: ethers.BytesLike,
  l2GasLimit: ethers.BigNumber,
  factoryDeps: BytesLike[],
  refundRecipient: string
) {
  const overrides = { gasPrice: 0 as BigNumberish, value: 0 as BigNumberish, gasLimit: 28000000 as BigNumberish };
  overrides.gasPrice = await mailbox.provider.getGasPrice();

  // we call bridgehubChain direcetly to avoid running out of gas.
  const baseCost = await mailbox.l2TransactionBaseCost(
    overrides.gasPrice,
    ethers.BigNumber.from(100000),
    REQUIRED_L2_GAS_PRICE_PER_PUBDATA
  );
  overrides.value = baseCost.add(ethers.BigNumber.from(0));

  return await mailbox.requestL2Transaction(
    to,
    l2Value,
    calldata,
    l2GasLimit,
    REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
    factoryDeps,
    refundRecipient,
    overrides
  );
}

export function constructL2Log(isService: boolean, sender: string, key: number | string, value: string) {
  return ethers.utils.hexConcat([
    isService ? "0x0001" : "0x0000",
    "0x0000",
    sender,
    ethers.utils.hexZeroPad(ethers.utils.hexlify(key), 32),
    ethers.utils.hexZeroPad(ethers.utils.hexlify(value), 32),
  ]);
}

export function createSystemLogs(
  chainedPriorityTxHashKey?: BytesLike,
  numberOfLayer1Txs?: BigNumberish,
  previousBatchHash?: BytesLike
) {
  return [
    constructL2Log(true, L2_TO_L1_MESSENGER, SYSTEM_LOG_KEYS.L2_TO_L1_LOGS_TREE_ROOT_KEY, ethers.constants.HashZero),
    constructL2Log(
      true,
      L2_TO_L1_MESSENGER,
      SYSTEM_LOG_KEYS.TOTAL_L2_TO_L1_PUBDATA_KEY,
      "0x290decd9548b62a8d60345a988386fc84ba6bc95484008f6362f93160ef3e563"
    ),
    constructL2Log(true, L2_TO_L1_MESSENGER, SYSTEM_LOG_KEYS.STATE_DIFF_HASH_KEY, ethers.constants.HashZero),
    constructL2Log(
      true,
      L2_SYSTEM_CONTEXT_ADDRESS,
      SYSTEM_LOG_KEYS.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY,
      ethers.constants.HashZero
    ),
    constructL2Log(
      true,
      L2_SYSTEM_CONTEXT_ADDRESS,
      SYSTEM_LOG_KEYS.PREV_BATCH_HASH_KEY,
      previousBatchHash ? ethers.utils.hexlify(previousBatchHash) : ethers.constants.HashZero
    ),
    constructL2Log(
      true,
      L2_BOOTLOADER_ADDRESS,
      SYSTEM_LOG_KEYS.CHAINED_PRIORITY_TXN_HASH_KEY,
      chainedPriorityTxHashKey ? chainedPriorityTxHashKey.toString() : EMPTY_STRING_KECCAK
    ),
    constructL2Log(
      true,
      L2_BOOTLOADER_ADDRESS,
      SYSTEM_LOG_KEYS.NUMBER_OF_LAYER_1_TXS_KEY,
      numberOfLayer1Txs ? numberOfLayer1Txs.toString() : ethers.constants.HashZero
    ),
  ];
}

export function createSystemLogsWithUpgrade(
  chainedPriorityTxHashKey?: BytesLike,
  numberOfLayer1Txs?: BigNumberish,
  upgradeTxHash?: string
) {
  return [
    constructL2Log(true, L2_TO_L1_MESSENGER, SYSTEM_LOG_KEYS.L2_TO_L1_LOGS_TREE_ROOT_KEY, ethers.constants.HashZero),
    constructL2Log(
      true,
      L2_TO_L1_MESSENGER,
      SYSTEM_LOG_KEYS.TOTAL_L2_TO_L1_PUBDATA_KEY,
      "0x290decd9548b62a8d60345a988386fc84ba6bc95484008f6362f93160ef3e563"
    ),
    constructL2Log(true, L2_TO_L1_MESSENGER, SYSTEM_LOG_KEYS.STATE_DIFF_HASH_KEY, ethers.constants.HashZero),
    constructL2Log(
      true,
      L2_SYSTEM_CONTEXT_ADDRESS,
      SYSTEM_LOG_KEYS.PACKED_BATCH_AND_L2_BLOCK_TIMESTAMP_KEY,
      ethers.constants.HashZero
    ),
    constructL2Log(true, L2_SYSTEM_CONTEXT_ADDRESS, SYSTEM_LOG_KEYS.PREV_BATCH_HASH_KEY, ethers.constants.HashZero),
    constructL2Log(
      true,
      L2_BOOTLOADER_ADDRESS,
      SYSTEM_LOG_KEYS.CHAINED_PRIORITY_TXN_HASH_KEY,
      chainedPriorityTxHashKey ? chainedPriorityTxHashKey.toString() : EMPTY_STRING_KECCAK
    ),
    constructL2Log(
      true,
      L2_BOOTLOADER_ADDRESS,
      SYSTEM_LOG_KEYS.NUMBER_OF_LAYER_1_TXS_KEY,
      numberOfLayer1Txs ? numberOfLayer1Txs.toString() : ethers.constants.HashZero
    ),
    constructL2Log(
      true,
      L2_BOOTLOADER_ADDRESS,
      SYSTEM_LOG_KEYS.EXPECTED_SYSTEM_CONTRACT_UPGRADE_TX_HASH_KEY,
      upgradeTxHash
    ),
  ];
}

export function genesisStoredBatchInfo(): StoredBatchInfo {
  return {
    batchNumber: 0,
    batchHash: ethers.constants.HashZero,
    indexRepeatedStorageChanges: 0,
    numberOfLayer1Txs: 0,
    priorityOperationsHash: EMPTY_STRING_KECCAK,
    l2LogsTreeRoot: DEFAULT_L2_LOGS_TREE_ROOT_HASH,
    timestamp: 0,
    commitment: ethers.constants.HashZero,
  };
}

// Packs the batch timestamp and L2 block timestamp and returns the 32-byte hex string
// which should be used for the "key" field of the L2->L1 system context log.
export function packBatchTimestampAndBatchTimestamp(
  batchTimestamp: BigNumberish,
  l2BlockTimestamp: BigNumberish
): string {
  const packedNum = BigNumber.from(batchTimestamp).shl(128).or(BigNumber.from(l2BlockTimestamp));
  return ethers.utils.hexZeroPad(ethers.utils.hexlify(packedNum), 32);
}

export async function initialDeployment(
  deployWallet: Wallet,
  ownerAddress: string,
  gasPrice: BigNumberish,
  extraFacets: FacetCut[]
): Promise<Deployer> {
  process.env.ETH_CLIENT_CHAIN_ID = (await deployWallet.getChainId()).toString();

  const deployer = new Deployer({
    deployWallet,
    ownerAddress,
    verbose: false,
    addresses: addressConfig,
    bootloaderBytecodeHash: L2_BOOTLOADER_BYTECODE_HASH,
    defaultAccountBytecodeHash: L2_DEFAULT_ACCOUNT_BYTECODE_HASH,
  });

  const create2Salt = ethers.utils.hexlify(ethers.utils.randomBytes(32));

  let nonce = await deployWallet.getTransactionCount();

  await deployTestnetTokens(testnetTokens, deployWallet, testnetTokenPath, deployer.verbose);

  nonce = await deployWallet.getTransactionCount();

  await deployer.deployCreate2Factory({ gasPrice, nonce });
  nonce++;

  // await deployer.deployMulticall3(create2Salt, {gasPrice, nonce});
  // nonce++;

  process.env.CONTRACTS_LATEST_PROTOCOL_VERSION = (20).toString();
  process.env.CONTRACTS_GENESIS_ROOT = zeroHash;
  process.env.CONTRACTS_GENESIS_ROLLUP_LEAF_INDEX = "0";
  process.env.CONTRACTS_GENESIS_BATCH_COMMITMENT = zeroHash;
  process.env.CONTRACTS_PRIORITY_TX_MAX_GAS_LIMIT = "72000000";
  process.env.CONTRACTS_RECURSION_NODE_LEVEL_VK_HASH = zeroHash;
  process.env.CONTRACTS_RECURSION_LEAF_LEVEL_VK_HASH = zeroHash;
  process.env.CONTRACTS_RECURSION_CIRCUITS_SET_VKS_HASH = zeroHash;

  await deployer.deployGenesisUpgrade(create2Salt, { gasPrice });
  await deployer.deployGovernance(create2Salt, { gasPrice });

  await deployer.deployTransparentProxyAdmin(create2Salt, { gasPrice });
  await deployer.deployBridgehubContract(create2Salt, gasPrice);
  await deployer.deployStateTransitionContract(create2Salt, extraFacets, gasPrice);
  await deployer.deployBridgeContracts(create2Salt, gasPrice);
  await initializeErc20Bridge(deployer, deployWallet, gasPrice, null);

  await deployer.deployWethBridgeContracts(create2Salt, gasPrice);
  await initializeWethBridge(deployer, deployWallet, gasPrice);
  await deployer.registerHyperchain(create2Salt, extraFacets, gasPrice);

  return deployer;
}

export interface StoredBatchInfo {
  batchNumber: BigNumberish;
  batchHash: BytesLike;
  indexRepeatedStorageChanges: BigNumberish;
  numberOfLayer1Txs: BigNumberish;
  priorityOperationsHash: BytesLike;
  l2LogsTreeRoot: BytesLike;
  timestamp: BigNumberish;
  commitment: BytesLike;
}

export interface CommitBatchInfo {
  batchNumber: BigNumberish;
  timestamp: number;
  indexRepeatedStorageChanges: BigNumberish;
  newStateRoot: BytesLike;
  numberOfLayer1Txs: BigNumberish;
  priorityOperationsHash: BytesLike;
  bootloaderHeapInitialContentsHash: BytesLike;
  eventsQueueStateHash: BytesLike;
  systemLogs: BytesLike;
  totalL2ToL1Pubdata: BytesLike;
}
