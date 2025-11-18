# DeFi Stablecoin Protocol - Math Reference

## Constants

```solidity
ADDITIONAL_FEED_PRECISION = 1e10   // Scale Chainlink 8 decimals → 18 decimals
PRECISION = 1e18                    // Standard 18 decimal precision
LIQUIDATION_THRESHOLD = 50          // 50% (allows minting 50% of collateral value)
LIQUIDATION_PRECISION = 100         // Denominator for percentages
MIN_HEALTH_FACTOR = 1e18           // 1.0 minimum (below = liquidatable)
LIQUIDATION_BONUS = 10              // 10% liquidator reward
```

## Core Formulas

### 1. Health Factor
**Location:** `DSCEngine.sol:424-425`

```
healthFactor = (collateralValueInUsd × LIQUIDATION_THRESHOLD × PRECISION) / (LIQUIDATION_PRECISION × totalDSCMinted)
```

**Simplified:**
```
healthFactor = (collateralValueInUsd × 0.5 × 1e18) / totalDSCMinted
```

**Special case:** If `totalDSCMinted = 0`, then `healthFactor = type(uint256).max`

- `healthFactor >= 1e18` → Healthy 
- `healthFactor < 1e18` → Liquidatable 

**Example:**
```
Collateral: $30,000
DSC Minted: $10,000

healthFactor = ($30,000 × 0.5 × 1e18) / $10,000
             = 1.5e18
              Healthy (150% of minimum)
```

---

### 2. Token Amount → USD Value
**Location:** `DSCEngine.sol:530`

```
usdValue = (price × ADDITIONAL_FEED_PRECISION × amount) / PRECISION
```

**Example:**
```
Amount: 1 ETH (1e18 wei)
Price: $3,500 (Chainlink returns 3500 × 1e8)

usdValue = (3500e8 × 1e10 × 1e18) / 1e18
         = 3500e18
         = $3,500
```

---

### 3. USD Value → Token Amount
**Location:** `DSCEngine.sol:497`

```
tokenAmount = (usdAmountInWei × PRECISION) / (price × ADDITIONAL_FEED_PRECISION)
```

**Example:**
```
USD: $4,000 (4000e18)
Price: $2,000 (Chainlink returns 2000e8)

tokenAmount = (4000e18 × 1e18) / (2000e8 × 1e10)
            = 2e18
            = 2 ETH
```

---

### 4. Total Collateral Value
**Location:** `DSCEngine.sol:508-515`

```
totalCollateralValueInUsd = Σ getUsdValue(token, amount)
```

**Example:**
```
2 ETH @ $3,500 = $7,000
0.1 BTC @ $60,000 = $6,000

Total = $13,000
```

---

### 5. Maximum Liquidation Amount
**Location:** `DSCEngine.sol:304`

```
maxDebtToCover = (totalDSCMinted × LIQUIDATION_PRECISION) / 200
               = totalDSCMinted / 2
```

**Example:**
```
Total DSC Minted: $20,000
Max Liquidation: $10,000 (50%)
```

---

### 6. Liquidation Collateral (with Bonus)
**Location:** `DSCEngine.sol:308-310`

```
tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover)
bonusCollateral = (tokenAmountFromDebtCovered × LIQUIDATION_BONUS) / LIQUIDATION_PRECISION
totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral
```

**Simplified:**
```
totalCollateralToRedeem = tokenAmountFromDebtCovered × 1.10
```

**Example:**
```
Debt to Cover: $5,000
ETH Price: $2,500

ETH for debt = $5,000 / $2,500 = 2 ETH
Bonus = 2 ETH × 0.10 = 0.2 ETH
Total Seized = 2.2 ETH

Liquidator pays: $5,000 DSC
Liquidator gets: 2.2 ETH (worth $5,500)
Profit: $500 (10%)
```

---

## Worked Examples

### Example 1: Maximum Safe Mint

```
Deposit: 5 ETH @ $3,000/ETH
Collateral Value: $15,000

Max Mintable = $15,000 × 0.5 = $7,500 DSC

At max mint:
healthFactor = ($15,000 × 0.5) / $7,500 = 1.0 (risky!)

Recommended: Mint ~$6,000-7,000 for buffer
```

### Example 2: Liquidation Scenario

```
Initial:
- Collateral: 10 ETH @ $3,000 = $30,000
- Minted: $12,000 DSC
- Health: ($30,000 × 0.5) / $12,000 = 1.25 

Price drops to $2,200:
- New Collateral: 10 ETH @ $2,200 = $22,000
- Health: ($22,000 × 0.5) / $12,000 = 0.916  LIQUIDATABLE

Liquidation:
- Max debt cover: $12,000 / 2 = $6,000
- ETH needed: $6,000 / $2,200 = 2.727 ETH
- Bonus: 2.727 × 0.10 = 0.273 ETH
- Total seized: 3 ETH

After liquidation:
- Remaining collateral: 7 ETH = $15,400
- Remaining debt: $6,000
- New health: ($15,400 × 0.5) / $6,000 = 1.283 
```

### Example 3: Multi-Collateral Health

```
Position:
- 3 ETH @ $3,000 = $9,000
- 0.2 BTC @ $60,000 = $12,000
- Total collateral: $21,000
- DSC minted: $9,000

Health Factor:
($21,000 × 0.5) / $9,000 = 1.17 

Collateralization Ratio: $21,000 / $9,000 = 233%
```

---

## Quick Reference

### Why 50% threshold = 200% collateralization?

```
Max mintable = collateralValue × 0.5

If you mint maximum:
collateralizationRatio = collateralValue / (collateralValue × 0.5) = 2 = 200%
```

### Health Factor Quick Check

| Health Factor | Status | Meaning |
|--------------|--------|---------|
| `∞` (max uint) | Perfect | No debt |
| `> 1.0` | Safe | Over-collateralized |
| `= 1.0` | At Risk | Exactly at threshold |
| `< 1.0` | Danger | Liquidatable |

### Price Precision Conversion

```
Chainlink: 8 decimals  → Multiply by 1e10 → 18 decimals
Token amounts: 18 decimals (standard ERC20)
USD values: 18 decimals (protocol standard)
```

---

**Version:** 1.0 | **Updated:** 2025-11-17
