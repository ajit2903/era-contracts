////////////////////////////////////////////////////////////////
//                      CONSTANTS
////////////////////////////////////////////////////////////////

function ACCOUNT_CODE_STORAGE_SYSTEM_CONTRACT() -> addr {
    addr := 0x0000000000000000000000000000000000008002
}

function NONCE_HOLDER_SYSTEM_CONTRACT() -> addr {
    addr := 0x0000000000000000000000000000000000008003
}

function DEPLOYER_SYSTEM_CONTRACT() -> addr {
    addr :=  0x0000000000000000000000000000000000008006
}

function CODE_ORACLE_SYSTEM_CONTRACT() -> addr {
    addr := 0x0000000000000000000000000000000000008012
}

function EVM_GAS_MANAGER_CONTRACT() -> addr {   
    addr :=  0x0000000000000000000000000000000000008013
}

function LAST_RETURNDATA_SIZE_OFFSET() -> offset {
    offset := mul(32, 32)
}

function STACK_OFFSET() -> offset {
    offset := add(LAST_RETURNDATA_SIZE_OFFSET(), 64)
}

function BYTECODE_OFFSET() -> offset {
    offset := add(STACK_OFFSET(), mul(1024, 32))
}

function MAX_POSSIBLE_BYTECODE() -> max {
    max := 32000
}

function MEM_OFFSET() -> offset {
    offset := add(BYTECODE_OFFSET(), MAX_POSSIBLE_BYTECODE())
}

function MEM_OFFSET_INNER() -> offset {
    offset := add(MEM_OFFSET(), 32)
}

function MAX_POSSIBLE_MEM() -> max {
    max := 0x100000 // 1MB
}

function MAX_MEMORY_FRAME() -> max {
    max := add(MEM_OFFSET_INNER(), MAX_POSSIBLE_MEM())
}

function MAX_UINT() -> max_uint {
    max_uint := 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
}

function INF_PASS_GAS() -> inf {
    inf := 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
}

// Each evm gas is 5 zkEVM one
function GAS_DIVISOR() -> gas_div { gas_div := 5 }
function EVM_GAS_STIPEND() -> gas_stipend { gas_stipend := shl(30, 1) } // 1 << 30
function OVERHEAD() -> overhead { overhead := 2000 }

// From precompiles/CodeOracle
function DECOMMIT_COST_PER_WORD() -> cost { cost := 4 }

function UINT32_MAX() -> ret { ret := 4294967295 } // 2^32 - 1

////////////////////////////////////////////////////////////////
//                  GENERAL FUNCTIONS
////////////////////////////////////////////////////////////////

function $llvm_NoInline_llvm$_revert() {
    revert(0, 0)
}

function revertWithGas(evmGasLeft) {
    mstore(0, evmGasLeft)
    revert(0, 32)
}

function panic() {
    revert(0, 0)
}

function chargeGas(prevGas, toCharge) -> gasRemaining {
    if lt(prevGas, toCharge) {
        panic()
    }

    gasRemaining := sub(prevGas, toCharge)
}

function checkMemIsAccessible(index, offset) {
    checkOverflow(index, offset)

    if gt(add(index, offset), MAX_MEMORY_FRAME()) {
        panic()
    }
}

function checkMemOverflow(location) {
    if gt(location, MAX_MEMORY_FRAME()) {
        panic()
    }
}

function checkOverflow(data1, data2) {
    if lt(add(data1, data2), data2) {
        panic()
    }
}

// It is the responsibility of the caller to ensure that ip >= BYTECODE_OFFSET + 32
function readIP(ip,maxAcceptablePos) -> opcode {
    if gt(ip, maxAcceptablePos) {
        revert(0, 0)
    }

    opcode := and(mload(sub(ip, 31)), 0xff)
}

function readBytes(start, maxAcceptablePos,length) -> value {
    if gt(add(start,sub(length,1)), maxAcceptablePos) {
        revert(0, 0)
    }
    value := shr(mul(8,sub(32,length)),mload(start))
}

function getCodeAddress() -> addr {
    addr := verbatim_0i_1o("code_source")
}

function loadReturndataIntoActivePtr() {
    verbatim_0i_0o("return_data_ptr_to_active")
}

function loadCalldataIntoActivePtr() {
    verbatim_0i_0o("calldata_ptr_to_active")
}

function getActivePtrDataSize() -> size {
    size := verbatim_0i_1o("active_ptr_data_size")
}

function copyActivePtrData(_dest, _source, _size) {
    verbatim_3i_0o("active_ptr_data_copy", _dest, _source, _size)
}

function ptrAddIntoActive(_dest) {
    verbatim_1i_0o("active_ptr_add_assign", _dest)
}

function ptrShrinkIntoActive(_dest) {
    verbatim_1i_0o("active_ptr_shrink_assign", _dest)
}

function getIsStaticFromCallFlags() -> isStatic {
    isStatic := verbatim_0i_1o("get_global::call_flags")
    isStatic := iszero(iszero(and(isStatic, 0x04)))
}

function isAddrEmpty(addr) -> isEmpty {
    isEmpty := 0
    if iszero(extcodesize(addr)) { // YUL doesn't have short-circuit evaluation
        if iszero(balance(addr)) {
            if iszero(getRawNonce(addr)) {
                isEmpty := 1
            }
        }
    }
}

