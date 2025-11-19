# Smart Contracts

On-chain parimutuel prediction markets using EIP-1167 minimal proxy pattern for gas efficiency.

## Setup

```bash
# Install Foundry
foundryup

# Install dependencies
forge install OpenZeppelin/openzeppelin-contracts --no-commit
```

## Build & Test

```bash
forge build
forge test
```

## Deploy

```bash
export RPC_URL="https://sepolia.base.org"
export PRIVATE_KEY=0xYourPrivateKey

# Deploy contracts
forge script script/Deploy.s.sol:Deploy --rpc-url $RPC_URL --broadcast --verify

# Create markets
export FACTORY_ADDRESS=0xYourFactoryAddress
forge script script/CreateMarkets.s.sol:CreateMarkets --rpc-url $RPC_URL --broadcast
```

Use `scripts/deploy-and-create.sh` to automate deployment and market creation.

## Contracts

- **MarketFactory**: Creates market clones using EIP-1167
- **ParimutuelMarket**: Market implementation (cloned per market)
- **SettlementOracle**: Stores signed resolutions from oracle
- **StakeToken**: ERC-20 token for betting

## Market Lifecycle

Trading → Locked → Resolved → Redeem

- **Trading**: Users deposit bets
- **Locked**: Deposits closed, waiting for oracle
- **Resolved**: Oracle posted resolution, winner determined
- **Redeem**: Winners get pro-rata payouts
