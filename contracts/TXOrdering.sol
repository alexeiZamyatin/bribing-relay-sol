pragma solidity >=0.4.22 <0.6.0;

import "openzeppelin-solidity/contracts/math/SafeMath.sol";
import 'openzeppelin-solidity/contracts/ownership/Ownable.sol';
import "./Utils.sol";

/// @notice Contract is Ownable - provides isOwner modifier and necessary constructor
contract TXOrdering is Ownable{
    
    using SafeMath for uint256;
    using Utils for bytes;


    struct HeaderInfo {
        uint256 blockHash; // height of this block header
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
    uint256 public constant BLOCK_REWARD = 12.5; // Bitcoin block reward    


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
        uint256 bribe) 
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
        _attackHeaders[blockHeight].blockHeight = blockHeight;
        _attackHeaders[blockHeight].chainWork = chainWork;

        _attackDuration = attackDuration;
        _attackHeight = blockHeight;
        _bribe = bribe;
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

    /*
    * TODO: remove unnecessary checks. Add checks for block and coinbase template!
    * 
    * @notice Parses, validates and stores Bitcoin block header to mapping
    * @param blockHeaderBytes Raw Bitcoin block header bytes (80 bytes) 
    * @param attackHeight Height of attack template list, for which this block is submitted
    * @param payoutAccount Account which should receive payouts for attack participation 
    */  
    function submitBlockHeader(bytes memory blockHeaderBytes, uint256 attackHeight, address payoutAccount) public returns (bytes32) {
        
        require(blockHeaderBytes.length == 80, ERR_INVALID_HEADER_SIZE);

        bytes32 hashPrevBlock = blockHeaderBytes.slice(4, 32).flipBytes().toBytes32();
        bytes32 hashCurrentBlock = dblShaFlip(blockHeaderBytes).toBytes32();

        // Fail if block already exists
        // Time is always set in block header struct (prevBlockHash and height can be 0 for Genesis block)
        require(_attackHeaders[attackHeight-1].blockHash.length <= 0, ERR_DUPLICATE_BLOCK);
        // Fail if previous block hash not in current state of main chain
        require(_attackHeaders[attackHeight-1].blockHash == hashPrevBlock, ERR_PREV_BLOCK);

        // Fails if previous block header is not stored
        uint256 chainWorkPrevBlock = _attackHeaders[attackHeight-1].chainWork;
        uint256 target = getTargetFromHeader(blockHeaderBytes);
        uint256 blockHeight = 1 + _attackHeaders[attackHeight-1].blockHeight;
        
        // Check the PoW solution matches the target specified in the block header
        require(hashCurrentBlock <= bytes32(target), ERR_LOW_DIFF);
        // Check the specified difficulty target is correct:
        // If retarget: according to Bitcoin's difficulty adjustment mechanism;
        // Else: same as last block. 
        require(correctDifficultyTarget(hashPrevBlock, blockHeight, target), ERR_DIFF_TARGET_HEADER);

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
        require(_totalFunding > (_exchangeRate * BLOCK_REWARD) + _bribe);
        _totalFunding -= (_exchangeRate * BLOCK_REWARD) + _bribe;
        _attackPayout[payoutAccount] += (_exchangeRate * BLOCK_REWARD) + _bribe;

        // DO WE NEED THIS? If we pay the first possible submission, we don't need to store the blocks, once we have validated them 
        // --> only store hash to save gas.
        storeBlockHeader(hashCurrentBlock, blockHeaderBytes, blockHeight, chainWork, payoutAccount);
    }

    /*
    * NOTE: MAYBE WE DON'T NEED TO STORE FULL BLOCK HEADERS - SAVES GAS!
    * @notice Stores parsed block header and meta information
    */
    function storeBlockHeader(bytes32 hashCurrentBlock, bytes memory blockHeaderBytes, uint256 blockHeight, uint256 chainWork, address payoutAccount) internal {
        // potentially externalize this call
        _attackHeaders[blockHeight].header = blockHeaderBytes;
        _attackHeaders[blockHeight].blockHeight = blockHeight;
        _attackHeaders[blockHeight].chainWork = chainWork;
        _attackHeaders[blockHeight].miner = payoutAccount;
    }

    // allows any attacker to claim funds for their account, if k confirmations have passed since their submitted block
    // SIMPLIFY: all attackers can claim payout k bitcoin blocks after attack payout
    function claimPayout(uint256 blockHeight) public {
        require(msg.sender == _attackHeaders[blockHeight].miner, "Message sender does not match payout address for this blockheight");
        
        // TODO: CHECK IF ATTACK SUCCESSFUL OR NOT!!
        _attackHeaders[blockHeight].miner.send((_exchangeRate * BLOCK_REWARD) + _bribe);
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
    function correctDifficultyTarget(bytes32 hashPrevBlock, uint256 blockHeight, uint256 target) private view returns(bool) {
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
    function computeMerkle(bytes32 txHash, uint256 txIndex, bytes memory merkleProof) internal view returns(bytes32) {
    
        //  Special case: only coinbase tx in block. Root == proof
        if(merkleProof.length == 32) return merkleProof.toBytes32();

        // Merkle proof length must be greater than 64 and power of 2. Case length == 32 covered above.
        require(merkleProof.length > 64 && (merkleProof.length & (merkleProof.length - 1)) == 0, ERR_MERKLE_PROOF);
        
        bytes32 resultHash = txHash;

        for(uint i = 1; i < merkleProof.length / 32; i++) {
            if(txIndex % 2 == 1){
                resultHash = concatSHA256Hash(merkleProof.slice(i * 32, 32), abi.encodePacked(resultHash));
            } else {
                resultHash = concatSHA256Hash(abi.encodePacked(resultHash), merkleProof.slice(i * 32, 32));
            }
            txIndex /= 2;
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
        return dblShaFlip(abi.encodePacked(left, right)).toBytes32();
    }

    /*
    * @notice Checks if given block hash has the requested number of confirmations
    * @dev: Will fail in txBlockHash is not in _attackHeaders
    * @param blockHeaderHash Block header hash to be verified
    * @param confirmations Requested number of confirmations
    */
    function withinXConfirms(uint256 blockHeight, uint256 confirmations) public view returns(bool){
        // TODO: check if attackHeader mapping actually has this blockHeight stored
        return _attackHeaders[_attackHeight].blockHeight - blockHeight >= confirmations;
    }

    // Parser functions
    function getTimeFromHeader(bytes memory blockHeaderBytes) public pure returns(uint32){
        return uint32(blockHeaderBytes.slice(68,4).flipBytes().bytesToUint()); 
    }

    function getMerkleRoot(bytes memory blockHeaderBytes) public pure returns(bytes32){
        return blockHeaderBytes.slice(36, 32).flipBytes().toBytes32();
    }

    function getPrevBlockHashFromHeader(bytes memory blockHeaderBytes) public pure returns(bytes32){
        return blockHeaderBytes.slice(4, 32).flipBytes().toBytes32();
    }

    function getMerkleRootFromHeader(bytes memory blockHeaderBytes) public pure returns(bytes32){
        return blockHeaderBytes.slice(36,32).toBytes32(); 
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


    // VIEWS
    function getBlockHeader(bytes32 blockHeaderHash) public view returns(
        uint32 version,
        uint32 time,
        uint32 nonce,
        bytes32 prevBlockHash,
        bytes32 merkleRoot,
        uint256 target
    ){
        bytes memory blockHeaderBytes = _attackHeaders[blockHeaderHash].header;
        version = uint32(blockHeaderBytes.slice(0,4).flipBytes().bytesToUint());
        time = uint32(blockHeaderBytes.slice(68,4).flipBytes().bytesToUint());
        nonce = uint32(blockHeaderBytes.slice(76, 4).flipBytes().bytesToUint());
        prevBlockHash = blockHeaderBytes.slice(4, 32).flipBytes().toBytes32();
        merkleRoot = blockHeaderBytes.slice(36,32).toBytes32();
        target = nBitsToTarget(blockHeaderBytes.slice(72, 4).flipBytes().bytesToUint());
        return(version, time, nonce, prevBlockHash, merkleRoot, target);
    }

    function getLatestForkHash(uint256 forkId) public view returns(bytes32){
        return _ongoingForks[forkId].forkHeaderHashes[_ongoingForks[forkId].forkHeaderHashes.length - 1]; 
    }

    // Returns the next block template for the attack
    // Miners must parse/verify locally
    function getNextBlockTemplate() public view returns (bytes memory) {
        return getBlockTemplateForHeight(_attackHeight);
    }
    // Returns the block template for a given attack height 
    // (assuming the attack template for this height has already been defined)
    function getBlockTemplateForHeight(uint256 blockHeight) public view returns (bytes memory) {
        // TODO: add check for existance of block height?
        return  _headerTemplates[_attackHeight];
    }

    // Returns the next block template for the attack
    // Miners must parse/verify locally
    function getNextCoinbaseTxTemplate() public view returns (bytes memory) {
        return getCoinbaseTxTemplateForHeight(_attackHeight);
    }

    // Returns the block template for a given attack height 
    // (assuming the attack template for this height has already been defined)
    function getCoinbaseTxTemplateForHeight(uint256 blockHeight) public view returns (bytes memory) {
        // TODO: add check for existance of block height?
        return  _coinbaseTxTemplates[_attackHeight];
    }

    // Returns the currently funded attack duration
    function getAttackDuration() public view returns (uint256) {
        return div(_totalFunding, _bribe + (BLOCK_REWARD * _exchangeRate));
    }
}