# Flex Stable Coin (FSC) Engine

## Overview
Flex Stable Coin (FSC) Engine is a decentralized and algorithmic stablecoin system built on Ethereum. It allows users to deposit collateralized assets (like WETH or WBTC) to mint FSC, a stablecoin pegged to 1 USD. The system ensures **over-collateralization**, meaning all issued FSC tokens are backed by more collateral than their total value, maintaining stability and reducing risks.

### Key Features:
- **Over-Collateralized Stability:** Users must deposit collateral worth more than the FSC they mint.
- **No Governance & No Fees:** A purely algorithmic approach similar to **DAI**, but without governance complexities.
- **Secure and Transparent:** Uses **Chainlink price oracles** for real-time price feeds and ensures security via **reentrancy protection**.
- **Liquidation System:** Users with a **low health factor (<1)** can be liquidated, ensuring solvency.
- **Collateral Management:** Supports **depositing, withdrawing, and redeeming** collateral assets.

## How It Works

1. **Deposit Collateral**  
   Users can deposit whitelisted assets like WETH or WBTC to the FSC Engine.

2. **Mint FSC**  
   Once collateral is deposited, users can mint FSC **up to a collateralization threshold (e.g., 150%)**.

3. **Redeem Collateral**  
   Users can return FSC to reclaim their deposited collateral.

4. **Liquidation Mechanism**  
   If a user’s **health factor falls below 1**, their collateral can be **liquidated at a 10% discount**, ensuring protocol stability.

### Security Measures

1. **OracleLib:** Fetches accurate price data to prevent manipulation.
2. **Reentrancy Protection:** Prevents common Solidity attack vectors.
3. **Health Factor Monitoring:** Ensures users remain over-collateralized