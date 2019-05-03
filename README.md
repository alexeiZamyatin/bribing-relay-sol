# Bribing BTC Relay


The block header data used for testing was first provided in the BTCRelay Serpent implementation (<a href="https://github.com/ethereum/btcrelay">repo</a>).  

## Other resources
We make note of the following libraries/implementations, which specifically may aid with Bitcoin transaction parsing:
+ https://github.com/summa-tx/bitcoin-spv
+ https://github.com/tjade273/BTCRelay-tools
+ https://github.com/rainbreak/solidity-btc-parser
+ https://github.com/ethers/bitcoin-proof
+ https://github.com/ethers/EthereumBitcoinSwap 
+ 
## Installation

Make sure ganache-cli and truffle are installed as global packages. Then, install the required packages with:

```
npm install
```

## Testing

Start ganache:

```
ganache-cli
```

Migrate contracts:

```
truffle migrate
```

Run tests: 

```
truffle test
```
This will also re-run migration scripts. 
