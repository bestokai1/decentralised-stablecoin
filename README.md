# Decentralised Stable Coin Smart Contract
**This is a demo of a decentralised stable coin contract with implementations of Openzeppelin's contracts such as ERC20 and Ownable and the Chainlink Oracle through pricefeeds**


## About The Project
This minimalistic defi smart contract system is designed to maintain a 1 token == $1 peg. It is loosely based on the MakerDAO DSS (DAI) system
This stablecoin has the following properties:
 * - Exogenous collateral (assets that have their own independent value outside of this stablecoin system.)
 * - Dollar-pegged
 * - Algorithmic stability (use of algorithm to maintain stability of stablecoin)
This stablecoin is similar to DAI if DAI had no governance, no fees and was only backed by WETH and WBTC. This DSC system should always be overcollaterized. At no point should the value of all collateral be less thanor equal to the dollar-backed value of all DSC.

## Actors

Actors:
* User: Will be able to deposit, redeem or be liquidated depending on their liquidation health factor.
* Owner: Owner of the contract that controls the engine of this system. 

## Quick Start
```solidity
 git clone https://github.com/bestokai1/decentralised-stablecoin
 code decentralised-stablecoin
 forge build
```

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Format

```shell
$ forge fmt
```

### Help

```shell
$ forge --help
$ anvil --help
$ cast --help
```