function getRawNonce(addr) -> nonce {
    mstore(0, 0x5AA9B6B500000000000000000000000000000000000000000000000000000000)
    mstore(4, addr)

    let result := staticcall(gas(), NONCE_HOLDER_SYSTEM_CONTRACT(), 0, 36, 0, 0)

    if iszero(result) {
        revert(0, 0)
    }

    returndatacopy(0, 0, 32)
    nonce := mload(0)
}

function _getRawCodeHash(account) -> hash {
    mstore(0, 0x4DE2E46800000000000000000000000000000000000000000000000000000000)
    mstore(4, account)

    let success := staticcall(gas(), ACCOUNT_CODE_STORAGE_SYSTEM_CONTRACT(), 0, 36, 0, 0)

    if iszero(success) {
        // This error should never happen
        revert(0, 0)
    }

    returndatacopy(0, 0, 32)
    hash := mload(0)
}

// Basically performs an extcodecopy, while returning the length of the bytecode.
function _fetchDeployedCode(addr, _offset, _len) -> codeLen {
    codeLen := _fetchDeployedCodeWithDest(addr, 0, _len, _offset)
}

// Basically performs an extcodecopy, while returning the length of the bytecode.
function _fetchDeployedCodeWithDest(addr, _offset, _len, dest) -> codeLen {
    let codeHash := _getRawCodeHash(addr)

    mstore(0, codeHash)

    let success := staticcall(gas(), CODE_ORACLE_SYSTEM_CONTRACT(), 0, 32, 0, 0)

    if iszero(success) {
        // This error should never happen
        revert(0, 0)
    }

    // The first word is the true length of the bytecode
    returndatacopy(0, 0, 32)
    codeLen := mload(0)

    if gt(_len, codeLen) {
        _len := codeLen
    }

    returndatacopy(dest, add(32,_offset), _len)
}

// Returns the length of the bytecode.
function _fetchDeployedCodeLen(addr) -> codeLen {
    let codeHash := _getRawCodeHash(addr)

    mstore(0, codeHash)

    let success := staticcall(gas(), CODE_ORACLE_SYSTEM_CONTRACT(), 0, 32, 0, 0)

    switch iszero(success)
    case 1 {
        // The code oracle call can only fail in the case where the contract
        // we are querying is the current one executing and it has not yet been
        // deployed, i.e., if someone calls codesize (or extcodesize(address()))
        // inside the constructor. In that case, code length is zero.
        codeLen := 0
    }
    default {
        // The first word is the true length of the bytecode
        returndatacopy(0, 0, 32)
        codeLen := mload(0)
    }
}

function getDeployedBytecode() {
    let codeLen := _fetchDeployedCode(
        getCodeAddress(),
        add(BYTECODE_OFFSET(), 32),
        MAX_POSSIBLE_BYTECODE()
    )

    mstore(BYTECODE_OFFSET(), codeLen)
}

function getMax(a, b) -> max {
    max := b
    if gt(a, b) {
        max := a
    }
}

function bitLength(n) -> bitLen {
    for { } gt(n, 0) { } { // while(n > 0)
        if iszero(n) {
            bitLen := 1
            break
        }
        n := shr(1, n)
        bitLen := add(bitLen, 1)
    }
}

function bitMaskFromBytes(nBytes) -> bitMask {
    bitMask := sub(exp(2, mul(nBytes, 8)), 1) // 2**(nBytes*8) - 1
}

// This function can overflow, it is the job of the caller to ensure that it does not.
// The argument to this function is the offset into the memory region IN BYTES.
function expandMemory(newSize) -> gasCost {
    let oldSizeInWords := mload(MEM_OFFSET())

    // The add 31 here before dividing is there to account for misaligned
    // memory expansions, where someone calls this with a newSize that is not
    // a multiple of 32. For instance, if someone calls it with an offset of 33,
    // the new size in words should be 2, not 1, but dividing by 32 will give 1.
    // Adding 31 solves it.
    let newSizeInWords := div(add(newSize, 31), 32)

    if gt(newSizeInWords, oldSizeInWords) {
        let new_minus_old := sub(newSizeInWords, oldSizeInWords)
        gasCost := add(mul(3,new_minus_old), div(mul(new_minus_old,add(newSizeInWords,oldSizeInWords)),512))

        mstore(MEM_OFFSET(), newSizeInWords)
    }
}

function performSystemCall(
    to,
    dataLength,
) -> ret {
    let farCallAbi := shl(248, 1) // system call
    // dataOffset is 0
    // dataStart is 0
    farCallAbi :=  or(farCallAbi, shl(96, dataLength))
    farCallAbi :=  or(farCallAbi, shl(192, gas())) // TODO overflow
    // shardId is 0
    // forwardingMode is 0
    // not constructor call

    let success := verbatim_6i_1o("system_call", to, farCallAbi, 0, 0, 0, 0)

    if iszero(success) {
        // This error should never happen
        revert(0, 0)
    }
}

function _isEVM(_addr) -> isEVM {
    // function isAccountEVM(address _addr) external view returns (bool);
    mstore(0, 0x8C04047700000000000000000000000000000000000000000000000000000000)
    mstore(4, _addr)

    let success := staticcall(gas(), ACCOUNT_CODE_STORAGE_SYSTEM_CONTRACT(), 0, 36, 0, 0)

    if iszero(success) {
        // This error should never happen
        revert(0, 0)
    }

    returndatacopy(0, 0, 32)
    isEVM := mload(0)
}

