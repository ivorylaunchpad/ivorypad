<p align="center"><img src=".github/banner.png" alt="Ivorypad: launch on Whitechain" width="100%" /></p>

<p align="center">
  <img src=".github/logo.png" alt="Ivorypad logo" width="72" />
</p>

<h1 align="center">Ivorypad</h1>

<p align="center"><b>The memecoin launchpad on Whitechain.</b><br/>Launch a coin in one signature. Ownership renounced. LP burned at graduation.</p>

<p align="center">
  <a href="https://ivorypads.com">Website</a> ·
  <a href="https://t.me/Ivorypad_bot">Telegram bot</a> ·
  <a href="https://x.com/Ivorypad">X</a> ·
  <a href="https://explorer.whitechain.io/address/0x3c44D829BbA9781D73f42497fD73896152CA4910">Factory on explorer</a>
</p>

---

## What Ivorypad is

Ivorypad lets anyone launch a memecoin on [Whitechain](https://whitechain.io) (chain 1875) and trade it from the first second.

The platform has three parts:
- **Website** ([ivorypads.com](https://ivorypads.com)): launch, markets, coin pages with a live market-cap chart, a portfolio, a token locker, a bridge and analytics.
- **Telegram bot** ([@Ivorypad_bot](https://t.me/Ivorypad_bot)): built-in wallets, buying and selling, launches, and bridging from Ethereum, BNB Chain and Robinhood Chain.
- **Smart contracts** (this repository): what runs on chain.

This repository holds the on-chain contracts only, published so that anyone can read them and check them against the deployed code. The website, the bot and the infrastructure are not public.

## How a coin works

- **One-transaction launch**: 1,000,000,000 coins are minted once, into the coin's own pool. There is no mint function, no admin key and no upgrade path.
- **Ownership renounced**: the coin and its market both report `owner() = 0x0`. The trade tax (0–10%) is fixed forever at launch.
- **Bonding curve**: priced in WBT (or USDC.e). A coin opens at about **$2.5K market cap**.
- **Graduation at 100 WBT raised**: in that same trade:
  - the curve closes;
  - the liquidity moves into the coin's own **WhiteSwap** pair;
  - the **LP tokens are burned**, and so are the unused coins.

  The pair is created at launch and blocked until graduation, so nobody can seed it early.
- **Rewards**: the tax goes to the creator, to holders, or to buyback-and-burn, as chosen at launch. Rewards are paid in WBT. Claiming never moves the price, market cap, reserves or supply.
- **Locker**: any token can be locked until a chosen date. A lock can only be extended, never shortened. There is no admin and no early exit.

## Mainnet contracts (Whitechain)

| Contract | Address |
|---|---|
| IvoryFactory | [0x3c44D829BbA9781D73f42497fD73896152CA4910](https://explorer.whitechain.io/address/0x3c44D829BbA9781D73f42497fD73896152CA4910) |
| LockVault | [0x6c4a77c221C5f93E72c8857bF7d8142deAD2f407](https://explorer.whitechain.io/address/0x6c4a77c221C5f93E72c8857bF7d8142deAD2f407) |
| IvoryTokenDeployer | [0x8982353b0ebD4306adf5322279c312A080aA372a](https://explorer.whitechain.io/address/0x8982353b0ebD4306adf5322279c312A080aA372a) |
| IvoryMarketDeployer | [0xFeC9005472cE27fD3D6F1CAaF10BA3Af845397B8](https://explorer.whitechain.io/address/0xFeC9005472cE27fD3D6F1CAaF10BA3Af845397B8) |
| WhiteSwap factory | [0x4374A0D2B27e61260ACc9868D4a12dAa80cE0De2](https://explorer.whitechain.io/address/0x4374A0D2B27e61260ACc9868D4a12dAa80cE0De2) |
| WhiteSwap router | [0xE39E00ab80A284E7B61808B15b1C676D00f2430f](https://explorer.whitechain.io/address/0xE39E00ab80A284E7B61808B15b1C676D00f2430f) |

- **Treasury**: [0x8eEB81Bc8Baa23847d08C3Daa5E10011fe9a646D](https://explorer.whitechain.io/address/0x8eEB81Bc8Baa23847d08C3Daa5E10011fe9a646D)
- **Deployed**: 22 November 2026, transaction [0xa2a6e4b5…05bc](https://explorer.whitechain.io/tx/0xa2a6e4b5560d44e532d5bfeb46a5c6056f042a42c229487e33ada682329905bc)
- **Compiler**: Solidity 0.8.30, optimizer 200 runs, EVM paris.

## Contracts in this repository

| File | What it does |
|---|---|
| `contracts/src/IvoryFactory.sol` | Launches coins and creates their WhiteSwap pairs |
| `contracts/src/IvoryMarket.sol` | Each coin's pool: bonding curve, rewards, buyback, graduation into WhiteSwap |
| `contracts/src/IvoryToken.sol` | The coin: fixed supply, holder rewards |
| `contracts/src/LockVault.sol` | Time locks that can only be extended |
| `contracts/src/IvoryDeployers.sol` | Deploy helpers that keep the factory under the contract size limit |

## Launch access

Launching is open to an invited first cohort for now. Anyone can buy and sell every coin.

## Disclaimer

Memecoins are highly speculative and can lose all their value. Nothing here is financial advice. Do your own research.

## License

Copyright © 2026 Ivorypad. **All rights reserved.**

The source is published for transparency and verification only. No license is granted to copy, modify, fork, deploy or reuse this code, in whole or in part, without written permission from Ivorypad. See [LICENSE](LICENSE).
