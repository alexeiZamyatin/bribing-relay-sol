var BribeRelay = artifacts.require("./BribeRelay.sol");
var Utils = artifacts.require("./Utils.sol")

module.exports = function (deployer, network) {
    if (network == "development") {
        deployer.deploy(Utils);
        deployer.link(Utils, BribeRelay);
        deployer.deploy(BribeRelay);
    } else if (network == "ropsten") {
        deployer.deploy(BribeRelay);
    } else if (network == "main") {
        deployer.deploy(BribeRelay);
    }
};