function zkVmGasToEvmGas(_zkevmGas) -> calczkevmGas {
    calczkevmGas := div(_zkevmGas, GAS_DIVISOR()) // TODO round up
}

function getEvmGasFromContext() -> evmGas {
    let _gas := gas()
    let requiredGas := add(EVM_GAS_STIPEND(), OVERHEAD()) // TODO CHECK GAS MECHANICS

    switch lt(_gas, requiredGas)
    case 1 {
        evmGas := 0
    }
    default {
        evmGas := div(sub(_gas, requiredGas), GAS_DIVISOR())
    }
}

////////////////////////////////////////////////////////////////
//                     STACK OPERATIONS
////////////////////////////////////////////////////////////////

function dupStackItem(sp, evmGas, position, oldStackHead) -> newSp, evmGasLeft, stackHead {
    evmGasLeft := chargeGas(evmGas, 3)
    let tempSp := sub(sp, mul(0x20, sub(position, 1)))

    if lt(tempSp, STACK_OFFSET())  {
        panic()
    }

    mstore(sp, oldStackHead)
    stackHead := mload(tempSp)
    newSp := add(sp, 0x20)
}

function swapStackItem(sp, evmGas, position, oldStackHead) ->  evmGasLeft, stackHead {
    evmGasLeft := chargeGas(evmGas, 3)
    let tempSp := sub(sp, mul(0x20, position))

    if lt(tempSp, STACK_OFFSET())  {
        panic()
    }

    stackHead := mload(tempSp)                    
    mstore(tempSp, oldStackHead)
}

function popStackItem(sp, oldStackHead) -> a, newSp, stackHead {
    // We can not return any error here, because it would break compatibility
    if lt(sp, STACK_OFFSET()) {
        panic()
    }

    a := oldStackHead
    newSp := sub(sp, 0x20)
    stackHead := mload(newSp)
}

function pushStackItem(sp, item, oldStackHead) -> newSp, stackHead {
    if iszero(lt(sp, BYTECODE_OFFSET())) {
        panic()
    }

    mstore(sp, oldStackHead)
    stackHead := item
    newSp := add(sp, 0x20)
}

function popStackItemWithoutCheck(sp, oldStackHead) -> a, newSp, stackHead {
    a := oldStackHead
    newSp := sub(sp, 0x20)
    stackHead := mload(newSp)
}

function pushStackItemWithoutCheck(sp, item, oldStackHead) -> newSp, stackHead {
    mstore(sp, oldStackHead)
    stackHead := item
    newSp := add(sp, 0x20)
}

function popStackCheck(sp, numInputs) {
    if lt(sub(sp, mul(0x20, sub(numInputs, 1))), STACK_OFFSET()) {
        panic()
    }
}

function pushStackCheck(sp, numInputs) {
    if iszero(lt(add(sp, mul(0x20, sub(numInputs, 1))), BYTECODE_OFFSET())) {
        panic()
    }
}

function accessStackHead(sp, stackHead) -> value {
    if lt(sp, STACK_OFFSET()) {
        panic()
    }

    value := stackHead
}

////////////////////////////////////////////////////////////////
//               EVM GAS MANAGER FUNCTIONALITY
////////////////////////////////////////////////////////////////

function $llvm_AlwaysInline_llvm$_warmAddress(addr) -> isWarm {
    // function warmAccount(address account)
    // non-standard selector 0x00
    // addr is packed in the same word with selector
    mstore(0, and(addr, 0xffffffffffffffffffffffffffffffffffffffff))

    performSystemCall(EVM_GAS_MANAGER_CONTRACT(), 32)

    if returndatasize() {
        isWarm := true
    }
}

function isSlotWarm(key) -> isWarm {
    // non-standard selector 0x01
    mstore(0, 0x0100000000000000000000000000000000000000000000000000000000000000)
    mstore(1, key)

    let success := call(gas(), EVM_GAS_MANAGER_CONTRACT(), 0, 0, 33, 0, 0)

    if iszero(success) {
        // This error should never happen
        revert(0, 0)
    }

    if returndatasize() {
        isWarm := true
    }
}

function warmSlot(key,currentValue) -> isWarm, originalValue {
    // non-standard selector 0x02
    mstore(0, 0x0200000000000000000000000000000000000000000000000000000000000000)
    mstore(1, key)
    mstore(33,currentValue)

    performSystemCall(EVM_GAS_MANAGER_CONTRACT(), 65)

    if returndatasize() {
        isWarm := true
        returndatacopy(0, 0, 32)
        originalValue := mload(0)
    }
}

function _pushEVMFrame(_passGas, _isStatic) {
    // function pushEVMFrame
    // non-standard selector 0x03
    mstore(0, or(0x0300000000000000000000000000000000000000000000000000000000000000, _isStatic))
    mstore(32, _passGas)

    performSystemCall(EVM_GAS_MANAGER_CONTRACT(), 64)
}

