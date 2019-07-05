pragma solidity >=0.4.22 <0.6.0;

import "openzeppelin-solidity/contracts/math/SafeMath.sol";
import 'openzeppelin-solidity/contracts/ownership/Ownable.sol';
import "./Utils.sol";

/// @notice Contract is Ownable - provides isOwner modifier and necessary constructor
contract BribeRelay is Ownable{
    
    using SafeMath for uint256;
    using Utils for bytes;


    struct HeaderInfo {
        bytes32 blockHash; // height of this block header
        uint256 chainWork; // accumulated PoW at this height
        bytes header; // 80 bytes block header
        uint256 lastDiffAdjustment; // necessary to track, should a fork include a diff. adjustment block
        address miner; // miner payout account
    }

    // Attack configuration and tracking
    address public _owner; // owner of the contract = attacker
    mapping(uint256 => HeaderInfo) public _attackHeaders; // mapping of block headers submitted
    mapping(address => uint256) public _attackPayout; // attack payouts
    uint256 public _exchangeRate; // BTC-ETH exchange rate, necessary for computing payouts (fixed exchange rate for simplicity!)
    uint256 public _bribe; // bribe value
    uint256 public _totalFunding; // total funding currently in contract
    uint256 public _attackDuration; // target attack duration. Note: actual duration depends on available funding!

    // Templates - stored as bytes. Miners can parse locally. Optional: provide 'view' parsing functions in contract.
    mapping(uint256 => bytes) public _headerTemplates; // mapping of height to 80 bytes block template. Empty fields: nonce, merkle tree root(?)
    mapping(uint256 => bytes) public _coinbaseTxTemplates; // mapping of height to coinbase tx template

    // Main chain detection and PoW verification
    bytes32 public _heaviestBlock; // block with the highest chainWork, i.e., blockchain tip
    uint256 public _highScore; // highest chainWork, i.e., accumulated PoW at current blockchain tip    
    uint256 public _lastDiffAdjustmentTime; // timestamp of the block of last difficulty adjustment (blockHeight % 2016 == 0)
    uint256 public _attackHeight; // current block height of (heaviest) attack chain (For simplicity: assumption that only 1 attack fork will be submitted)
    

    // CONSTANTS
    /*
    * Bitcoin difficulty constants
    */ 
    uint256 public constant DIFFICULTY_ADJUSTMENT_INVETVAL = 2016;
    uint256 public constant TARGET_TIMESPAN = 14 * 24 * 60 * 60; // 2 weeks 
    uint256 public constant UNROUNDED_MAX_TARGET = 2**224 - 1; 
    uint256 public constant TARGET_TIMESPAN_DIV_4 = TARGET_TIMESPAN / 4; // store division as constant to save costs
    uint256 public constant TARGET_TIMESPAN_MUL_4 = TARGET_TIMESPAN * 4; // store multiplucation as constant to save costs
    uint256 public constant BLOCK_REWARD = 12; //.5; // Bitcoin block reward    


    // EXCEPTION MESSAGES
    string ERR_GENESIS_SET = "Initial parent has already been set";
    string ERR_INVALID_FORK_ID = "Incorrect fork identifier: id 0 is no available";
    string ERR_INVALID_HEADER_SIZE = "Invalid block header size";
    string ERR_DUPLICATE_BLOCK = "Block already stored";
    string ERR_PREV_BLOCK = "Previous block hash not found"; 
    string ERR_LOW_DIFF = "PoW hash does not meet difficulty target of header";
    string ERR_DIFF_TARGET_HEADER = "Incorrect difficulty target specified in block header";
    string ERR_NOT_MAIN_CHAIN = "Main chain submission indicated, but submitted block is on a fork";
    string ERR_FORK_PREV_BLOCK = "Previous block hash does not match last block in fork submission";
    string ERR_NOT_FORK = "Indicated fork submission, but block is in main chain";
    string ERR_INVALID_TXID = "Invalid transaction identifier";
    string ERR_CONFIRMS = "Transaction has less confirmations than requested"; 
    string ERR_MERKLE_PROOF = "Invalid Merkle Proof structure";
    
    /*
    * @notice Initialized BTCRelay with provided block, i.e., defined the first block of the stored chain. 
    * @dev TODO: check issue with "blockHeight mod 2016 = 2015" requirement (old btc relay!). Alexei: IMHO should be called with "blockHeight mod 2016 = 0"
    * @param blockHeaderBytes Raw Bitcoin block headers
    * @param blockHeight block blockHeight
    * @param chainWork total accumulated PoW at given block blockHeight/hash 
    * @param lastDiffAdjustmentTime timestamp of the block of the last diff. adjustment. Note: diff. target of that block MUST be equal to @param target 
    */
    function initialize(
        bytes memory blockHeaderBytes, 
        uint32 blockHeight, 
        uint256 chainWork,
        uint256 lastDiffAdjustmentTime,
        uint256 attackDuration,
        uint256 bribe,
        uint256 exchangeRate) 
        public 
        payable
        onlyOwner 
        {
        require(_heaviestBlock == 0, "Already initialized");
    
        bytes32 blockHeaderHash = dblShaFlip(blockHeaderBytes).toBytes32(); 
        _heaviestBlock = blockHeaderHash;
        _highScore = chainWork;
        _lastDiffAdjustmentTime = lastDiffAdjustmentTime;
        
        _attackHeaders[blockHeight].header = blockHeaderBytes;
        _attackHeaders[blockHeight].blockHash = blockHeaderHash;
        _attackHeaders[blockHeight].chainWork = chainWork;

        _attackDuration = attackDuration;
        _attackHeight = blockHeight;
        _bribe = bribe;
        _exchangeRate = exchangeRate;
    }

    function submitBlockTemplate(
        uint256 blockHeight, 
        bytes memory blockHeaderTemplate, 
        bytes memory coinbaseTxTemplate) 
        public 
        onlyOwner 
        {
            _headerTemplates[blockHeight] = blockHeaderTemplate;
            _coinbaseTxTemplates[blockHeight] = coinbaseTxTemplate;
    }

    // Pushes more funds to attack & updates totalFunding tracker
    function fundAttack() public payable {
        _totalFunding += msg.value; // TODO: double check if conversion neccessary here
    }

    // EVAL CASE: 
    // 1) Parse block and verify block header (not full format)
    // 2) Store block header
    function submitBlockHeader(bytes memory blockHeaderBytes, uint256 blockHeight, address payable payoutAccount, bool store) public returns (bytes32) {
        
        require(blockHeaderBytes.length == 80, ERR_INVALID_HEADER_SIZE);

        bytes32 hashPrevBlock = blockHeaderBytes.slice(4, 32).flipBytes().toBytes32();
        bytes32 hashCurrentBlock = dblShaFlip(blockHeaderBytes).toBytes32();

        // Fail if block already exists
        // Time is always set in block header struct (prevBlockHash and height can be 0 for Genesis block)
        require(_attackHeaders[blockHeight-1].lastDiffAdjustment <= 0, ERR_DUPLICATE_BLOCK);
        // Fail if previous block hash not in current state of main chain
        require(_attackHeaders[blockHeight-1].blockHash == hashPrevBlock, ERR_PREV_BLOCK);

        // Fails if previous block header is not stored
        uint256 chainWorkPrevBlock = _attackHeaders[blockHeight-1].chainWork;
        uint256 target = getTargetFromHeader(blockHeaderBytes);
        
        // Check the PoW solution matches the target specified in the block header
        require(hashCurrentBlock <= bytes32(target), ERR_LOW_DIFF);
        // Check the specified difficulty target is correct:
        // If retarget: according to Bitcoin's difficulty adjustment mechanism;
        // Else: same as last block. 
        require(correctDifficultyTarget(blockHeight, target), ERR_DIFF_TARGET_HEADER);

        // https://en.bitcoin.it/wiki/Difficulty
        // TODO: check correct conversion here
        uint256 difficulty = getDifficulty(target);
        uint256 chainWork = chainWorkPrevBlock + difficulty;

        // Fork handling DROPPED FOR SIMPLICITY
        // Main chain submission
        require(chainWork > _highScore, ERR_NOT_MAIN_CHAIN);
        _heaviestBlock = hashCurrentBlock;
        _highScore = chainWork;
        _attackHeight = blockHeight; // probably not necessary
        //require(_totalFunding > (_exchangeRate * BLOCK_REWARD) + _bribe);
        _totalFunding -= (_exchangeRate * BLOCK_REWARD) + _bribe;
        _attackPayout[payoutAccount] += (_exchangeRate * BLOCK_REWARD) + _bribe;

        // DO WE NEED THIS? If we pay the first possible submission, we don't need to store the blocks, once we have validated them 
        // --> only store hash to save gas.
        if(store){
            storeBlockHeader(hashCurrentBlock, blockHeaderBytes, blockHeight, chainWork, payoutAccount);
        }
    }

    
    // EVAL CASE 3) Verify transaction inclusion
    function evalVerifyTX(bytes32 txid, uint256 txBlockHeight, uint256 txIndex, bytes memory merkleProof, uint256 confirmations) public {
        verifxTX(txid, txBlockHeight, txIndex, merkleProof, confirmations);
    }

    function verifxTX(bytes32 txid, uint256 txBlockHeight, uint256 txIndex, bytes memory merkleProof, uint256 confirmations) public view returns(bool) {
        // txid must not be 0
        require(txid != bytes32(0x0), ERR_INVALID_TXID);
        
        // check requrested confirmations. No need to compute proof if insufficient confs.
        require(_attackHeight - txBlockHeight >= confirmations, ERR_CONFIRMS);

        bytes32 merkleRoot = getMerkleRoot(_attackHeaders[txBlockHeight].header);
        // Check merkle proof structure: 1st hash == txid and last hash == merkleRoot
        //require(merkleProof.slice(0, 32).toBytes32() == txid, "First Merkle tree hash not txid!");
        //require(merkleProof.slice(merkleRoot.length, 32).flipBytes().toBytes32() == merkleRoot, "Last Merkle tree hash not merkleRoot!");
        
        // compute merkle tree root and check if it matches block's original merkle tree root
        if(computeMerkle(txIndex, merkleProof) == merkleRoot){
            return true;
        }
        return false;
    }

    // EVAL CASE 4) Parse TX
    function parseTX(bytes memory txData) public {
        extractNumOutputs(txData);
        extractNumInputs(txData);

        // bytes memory input = extractInputAtIndex(txData, 0);
        bytes memory output = extractOutputAtIndex(txData, 1);

        extractOpReturnData(output);
    }


    /*
    * NOTE: MAYBE WE DON'T NEED TO STORE FULL BLOCK HEADERS - SAVES GAS!
    * @notice Stores parsed block header and meta information
    */
    function storeBlockHeader(bytes32 hashCurrentBlock, bytes memory blockHeaderBytes, uint256 blockHeight, uint256 chainWork, address payable payoutAccount) internal {
        // potentially externalize this call
        _attackHeaders[blockHeight].header = blockHeaderBytes;
        _attackHeaders[blockHeight].blockHash = hashCurrentBlock;
        _attackHeaders[blockHeight].chainWork = chainWork;
        _attackHeaders[blockHeight].miner = payoutAccount;
    }

    // HELPER FUNCTIONS

    /*
    * @notice Performns Bitcoin-like double sha256 (LE!)
    * @param data Bytes to be flipped and double hashed s
    * @return Reversed and double hashed representation of parsed data
    */
    function dblShaFlip(bytes memory data) public pure returns (bytes memory){
        return abi.encodePacked(sha256(abi.encodePacked(sha256(data)))).flipBytes();
    }

    function dblSha(bytes memory data) public pure returns (bytes memory){
        return abi.encodePacked(sha256(abi.encodePacked(sha256(data))));
    }

    /*
    * @notice Calculates the PoW difficulty target from compressed nBits representation, 
    * according to https://bitcoin.org/en/developer-reference#target-nbits
    * @param nBits Compressed PoW target representation
    * @return PoW difficulty target computed from nBits
    */
    function nBitsToTarget(uint256 nBits) private pure returns (uint256){
        uint256 exp = uint256(nBits) >> 24;
        uint256 c = uint256(nBits) & 0xffffff;
        uint256 target = uint256((c * 2**(8*(exp - 3))));
        return target;
    }

    /*
    * @notice Checks if the difficulty target should be adjusted at this block blockHeight
    * @param blockHeight block blockHeight to be checked
    * @return true, if block blockHeight is at difficulty adjustment interval, otherwise false
    */
    function difficultyShouldBeAdjusted(uint256 blockHeight) private pure returns (bool){
        return blockHeight % DIFFICULTY_ADJUSTMENT_INVETVAL == 0;
    }

    /*
    * @notice Verifies the currently submitted block header has the correct difficutly target, based on contract parameters
    * @dev Called from submitBlockHeader. TODO: think about emitting events in this function to identify the reason for failures
    * @param hashPrevBlock Previous block hash (necessary to retrieve previous target)
    */
    function correctDifficultyTarget(uint256 blockHeight, uint256 target) private view returns(bool) {
        bytes memory prevBlockHeader = _attackHeaders[blockHeight-1].header;
        uint256 prevTarget = getTargetFromHeader(prevBlockHeader);
        
        if(!difficultyShouldBeAdjusted(blockHeight)){
            // Difficulty not adjusted at this block blockHeight
            if(target != prevTarget && prevTarget != 0){
                return false;
            }
        } else {
            // Difficulty should be adjusted at this block blockHeight => check if adjusted correctly!
            uint256 prevTime = getTimeFromHeader(prevBlockHeader);
            uint256 startTime = _lastDiffAdjustmentTime;
            uint256 newTarget = computeNewTarget(prevTime, startTime, prevTarget);
            return target == newTarget;
        }
        return true;
    }

    /*
    * @notice Computes the new difficulty target based on the given parameters, 
    * according to: https://github.com/bitcoin/bitcoin/blob/78dae8caccd82cfbfd76557f1fb7d7557c7b5edb/src/pow.cpp 
    * @param prevTime timestamp of previous block 
    * @param startTime timestamp of last re-target
    * @param prevTarget PoW difficulty target of previous block
    */
    function computeNewTarget(uint256 prevTime, uint256 startTime, uint256 prevTarget) private pure returns(uint256){
        uint256 actualTimeSpan = prevTime - startTime;
        if(actualTimeSpan < TARGET_TIMESPAN_DIV_4){
            actualTimeSpan = TARGET_TIMESPAN_DIV_4;
        } 
        if(actualTimeSpan > TARGET_TIMESPAN_MUL_4){
            actualTimeSpan = TARGET_TIMESPAN_MUL_4;
        }

        uint256 newTarget = actualTimeSpan.mul(prevTarget).div(TARGET_TIMESPAN);
        if(newTarget > UNROUNDED_MAX_TARGET){
            newTarget = UNROUNDED_MAX_TARGET;
        }
        return newTarget;
    }   

    /*
    * @notice Reconstructs merkle tree root given a transaction hash, index in block and merkle tree path
    * @param txHash hash of to be verified transaction
    * @param txIndex index of transaction given by hash in the corresponding block's merkle tree 
    * @param merkleProof merkle tree path to transaction hash from block's merkle tree root
    * @return merkle tree root of the block containing the transaction, meaningless hash otherwise
    */
    function computeMerkle(uint256 txIndex, bytes memory merkleProof) internal view returns(bytes32) {
    
        //  Special case: only coinbase tx in block. Root == proof
        // if(merkleProof.length == 32) return merkleProof.toBytes32();

        // Merkle proof length must be greater than 64 and power of 2. Case length == 32 covered above.
        //require(merkleProof.length > 64 && (merkleProof.length & (merkleProof.length - 1)) == 0, ERR_MERKLE_PROOF);
        
        bytes32 resultHash;

        for(uint i = 1; i < 13; i++) {
            //if(txIndex % 2 == 1){
            //    resultHash = concatSHA256Hash(merkleProof.slice(i * 32, 32), abi.encodePacked(resultHash));
            //} else {
            resultHash = concatSHA256Hash(abi.encodePacked(resultHash), merkleProof.slice(32, 32));
            //dblShaFlip(merkleProof.slice(i * 32, 32));
            //dblShaFlip(merkleProof.slice(i * 32, 32));
            //}
           // txIndex /= 2;
        }
        return resultHash;
    }

    /*
    * @notice Concatenates and re-hashes two SHA256 hashes
    * @param left left side of the concatenation
    * @param right right side of the concatenation
    * @return sha256 hash of the concatenation of left and right
    */
    function concatSHA256Hash(bytes memory left, bytes memory right) public pure returns (bytes32) {
        return dblSha(abi.encodePacked(left, right)).toBytes32();
    }


    // Parser functions
    function getTimeFromHeader(bytes memory blockHeaderBytes) public pure returns(uint32){
        return uint32(blockHeaderBytes.slice(68,4).flipBytes().bytesToUint()); 
    }

    function getMerkleRoot(bytes memory blockHeaderBytes) public pure returns(bytes32){
        return blockHeaderBytes.slice(36, 32).flipBytes().toBytes32();
    }

    function getNBitsFromHeader(bytes memory blockHeaderBytes) public pure returns(uint256){
        return blockHeaderBytes.slice(72, 4).flipBytes().bytesToUint();
    }

    function getTargetFromHeader(bytes memory blockHeaderBytes) public pure returns(uint256){
        return nBitsToTarget(getNBitsFromHeader(blockHeaderBytes));
    }

    function getDifficulty(uint256 target) public pure returns(uint256){
        return 0x00000000FFFF0000000000000000000000000000000000000000000000000000 / target;
    }


    function extractOpReturnData(bytes memory _b) public pure returns (bytes memory) {
        require(_b.slice(9, 1).equal(hex"6a"), "Not an OP_RETURN output");
        bytes memory _dataLen = _b.slice(10, 1);
        return _b.slice(11, _dataLen.bytesToUint());
    }
    function extractNumInputs(bytes memory _b) public pure returns (uint8) {
        uint256 _n = extractNumInputsBytes(_b).bytesToUint();
        require(_n < 0xfd, "VarInts not supported");  // Error on VarInts
        return uint8(_n);
    }
    function extractNumOutputs(bytes memory _b) public pure returns (uint8) {
        uint256 _offset = findNumOutputs(_b);
        uint256 _n = _b.slice(_offset, 1).bytesToUint();
        require(_n < 0xfd, "VarInts not supported");  // Error on VarInts
        return uint8(_n);
    }
        function extractOutputAtIndex(bytes memory _b, uint8 _index) public pure returns (bytes memory) {

        // Some gas wasted here. This duplicates findNumOutputs
        require(_index < extractNumOutputs(_b), "Index more than number of outputs");

        // First output is the next byte after the number of outputs
        uint256 _offset = findNumOutputs(_b) + 1;

        // Determine length of first ouput
        uint _len = determineOutputLength(_b.slice(_offset + 8, 2));

        // This loop moves forward, and then gets the len of the next one
        for (uint i = 0; i < _index; i++) {
            _offset = _offset + _len;
            _len = determineOutputLength(_b.slice(_offset + 8, 2));
        }

        // We now have the length and offset of the one we want
        return _b.slice(_offset, _len);
    }
    function determineOutputLength(bytes memory _b) public pure returns (uint256) {

        // Keccak for equality because it doesn"t work otherwise.
        // Wasted an hour here

        // P2WSH
        if (keccak256(_b) == keccak256(hex"2200")) { return 43; }

        // P2WPKH
        if (keccak256(_b) == keccak256(hex"1600")) { return 31; }

        // Legacy P2PKH
        if (keccak256(_b) == keccak256(hex'1976')) { return 34; }

        // legacy P2SH
        if (keccak256(_b) == keccak256(hex'17a9')) { return 32; }

        // OP_RETURN
        if (keccak256(_b.slice(1, 1)) == keccak256(hex"6a")) {
            uint _pushLen = _b.slice(0, 1).bytesToUint();
            require(_pushLen < 76, "Multi-byte pushes not supported");
            // 8 byte value + 1 byte len + len bytes data
            return 9 + _pushLen;
        }

        // Error if we fall through the if statements
        require(false, "Unable to determine output length");
    }
    function findNumOutputs(bytes memory _b) public pure returns (uint256) {
        return 7 + (41 * extractNumInputs(_b));
    }
    function extractNumInputsBytes(bytes memory _b) public pure returns (bytes memory) {
        return _b.slice(6, 1);
    }

}