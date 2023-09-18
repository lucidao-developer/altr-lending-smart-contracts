<h1 align="center">Altr Lending</h3>

<div align="center">

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](/LICENSE)

</div>

## Description

This repository contains a Solidity-based smart contract for decentralized lending. It allows users to borrow and lend tokens against NFT collateral. The contract includes features like liquidation, interest rate calculation, and protocol fees.

## Prerequisites

- Docker

## Installation and Setup

### Clone the Repository

```bash
git clone https://github.com/lucidao-developer/altr-lending-smart-contracts.git
cd altr-lending-smart-contracts
```

### Build Docker image
Open your terminal and run the following command:
```bash
docker build --no-cache --progress=plain -t altr-contracts .
```
This will build a docker image with all the dependencies needed to interact with the project.

### Setup docker shell
To access the docker shell run:
```bash
docker run -it -p 3000:3000 altr-contracts sh
```

Then you can use this shell to run the following commands inside docker.

## Compile Contracts

To compile the Solidity contracts, run:

```bash
forge build
```

This will compile all `.sol` files in the `contracts` directory and output the ABI and bytecode in the `out` directory.

## Run Tests

To execute the test suite, run:

```bash
forge test
```

This will execute all test files located in the `test` directory.

## Generate Test Coverage

To generate a code coverage report, run:

```bash
forge coverage
```

This will output a coverage report in the terminal.

## Generate documentation

To generate and read the project documentation, run:

```bash
forge doc --serve --hostname 0.0.0.0
```

This will output the documentation in the docs folder and serve it on the specified port of localhost.

## Special Thanks

This project has been built with the help of:

 [![GitHub](https://img.shields.io/badge/GitHub-NeoBase-blue)](https://github.com/neobase-one)