function consumeEvmFrame() -> passGas, isStatic, callerEVM {
    // function consumeEvmFrame() external returns (uint256 passGas, uint256 auxDataRes)
    // non-standard selector 0x04
    mstore(0, 0x0400000000000000000000000000000000000000000000000000000000000000)

    performSystemCall(EVM_GAS_MANAGER_CONTRACT(), 1)

    let _returndatasize := returndatasize()
    if _returndatasize {
        callerEVM := true

        returndatacopy(0, 0, 32)
        passGas := mload(0)
        
        isStatic := gt(_returndatasize, 32)
    }
}

////////////////////////////////////////////////////////////////
//               CALLS FUNCTIONALITY
////////////////////////////////////////////////////////////////

function performCall(oldSp, evmGasLeft, oldStackHead) -> newGasLeft, sp, stackHead {
    let gasToPass, addr, value, argsOffset, argsSize, retOffset, retSize

    popStackCheck(oldSp, 7)
    gasToPass, sp, stackHead := popStackItemWithoutCheck(oldSp, oldStackHead)
    addr, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
    value, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
    argsOffset, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
    argsSize, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
    retOffset, sp, retSize := popStackItemWithoutCheck(sp, stackHead)

    addr := and(addr, 0xffffffffffffffffffffffffffffffffffffffff)

    checkMemIsAccessible(argsOffset, argsSize)
    checkMemIsAccessible(retOffset, retSize)

    // static_gas = 0
    // dynamic_gas = memory_expansion_cost + code_execution_cost + address_access_cost + positive_value_cost + value_to_empty_account_cost
    // code_execution_cost is the cost of the called code execution (limited by the gas parameter).
    // If address is warm, then address_access_cost is 100, otherwise it is 2600. See section access sets.
    // If value is not 0, then positive_value_cost is 9000. In this case there is also a call stipend that is given to make sure that a basic fallback function can be called. 2300 is thus removed from the cost, and also added to the gas input.
    // If value is not 0 and the address given points to an empty account, then value_to_empty_account_cost is 25000. An account is empty if its balance is 0, its nonce is 0 and it has no code.

    let gasUsed := 100 // warm address access cost
    if iszero($llvm_AlwaysInline_llvm$_warmAddress(addr)) {
        gasUsed := 2600 // cold address access cost
    }

    if gt(value, 0) {
        gasUsed := add(gasUsed, 6700) // positive_value_cost - stipend
        gasToPass := add(gasToPass, 2300) // stipend TODO

        if isAddrEmpty(addr) {
            gasUsed := add(gasUsed, 25000) // value_to_empty_account_cost
        }
    }

    {
        let maxExpand := getMaxMemoryExpansionCost(retOffset, retSize, argsOffset, argsSize)
        gasUsed := add(gasUsed, maxExpand)
    }

    evmGasLeft := chargeGas(evmGasLeft, gasUsed)

    gasToPass := capGasForCall(evmGasLeft, gasToPass)

    let success, frameGasLeft := _performCall(
        addr,
        gasToPass,
        value,
        add(argsOffset, MEM_OFFSET_INNER()),
        argsSize,
        add(retOffset, MEM_OFFSET_INNER()),
        retSize
    )

    let gasUsed := 0

    // TODO precompile should be called, but return nothing if gasPassed is too low
    let precompileCost := getGasForPrecompiles(addr, argsOffset, argsSize)
    switch iszero(precompileCost)
    case 1 {
        gasUsed := sub(gasToPass, frameGasLeft)
    }
    default {
        gasUsed := precompileCost
    }

    newGasLeft := chargeGas(evmGasLeft, gasUsed)
    stackHead := success
}

function performStaticCall(oldSp, evmGasLeft, oldStackHead) -> newGasLeft, sp, stackHead {
    let gasToPass,addr, argsOffset, argsSize, retOffset, retSize

    popStackCheck(oldSp, 6)
    gasToPass, sp, stackHead := popStackItemWithoutCheck(oldSp, oldStackHead)
    addr, sp, stackHead  := popStackItemWithoutCheck(sp, stackHead)
    argsOffset, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
    argsSize, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
    retOffset, sp, retSize := popStackItemWithoutCheck(sp, stackHead)

    addr := and(addr, 0xffffffffffffffffffffffffffffffffffffffff)

    checkMemIsAccessible(argsOffset, argsSize)
    checkMemIsAccessible(retOffset, retSize)

    let gasUsed := 100
    if iszero($llvm_AlwaysInline_llvm$_warmAddress(addr)) {
        gasUsed := 2600
    }

    {
        let maxExpand := getMaxMemoryExpansionCost(retOffset, retSize, argsOffset, argsSize)
        gasUsed := add(gasUsed, maxExpand)
    }

    evmGasLeft := chargeGas(evmGasLeft, gasUsed)

    gasToPass := capGasForCall(evmGasLeft, gasToPass)

    let success, frameGasLeft := _performStaticCall(
        addr,
        gasToPass,
        add(MEM_OFFSET_INNER(), argsOffset),
        argsSize,
        add(MEM_OFFSET_INNER(), retOffset),
        retSize
    )

    let gasUsed := 0

    let precompileCost := getGasForPrecompiles(addr, argsOffset, argsSize)
    switch iszero(precompileCost)
    case 1 {
        gasUsed := sub(gasToPass, frameGasLeft)
    }
    default {
        gasUsed := precompileCost
    }

    newGasLeft := chargeGas(evmGasLeft, gasUsed)

    stackHead := success
}


