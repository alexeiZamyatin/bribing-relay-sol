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



    const storeGenesis = async function(){
        await relay.initialize(
            constants.GENESIS.HEADER,
            constants.GENESIS.BLOCKHEIGHT,
            constants.GENESIS.CHAINWORK,
            constants.GENESIS.LAST_DIFFICULTY_ADJUSTMENT_TIME,
            10,
            100,
            1
            );
    }

    beforeEach('(re)deploy contracts', async function (){ 
        relay = await BribeRelay.new();
        utils = await Utils.deployed();
    });
    
    it("set Genesis as initial parent ", async () => {   
        let submitHeaderTx = await relay.initialize(
            constants.GENESIS.HEADER,
            constants.GENESIS.BLOCKHEIGHT,
            constants.GENESIS.CHAINWORK,
            constants.GENESIS.LAST_DIFFICULTY_ADJUSTMENT_TIME,
            10,
            100,
            1
            );
        console.log("Total gas used INIT: " + submitHeaderTx.receipt.gasUsed)
    });
    

    it("EVAL CASE 1: verify block header ", async () => {   
        
        storeGenesis();
        let submitBlock1 = await relay.submitBlockHeader(
            constants.HEADERS.BLOCK_1, 
            1,
            "0xC5a96Db085dDA36FfBE390f455315D30D6D3DC52", // random address
            false
        );

        console.log("Total gas used (Verify Header): " + submitBlock1.receipt.gasUsed);
   });

   it("EVAL CASE 2: verify block AND store header ", async () => {   
        
    storeGenesis();
    let submitBlock1 = await relay.submitBlockHeader(
        constants.HEADERS.BLOCK_1, 
        1,
        "0xC5a96Db085dDA36FfBE390f455315D30D6D3DC52", // random address
        true
    );
    console.log("Total gas used (Verify+Stroe Header): " + submitBlock1.receipt.gasUsed);
    });


    it("EVAL CASE 3: verify tx inclusion", async () => {
        await relay.initialize(
            constants.EVAL_TX.INDEXED_HEADERS[0].HEADER,
            541444,
            0,
            1536963606,
            10,
            100,
            1
        );
        let txVerify = await relay.evalVerifyTX(
            constants.EVAL_TX.TXID_LE,
            541444,
            constants.EVAL_TX.PROOF_INDEX,
            constants.EVAL_TX.PROOF,
            0
        );
        console.log("Total gas used (Verify TX): " + txVerify.receipt.gasUsed);
    });

    
    it("EVAL CASE 4: parse transaction inputs, outputs, op_return", async () => {
       
        let txParse = await relay.parseTX(
            constants.EVAL_TX.TX
        );
        console.log("Total gas used (Parse TX): " + txParse.receipt.gasUsed);
    });
    

})