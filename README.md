# Decentralized Stablecoin (DSC) Protocol

A decentralized, over-collateralized stablecoin system pegged to the USD, built with Solidity and Foundry.

## About This Project

This project is part of the [Cyfrin Updraft Advanced Foundry Course](https://updraft.cyfrin.io/courses/advanced-foundry), an educational initiative by Patrick Collins and the Cyfrin team. The course teaches advanced Solidity development, DeFi protocol design, and professional smart contract testing practices.

**Course:** [Cyfrin Updraft - Advanced Foundry](https://updraft.cyfrin.io/courses/advanced-foundry)
**Instructor:** Patrick Collins
**Organization:** Cyfrin

---

## Table of Contents

- [Overview](#overview)
- [System Design](#system-design)
- [Features](#features)
- [Technology Stack](#technology-stack)
- [Installation](#installation)
- [Testing](#testing)
- [Deployment](#deployment)
- [Security Considerations](#security-considerations)
- [Project Structure](#project-structure)
- [Contributing](#contributing)
- [License](#license)
- [Acknowledgments](#acknowledgments)

---

## Overview

The Decentralized Stablecoin (DSC) Protocol is an algorithmic stablecoin system that maintains a 1:1 peg with the US Dollar through over-collateralization with crypto assets (wETH and wBTC). The protocol implements a CDP (Collateralized Debt Position) system similar to MakerDAO's DAI, but simplified and without governance.

### Key Characteristics

- **Exogenous Collateral:** Backed by wETH and wBTC (crypto assets with external value)
- **Decentralized:** No governance, no fees, fully algorithmic
- **Anchored/Pegged:** Maintains $1.00 USD peg via Chainlink price oracles
- **Over-Collateralized:** Requires 200% collateralization (50% liquidation threshold)
- **Algorithmic Stability:** Minting and burning mechanisms maintain peg

---

## System Design

### 1. Relative Stability (Pegging Mechanism)

**Target:** $1.00 USD

**Implementation:**
- Chainlink Price Feed integration for real-time price data
- Functions to convert ETH & BTC values to USD equivalents
- Oracle validation (staleness checks, invalid price handling)

### 2. Stability Mechanism (Algorithmic)

**Minting:**
- Users deposit collateral (wETH or wBTC)
- Mint DSC tokens up to 50% of collateral value
- Health factor must remain ≥ 1.0

**Burning:**
- Burn DSC tokens to reduce debt
- Improves health factor
- Enables collateral withdrawal

### 3. Collateral System

**Supported Assets:**
- wETH (Wrapped Ethereum)
- wBTC (Wrapped Bitcoin)

**Collateralization:**
- Minimum 200% collateralization ratio
- Liquidation threshold: 50%
- Liquidation bonus: 10% for liquidators

---

## Features

### Core Functionality

- **Deposit Collateral:** Lock wETH or wBTC as collateral
- **Mint DSC:** Create DSC tokens against deposited collateral
- **Burn DSC:** Destroy DSC tokens to reduce debt
- **Redeem Collateral:** Withdraw collateral (maintains health factor)
- **Liquidation:** Permissionless liquidation of undercollateralized positions

### Safety Features

- ✅ Reentrancy protection (OpenZeppelin ReentrancyGuard)
- ✅ Oracle price validation (staleness and invalid price checks)
- ✅ Health factor monitoring
- ✅ Explicit balance checks (prevents underflow)
- ✅ CEI (Checks-Effects-Interactions) pattern

### Advanced Features

- Multi-collateral support
- Partial liquidations (max 50% of debt)
- Liquidator incentives (10% bonus)
- Comprehensive getter functions for integration

---

## Technology Stack

- **Smart Contract Language:** Solidity ^0.8.20
- **Development Framework:** Foundry
- **Testing Framework:** Forge (Foundry)
- **Price Oracles:** Chainlink
- **Security:** OpenZeppelin Contracts
- **Network:** Ethereum (Sepolia testnet / Anvil local)

---

## Installation

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- [Git](https://git-scm.com/downloads)

### Setup

```bash
# Clone the repository
git clone https://github.com/yourusername/foundry-defi-stablecoin
cd foundry-defi-stablecoin

# Install dependencies
forge install

# Compile contracts
forge build
```

---

## Testing

The project includes a comprehensive test suite with unit tests, integration tests, fuzz tests, and invariant tests.

### Run All Tests

```bash
forge test
```

### Run Specific Tests

```bash
# Constructor tests
forge test --match-test testConstructor

# Price tests
forge test --match-test testGetUsdValue

# Deposit tests
forge test --match-test testDeposit

# Reentrancy tests
forge test --match-test testReentrancy
```

### Test Coverage

```bash
# Generate coverage report
forge coverage

# Generate detailed HTML report
forge coverage --report lcov
genhtml lcov.info -o coverage
open coverage/index.html
```

### Gas Analysis

```bash
forge test --gas-report
```

### Test Categories

- **Constructor Tests:** Initialization and configuration validation
- **Price Tests:** Oracle integration and price conversion
- **Deposit/Withdraw Tests:** Collateral management
- **Mint/Burn Tests:** DSC token lifecycle
- **Liquidation Tests:** Undercollateralized position handling
- **Reentrancy Tests:** Security validation with malicious tokens
- **Health Factor Tests:** Position health calculations

**Current Test Count:** 15+ tests covering critical functionality

---

## Deployment

### Local Deployment (Anvil)

```bash
# Start local node
anvil

# Deploy (in new terminal)
forge script script/DeployDSC.s.sol --rpc-url http://localhost:8545 --broadcast
```

### Testnet Deployment (Sepolia)

```bash
# Set environment variables
export SEPOLIA_RPC_URL=<your_rpc_url>
export PRIVATE_KEY=<your_private_key>
export ETHERSCAN_API_KEY=<your_api_key>

# Deploy
forge script script/DeployDSC.s.sol --rpc-url $SEPOLIA_RPC_URL --broadcast --verify

# Verify contract
forge verify-contract <CONTRACT_ADDRESS> DSCEngine --chain sepolia
```

---

## Security Considerations

### Known Security Features

✅ **Implemented:**
- Reentrancy guards on all state-changing functions
- Oracle staleness validation (3-hour threshold)
- Invalid price rejection (price <= 0)
- Health factor checks prevent undercollateralization
- Explicit balance checks prevent underflow
- CEI pattern followed consistently

### Security Audit Findings

This is an **educational project** and has undergone internal security review. See `SECURITY_AUDIT_REPORT.md` for detailed findings.

**⚠️ WARNING:** This contract is **NOT AUDITED** and should **NOT** be used in production with real funds.

### Recommendations Before Production

1. Professional third-party security audit
2. Formal verification of critical functions
3. Time-weighted average price (TWAP) oracle implementation
4. Emergency pause mechanism
5. Multi-signature admin controls
6. Comprehensive mainnet testing
7. Bug bounty program

---

## Project Structure

```
foundry-defi-stablecoin/
├── src/
│   ├── DSCEngine.sol              # Core protocol logic
│   └── DecentralizedStableCoin.sol # ERC20 stablecoin token
├── script/
│   ├── DeployDSC.s.sol            # Deployment script
│   └── HelperConfig.s.sol         # Network configurations
├── test/
│   ├── unit/
│   │   └── DSCEngineTest.t.sol    # Unit tests
│   └── mocks/
│       ├── ERC20Mock.sol          # Mock ERC20 token
│       ├── MockV3Aggregator.sol   # Mock Chainlink oracle
│       └── MaliciousToken.sol     # Reentrancy testing
├── foundry.toml                   # Foundry configuration
└── README.md                      # This file
```

---

## Key Concepts Learned

This project demonstrates advanced Solidity and DeFi concepts:

- **DeFi Protocol Design:** CDP systems, over-collateralization, liquidations
- **Oracle Integration:** Chainlink price feeds, staleness checks, price validation
- **Smart Contract Security:** Reentrancy protection, CEI pattern, explicit checks
- **Testing Best Practices:** Unit tests, fuzz tests, invariant tests, mocks
- **Foundry Workflow:** Scripting, deployment, testing, gas optimization
- **Protocol Mathematics:** Health factor calculations, liquidation mechanics
- **Event-Driven Architecture:** Proper event emission for off-chain monitoring

---


## Acknowledgments

This project was created as part of the **Cyfrin Updraft Advanced Foundry Course**.

- **Course:** [Cyfrin Updraft - Advanced Foundry](https://updraft.cyfrin.io/courses/advanced-foundry)
- **Instructor:** [Patrick Collins](https://twitter.com/PatrickAlphaC)
- **Organization:** [Cyfrin](https://www.cyfrin.io/)

The course provides comprehensive education on:
- Advanced Solidity development
- DeFi protocol design and implementation
- Smart contract security best practices
- Professional testing methodologies
- Foundry development workflows


### Special Thanks

- Patrick Collins for exceptional blockchain education
- The Cyfrin team for creating world-class educational content
- The Foundry team for building amazing developer tools
- The OpenZeppelin team for security libraries
- The Chainlink team for decentralized oracles

---