function performDelegateCall(oldSp, evmGasLeft, isStatic, oldStackHead) -> newEvmGasLeft, sp, stackHead {
    let addr, gasToPass, argsOffset, argsSize, retOffset, retSize

    popStackCheck(oldSp, 6)
    gasToPass, sp, stackHead := popStackItemWithoutCheck(oldSp, oldStackHead)
    addr, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
    argsOffset, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
    argsSize, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
    retOffset, sp, retSize := popStackItemWithoutCheck(sp, stackHead)

    addr := and(addr, 0xffffffffffffffffffffffffffffffffffffffff)

    checkMemIsAccessible(argsOffset, argsSize)
    checkMemIsAccessible(retOffset, retSize)

    let gasUsed := 100
    if iszero($llvm_AlwaysInline_llvm$_warmAddress(addr)) {
        gasUsed := 2600
    }

    {
        let maxExpand := getMaxMemoryExpansionCost(retOffset, retSize, argsOffset, argsSize)
        gasUsed := add(gasUsed, maxExpand)
    }

    evmGasLeft := chargeGas(evmGasLeft, gasUsed)

    if iszero(_isEVM(addr)) {
        revertWithGas(evmGasLeft)
    }

    gasToPass := capGasForCall(evmGasLeft, gasToPass)

    _pushEVMFrame(gasToPass, isStatic)
    let success := delegatecall(
        // We can not just pass all gas here to prevent overflow of zkEVM gas counter
        EVM_GAS_STIPEND(),
        addr,
        add(MEM_OFFSET_INNER(), argsOffset),
        argsSize,
        0,
        0
    )

    let frameGasLeft := _saveReturndataAfterEVMCall(add(MEM_OFFSET_INNER(), retOffset), retSize)
    let gasUsed := sub(gasToPass, frameGasLeft)

    newEvmGasLeft := chargeGas(evmGasLeft, gasUsed)

    stackHead := success
}

function _performCall(addr, gasToPass, value, argsOffset, argsSize, retOffset, retSize) -> success, frameGasLeft {
    switch _isEVM(addr)
    case 0 {
        // zkEVM native
        let zkEvmGasToPass := _getZkEVMGasForCall(gasToPass, addr)
        let zkEvmGasBefore := gas()
        success := call(zkEvmGasToPass, addr, value, argsOffset, argsSize, retOffset, retSize)
        _saveReturndataAfterZkEVMCall()
        let gasUsed := zkVmGasToEvmGas(sub(zkEvmGasBefore, gas()))

        if gt(gasToPass, gasUsed) {
            frameGasLeft := sub(gasToPass, gasUsed) // TODO check
        }
    }
    default {
        _pushEVMFrame(gasToPass, false)
        success := call(EVM_GAS_STIPEND(), addr, value, argsOffset, argsSize, 0, 0)
        frameGasLeft := _saveReturndataAfterEVMCall(retOffset, retSize)
    }
}

function _performStaticCall(addr, gasToPass, argsOffset, argsSize, retOffset, retSize) -> success, frameGasLeft {
    switch _isEVM(addr)
    case 0 {
        // zkEVM native
        let zkEvmGasToPass := _getZkEVMGasForCall(gasToPass, addr)
        let zkEvmGasBefore := gas()
        success := staticcall(zkEvmGasToPass, addr, argsOffset, argsSize, 0, 0)
        _saveReturndataAfterZkEVMCall()
        let gasUsed := zkVmGasToEvmGas(sub(zkEvmGasBefore, gas()))

        if gt(gasToPass, gasUsed) {
            frameGasLeft := sub(gasToPass, gasUsed) // TODO check
        }
    }
    default {
        _pushEVMFrame(gasToPass, true)
        success := staticcall(EVM_GAS_STIPEND(), addr, argsOffset, argsSize, 0, 0)
        frameGasLeft := _saveReturndataAfterEVMCall(retOffset, retSize)
    }
}

function _getZkEVMGasForCall(_evmGas, addr) -> zkevmGas {
    // TODO CHECK COSTS CALCULATION
    zkevmGas := mul(_evmGas, GAS_DIVISOR())
    let byteSize := extcodesize(addr)
    let should_ceil := mod(byteSize, 32)
    if gt(should_ceil, 0) {
        byteSize := add(byteSize, sub(32, should_ceil))
    }
    let decommitGasCost := mul(div(byteSize,32), DECOMMIT_COST_PER_WORD())
    zkevmGas := sub(zkevmGas, decommitGasCost)
    if gt(zkevmGas, UINT32_MAX()) {
        zkevmGas := UINT32_MAX()
    }
}

function capGasForCall(evmGasLeft,oldGasToPass) -> gasToPass {
    let maxGasToPass := sub(evmGasLeft, shr(6, evmGasLeft)) // evmGasLeft >> 6 == evmGasLeft/64
    gasToPass := oldGasToPass
    if gt(oldGasToPass, maxGasToPass) { 
        gasToPass := maxGasToPass
    }
}

function getMaxMemoryExpansionCost(retOffset, retSize, argsOffset, argsSize) -> maxExpand {
    maxExpand := add(retOffset, retSize)
    switch lt(maxExpand, add(argsOffset, argsSize)) 
    case 0 {
        maxExpand := expandMemory(maxExpand)
    }
    default {
        maxExpand := expandMemory(add(argsOffset, argsSize))
    }
}

