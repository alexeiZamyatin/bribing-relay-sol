const BribeRelay = artifacts.require("./BribeRelay.sol")
const Utils = artifacts.require("./Utils.sol")

const constants = require("./constants")
const helpers = require('./helpers');
const truffleAssert = require('truffle-assertions');
const BigNumber = require('big-number');

var eventFired = helpers.eventFired;
var dblSha256Flip = helpers.dblSha256Flip
var flipBytes = helpers.flipBytes

contract('BribeRelay Eval', async(accounts) => {



    const submitter = accounts[0];

    // gas limit
    const gas_limit = 800000000;

    const deploy = async function(){
        relay = await BribeRelay.new();
        utils = await Utils.deployed();
    }

    const storeGenesis = async function(){
        await relay.setInitialParent(
            constants.GENESIS.HEADER,
            constants.GENESIS.BLOCKHEIGHT,
            constants.GENESIS.CHAINWORK,
            constants.GENESIS.LAST_DIFFICULTY_ADJUSTMENT_TIME
            );
    }
    beforeEach('(re)deploy contracts', async function (){ 
        deploy()
    });
    
    it("set Genesis as initial parent ", async () => {   
        let submitHeaderTx = await relay.setInitialParent(
            constants.GENESIS.HEADER,
            constants.GENESIS.BLOCKHEIGHT,
            constants.GENESIS.CHAINWORK,
            constants.GENESIS.LAST_DIFFICULTY_ADJUSTMENT_TIME
            );
        // check if event was emmitted correctly
        truffleAssert.eventEmitted(submitHeaderTx, 'StoreHeader', (ev) => {
            return ev.blockHeight == 0;
        })

        //check header was stored correctly
        //TODO: check how to verify target - too large for toNumber() function 
        storedHeader = await relay.getBlockHeader.call(
            dblSha256Flip(constants.GENESIS.HEADER)
        )
        assert.equal(storedHeader.version.toNumber(), constants.GENESIS.HEADER_INFO.VERSION)
        assert.equal(storedHeader.time.toNumber(), constants.GENESIS.HEADER_INFO.TIME)
        assert.equal(storedHeader.nonce.toNumber(), constants.GENESIS.HEADER_INFO.NONCE)
        //assert.equal(new BigNumber(storedHeader.target), new BigNumber(constants.GENESIS.HEADER_INFO.TARGET))
        assert.equal(flipBytes(storedHeader.merkleRoot), constants.GENESIS.HEADER_INFO.MERKLE_ROOT)
        assert.equal(storedHeader.prevBlockHash, "0x0000000000000000000000000000000000000000000000000000000000000000")
    
        console.log("Gas used: " + submitHeaderTx.receipt.gasUsed)
    });
    

    it("EVAL CASE 1: verify block header ", async () => {   
        
        storeGenesis();
        let submitBlock1 = await relay.submitBlockHeader(
            constants.HEADERS.BLOCK_1, 
            "0xC5a96Db085dDA36FfBE390f455315D30D6D3DC52", // random address
            false
        );
        truffleAssert.eventEmitted(submitBlock1, 'StoreHeader', (ev) => {
            return ev.blockHeight == 1;
        });

        console.log("Total gas used: " + submitBlock1.receipt.gasUsed);
   });

   it("EVAL CASE 2: verify block AND store header ", async () => {   
        
    storeGenesis();
    let submitBlock1 = await relay.submitBlockHeader(
        constants.HEADERS.BLOCK_1, 
        "0xC5a96Db085dDA36FfBE390f455315D30D6D3DC52", // random address
        true
    );
    truffleAssert.eventEmitted(submitBlock1, 'StoreHeader', (ev) => {
        return ev.blockHeight == 1;
    });

    console.log("Total gas used: " + submitBlock1.receipt.gasUsed);
});

})