// The gas cost mentioned here is purely the cost of the contract, 
// and does not consider the cost of the call itself nor the instructions 
// to put the parameters in memory. 
// Take into account MEM_OFFSET_INNER() when passing the argsOffset
function getGasForPrecompiles(addr, argsOffset, argsSize) -> gasToCharge {
    switch addr
        case 0x01 { // ecRecover
            gasToCharge := 3000
        }
        case 0x02 { // SHA2-256
            gasToCharge := 60
            let dataWordSize := shr(5, add(argsSize, 31)) // (argsSize+31)/32
            gasToCharge := add(gasToCharge, mul(12, dataWordSize))
        }
        case 0x03 { // RIPEMD-160
            gasToCharge := 600
            let dataWordSize := shr(5, add(argsSize, 31)) // (argsSize+31)/32
            gasToCharge := add(gasToCharge, mul(120, dataWordSize))
        }
        case 0x04 { // identity
            gasToCharge := 15
            let dataWordSize := shr(5, add(argsSize, 31)) // (argsSize+31)/32
            gasToCharge := add(gasToCharge, mul(3, dataWordSize))
        }
        // [0; 31] (32 bytes)	Bsize	Byte size of B
        // [32; 63] (32 bytes)	Esize	Byte size of E
        // [64; 95] (32 bytes)	Msize	Byte size of M
        /*       
        def calculate_iteration_count(exponent_length, exponent):
            iteration_count = 0
            if exponent_length <= 32 and exponent == 0: iteration_count = 0
            elif exponent_length <= 32: iteration_count = exponent.bit_length() - 1
            elif exponent_length > 32: iteration_count = (8 * (exponent_length - 32)) + ((exponent & (2**256 - 1)).bit_length() - 1)
            return max(iteration_count, 1)
        def calculate_gas_cost(base_length, modulus_length, exponent_length, exponent):
            multiplication_complexity = calculate_multiplication_complexity(base_length, modulus_length)
            iteration_count = calculate_iteration_count(exponent_length, exponent)
            return max(200, math.floor(multiplication_complexity * iteration_count / 3))
        */
        // modexp gas cost EIP below
        // https://eips.ethereum.org/EIPS/eip-2565
        case 0x05 { // modexp
            let mulComplex
            let Bsize := mload(argsOffset)
            let Esize := mload(add(argsOffset, 0x20))

            {
                let words := getMax(Bsize, mload(add(argsOffset, 0x40))) // shr(3, x) == x/8
                if and(lt(words, 64), eq(words, 64)){
                    // if x <= 64: return x ** 2
                    mulComplex := mul(words, words)
                }
                if and(and(lt(words, 1024), eq(words, 1024)), gt(words, 64)){
                    // elif x <= 1024: return x ** 2 // 4 + 96 * x - 3072
                    mulComplex := sub(add(shr(2, mul(words, words)), mul(96, words)), 3072)
                }
                if gt(words, 64) {
                    //  else: return x ** 2 // 16 + 480 * x - 199680
                    mulComplex := sub(add(shr(4, mul(words, words)), mul(480, words)), 199680)
                }
            }

            // [96 + Bsize; 96 + Bsize + Esize]	E
            let exponentFirst256, exponentIsZero, exponentBitLen
            if or(lt(Esize, 32), eq(Esize, 32)) {
                // Maybe there isn't exactly 32 bytes, so a mask should be applied
                exponentFirst256 := mload(add(add(argsOffset, 0x60), Bsize))
                exponentBitLen := bitLength(exponentFirst256)
                exponentIsZero := iszero(and(exponentFirst256, bitMaskFromBytes(Esize)))
            }
            if gt(Esize, 32) {
                exponentFirst256 := mload(add(add(argsOffset, 0x60), Bsize))
                exponentIsZero := iszero(exponentFirst256)
                let exponentNext
                // This is done because the first 32bytes of the exponent were loaded
                for { let i := 0 } lt(i,  div(Esize, 32)) { i := add(i, 1) Esize := sub(Esize, 32)  } { // check every 32bytes
                    // Maybe there isn't exactly 32 bytes, so a mask should be applied
                    exponentNext := mload(add(add(add(argsOffset, 0x60), Bsize), add(mul(i, 32), 32)))
                    exponentBitLen := add(bitLength(exponentNext), mul(mul(32, 8), add(i, 1)))
                    if iszero(iszero(and(exponentNext, bitMaskFromBytes(Esize)))) {
                        exponentIsZero := false
                    }
                }
            }

            // if exponent_length <= 32 and exponent == 0: iteration_count = 0
            // return max(iteration_count, 1)
            let iterationCount := 1
            // elif exponent_length <= 32: iteration_count = exponent.bit_length() - 1
            if and(lt(Esize, 32), iszero(exponentIsZero)) {
                iterationCount := sub(exponentBitLen, 1)
            }
            // elif exponent_length > 32: iteration_count = (8 * (exponent_length - 32)) + ((exponent & (2**256 - 1)).bit_length() - 1)
            if gt(Esize, 32) {
                iterationCount := add(mul(8, sub(Esize, 32)), sub(bitLength(and(exponentFirst256, MAX_UINT())), 1))
            }

            gasToCharge := getMax(200, div(mul(mulComplex, iterationCount), 3))
        }
        // ecAdd ecMul ecPairing EIP below
        // https://eips.ethereum.org/EIPS/eip-1108
        case 0x06 { // ecAdd
            // The gas cost is fixed at 150. However, if the input
            // does not allow to compute a valid result, all the gas sent is consumed.
            gasToCharge := 150
        }
        case 0x07 { // ecMul
            // The gas cost is fixed at 6000. However, if the input
            // does not allow to compute a valid result, all the gas sent is consumed.
            gasToCharge := 6000
        }
        // 35,000 * k + 45,000 gas, where k is the number of pairings being computed.
        // The input must always be a multiple of 6 32-byte values.
        case 0x08 { // ecPairing
            gasToCharge := 45000
            let k := div(argsSize, 0xC0) // 0xC0 == 6*32
            gasToCharge := add(gasToCharge, mul(k, 35000))
        }
        case 0x09 { // blake2f
            // argsOffset[0; 3] (4 bytes) Number of rounds (big-endian uint)
            gasToCharge := and(mload(argsOffset), 0xFFFFFFFF) // last 4bytes
        }
        default {
            gasToCharge := 0
        }
}

function _saveReturndataAfterZkEVMCall() {
    loadReturndataIntoActivePtr()
    let lastRtSzOffset := LAST_RETURNDATA_SIZE_OFFSET()

    mstore(lastRtSzOffset, returndatasize())
}

function _saveReturndataAfterEVMCall(_outputOffset, _outputLen) -> _gasLeft {
    let lastRtSzOffset := LAST_RETURNDATA_SIZE_OFFSET()
    let rtsz := returndatasize()

    loadReturndataIntoActivePtr()

    // if (rtsz > 31)
    switch gt(rtsz, 31)
        case 0 {
            // Unexpected return data.
            _gasLeft := 0
            _eraseReturndataPointer()
        }
        default {
            returndatacopy(0, 0, 32)
            _gasLeft := mload(0)

            // We copy as much returndata as possible without going over the 
            // returndata size.
            switch lt(sub(rtsz, 32), _outputLen)
                case 0 { returndatacopy(_outputOffset, 32, _outputLen) }
                default { returndatacopy(_outputOffset, 32, sub(rtsz, 32)) }

            mstore(lastRtSzOffset, sub(rtsz, 32))

            // Skip the returnData
            ptrAddIntoActive(32)
        }
}

function _eraseReturndataPointer() {
    let lastRtSzOffset := LAST_RETURNDATA_SIZE_OFFSET()

    let activePtrSize := getActivePtrDataSize()
    ptrShrinkIntoActive(and(activePtrSize, 0xFFFFFFFF))// uint32(activePtrSize)
    mstore(lastRtSzOffset, 0)
}

////////////////////////////////////////////////////////////////
//                 CREATE FUNCTIONALITY
////////////////////////////////////////////////////////////////

function _fetchConstructorReturnGas() -> gasLeft {
    mstore(0, 0x24E5AB4A00000000000000000000000000000000000000000000000000000000)

    let success := staticcall(gas(), DEPLOYER_SYSTEM_CONTRACT(), 0, 4, 0, 0)

    if iszero(success) {
        // This error should never happen
        revert(0, 0)
    }

    returndatacopy(0, 0, 32)
    gasLeft := mload(0)
}

function $llvm_NoInline_llvm$_genericCreate(offset, size, sp, value, evmGasLeftOld, isCreate2, salt, oldStackHead) -> result, evmGasLeft, addr, stackHead  {
    _eraseReturndataPointer()

    let gasForTheCall := capGasForCall(evmGasLeftOld, INF_PASS_GAS())

    if lt(selfbalance(), value) { // TODO optimize
        revertWithGas(evmGasLeftOld)
    }

    offset := add(MEM_OFFSET_INNER(), offset) // TODO gas check

    pushStackCheck(sp, 4)
    sp, stackHead := pushStackItemWithoutCheck(sp, mload(sub(offset, 0x80)), oldStackHead)
    sp, stackHead := pushStackItemWithoutCheck(sp, mload(sub(offset, 0x60)), stackHead)
    sp, stackHead := pushStackItemWithoutCheck(sp, mload(sub(offset, 0x40)), stackHead)
    sp, stackHead := pushStackItemWithoutCheck(sp, mload(sub(offset, 0x20)), stackHead)

    _pushEVMFrame(gasForTheCall, false)

    if isCreate2 {
        // Create2EVM selector
        mstore(sub(offset, 0x80), 0x4e96f4c0)
        // salt
        mstore(sub(offset, 0x60), salt)
        // Where the arg starts (third word)
        mstore(sub(offset, 0x40), 0x40)
        // Length of the init code
        mstore(sub(offset, 0x20), size)


        result := call(gas(), DEPLOYER_SYSTEM_CONTRACT(), value, sub(offset, 0x64), add(size, 0x64), 0, 32)
    }


    if iszero(isCreate2) {
        // CreateEVM selector
        mstore(sub(offset, 0x60), 0xff311601)
        // Where the arg starts (second word)
        mstore(sub(offset, 0x40), 0x20)
        // Length of the init code
        mstore(sub(offset, 0x20), size)


        result := call(gas(), DEPLOYER_SYSTEM_CONTRACT(), value, sub(offset, 0x44), add(size, 0x44), 0, 32)
    }

    addr := mload(0)

    let gasLeft
    switch result
        case 0 {
            gasLeft := _saveReturndataAfterEVMCall(0, 0)
        }
        default {
            gasLeft := _fetchConstructorReturnGas()
        }

    let gasUsed := sub(gasForTheCall, gasLeft)
    evmGasLeft := chargeGas(evmGasLeftOld, gasUsed)

    let back

    // skipping check since we pushed exactly 4 items earlier
    back, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
    mstore(sub(offset, 0x20), back)
    back, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
    mstore(sub(offset, 0x40), back)
    back, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
    mstore(sub(offset, 0x60), back)
    back, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
    mstore(sub(offset, 0x80), back)
}

function performCreate(evmGas,oldSp,isStatic, oldStackHead) -> evmGasLeft, sp, stackHead {
    evmGasLeft := chargeGas(evmGas, 32000)

    if isStatic {
        panic()
    }

    let value, offset, size

    popStackCheck(oldSp, 3)
    value, sp, stackHead := popStackItemWithoutCheck(oldSp, oldStackHead)
    offset, sp, size := popStackItemWithoutCheck(sp, stackHead)

    checkMemIsAccessible(offset, size)

    if gt(size, mul(2, MAX_POSSIBLE_BYTECODE())) {
        revertWithGas(evmGasLeft) // TODO check
    }

    if gt(value, balance(address())) {
        revertWithGas(evmGasLeft)
    }

    // dynamicGas = init_code_cost + memory_expansion_cost + deployment_code_execution_cost + code_deposit_cost
    // minimum_word_size = (size + 31) / 32
    // init_code_cost = 2 * minimum_word_size
    // code_deposit_cost = 200 * deployed_code_size
    let dynamicGas := add(
        shr(4, add(size, 31)),
        expandMemory(add(offset, size))
    )
    evmGasLeft := chargeGas(evmGasLeft, dynamicGas)

    let result, addr
    result, evmGasLeft, addr, stackHead := $llvm_NoInline_llvm$_genericCreate(offset, size, sp, value, evmGasLeft, false, 0, stackHead)

    switch result
        case 0 { stackHead := 0 }
        default { stackHead := addr }
}

function performCreate2(evmGas, oldSp, isStatic, oldStackHead) -> evmGasLeft, sp, result, addr, stackHead {
    evmGasLeft := chargeGas(evmGas, 32000)

    if isStatic {
        panic()
    }

    let value, offset, size, salt

    popStackCheck(oldSp, 4)
    value, sp, stackHead := popStackItemWithoutCheck(oldSp, oldStackHead)
    offset, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
    size, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)
    salt, sp, stackHead := popStackItemWithoutCheck(sp, stackHead)

    checkMemIsAccessible(offset, size)

    if gt(size, mul(2, MAX_POSSIBLE_BYTECODE())) {
        revertWithGas(evmGasLeft)
    }

    if gt(value, balance(address())) {
        revertWithGas(evmGasLeft)
    }

    // dynamicGas = init_code_cost + hash_cost + memory_expansion_cost + deployment_code_execution_cost + code_deposit_cost
    // minimum_word_size = (size + 31) / 32
    // init_code_cost = 2 * minimum_word_size
    // hash_cost = 6 * minimum_word_size
    // code_deposit_cost = 200 * deployed_code_size
    evmGasLeft := chargeGas(evmGasLeft, add(
        expandMemory(add(offset, size)),
        shr(2, add(size, 31))
    ))

    result, evmGasLeft, addr, stackHead := $llvm_NoInline_llvm$_genericCreate(offset, size, sp, value, evmGasLeft,true,salt, stackHead)
}

////////////////////////////////////////////////////////////////
//               EXTCODECOPY FUNCTIONALITY
////////////////////////////////////////////////////////////////

function $llvm_AlwaysInline_llvm$_copyRest(dest, val, len) {
    let rest_bits := shl(3, len)
    let upper_bits := sub(256, rest_bits)
    let val_mask := shl(upper_bits, MAX_UINT())
    let val_masked := and(val, val_mask)
    let dst_val := mload(dest)
    let dst_mask := shr(rest_bits, MAX_UINT())
    let dst_masked := and(dst_val, dst_mask)
    mstore(dest, or(val_masked, dst_masked))
}

function $llvm_AlwaysInline_llvm$_memcpy(dest, src, len) {
    let dest_addr := dest
    let src_addr := src
    let dest_end := add(dest, and(len, sub(0, 32)))
    for { } lt(dest_addr, dest_end) {} {
        mstore(dest_addr, mload(src_addr))
        dest_addr := add(dest_addr, 32)
        src_addr := add(src_addr, 32)
    }

    let rest_len := and(len, 31)
    if rest_len {
        $llvm_AlwaysInline_llvm$_copyRest(dest_addr, mload(src_addr), rest_len)
    }
}

function $llvm_AlwaysInline_llvm$_memsetToZero(dest,len) {
    let dest_end := add(dest, and(len, sub(0, 32)))
    for {let i := dest} lt(i, dest_end) { i := add(i, 32) } {
        mstore(i, 0)
    }

    let rest_len := and(len, 31)
    if rest_len {
        $llvm_AlwaysInline_llvm$_copyRest(dest_end, 0, rest_len)
    }
}