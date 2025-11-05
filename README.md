# Mindshare Prediction Markets (Web3 MVP)

On-chain parimutuel prediction markets for daily "social mindshare" questions, e.g., "Will Project X be Top-5 on 2025-11-04 (UTC)?", or "Which ranks higher: A or B?"

**Why Web3**: funds are escrowed by code, settlement is automatic from an oracle snapshot, payouts are neutral and auditably pro-rata, and positions can be tokenized later for secondary trading.

## Table of Contents

- [Overview](#overview)
- [Design](#design)
- [Contracts](#contracts)
- [Interfaces](#interfaces)
- [Setup](#setup)
- [Build, Test, Deploy](#build-test-deploy)
- [How It Works](#how-it-works)
- [Security Notes](#security-notes)
- [Roadmap](#roadmap)

## Overview

**Mechanism**: parimutuel pools with two outcomes per market (YES/NO or A/B).

**Phases**: Trading → Locked → Resolved → (Redeem); Cancelled for refunds.

**Oracle**: posts a signed Resolution (winner + snapshot hash) for each market.

**MVP scope**: no fees by default, no secondary market yet (internal claim balances).

**Chain targets**: Ethereum Sepolia.

## Design

**Factory + Clones**: a single `ParimutuelMarket` implementation is cloned per question using EIP-1167 minimal proxies.

**Deterministic ID**: `marketId = keccak256(factory, questionHash, lockTime)`.

**Resolution**: oracle signs a struct with `marketId`, `winner`, `snapshotHash` and posts it on-chain; markets pull it to settle.

**Payout math**: winner per-unit = `gross(1 - fee) / winnerPool`; each account gets `claims * perUnit`.

**Losing side redemption**: users on the losing side can still call `redeem()` which succeeds but pays 0, preventing double-redemption attempts.

### EIP-1167 Minimal Proxy Pattern

This project uses **EIP-1167** (minimal proxy/clone pattern) to create gas-efficient market instances. Instead of deploying a full contract for each market (which would cost ~500k+ gas), we deploy a minimal proxy that delegates all calls to a single implementation contract.

**How it works**:
- One `ParimutuelMarket` implementation contract is deployed once (contains all the logic)
- Each new market is created as a minimal proxy (~55 bytes) that delegates calls to the implementation
- The proxy stores only its own state (pools, accounts, phase, etc.) but executes logic from the implementation
- The factory uses OpenZeppelin's `Clones.clone()` to create proxies

**Benefits**:
- **Gas savings**: ~95% reduction in deployment costs (from ~500k gas to ~45k gas per market)
- **Upgradeability consideration**: If logic needs updating, only the implementation needs to be redeployed (though proxies remain immutable)
- **Code reuse**: Single implementation contract can serve unlimited market instances

**Implementation details**:
- The `ParimutuelMarket` constructor is empty (clones don't execute constructors)
- Each proxy is initialized via `initialize()` which sets all state variables
- The `initialized` flag prevents re-initialization
- The `factory` address is captured during `initialize()` to enforce `onlyFactory` modifier

**Example**:
```solidity
// Deploy once (expensive)
ParimutuelMarket impl = new ParimutuelMarket();

// Create many markets (cheap)
address market1 = Clones.clone(address(impl));
address market2 = Clones.clone(address(impl));
// Each market has its own state but shares the same logic
```

For more details, see [EIP-1167: Minimal Proxy Standard](https://eips.ethereum.org/EIPS/eip-1167).

## Directory Structure

```
src/
  MarketFactory.sol
  ParimutuelMarket.sol
  SettlementOracle.sol
  interfaces/
    ISettlementOracle.sol
  StakeToken.sol        # mock ERC-20 for tests
script/
  Deploy.s.sol
test/
  Base.t.sol
  MarketHappy.t.sol
  MarketNegative.t.sol
  FactoryAndAdmin.t.sol
  Fuzz.t.sol
  ParimutuelMarket.t.sol
foundry.toml
```

## Contracts

### MarketFactory.sol

Deploys clone markets using EIP-1167 minimal proxies, sets global params (stake token, oracle, fee sink, fee bps).

- **Constructor**: `(address _implementation, address _stakeToken, address _oracle, address _feeSink)`
  - Stores the `ParimutuelMarket` implementation address for cloning
  - Sets initial global parameters for all markets
- **Events**: `MarketCreated`, `ParamsUpdated`
- **Functions**:
  - `setParams(address _stakeToken, address _oracle, address _feeSink, uint16 _feeBps)` - owner only, updates global params for future markets
  - `computeMarketId(bytes32 questionHash, uint64 lockTime)` - returns deterministic market ID: `keccak256(factory, questionHash, lockTime)`
  - `createMarket(bytes32 questionHash, uint64 lockTime, uint64 resolveTime)` - owner only, creates new market clone using `Clones.clone(implementation)` and calls `initialize()` on the proxy
  - `cancel(address market)` - owner only, cancels a market pre-resolution to enable refunds

**EIP-1167 Implementation**: Uses OpenZeppelin's `Clones.clone()` to create minimal proxies that delegate to the implementation contract, reducing deployment costs by ~95% compared to deploying full contracts.

### ParimutuelMarket.sol

Implementation contract that holds the market logic. Each market instance is created as an EIP-1167 minimal proxy that delegates to this implementation. Holds stake token, pool totals (A and B), per-account claim balances.

**Clone Pattern Considerations**:
- Empty constructor (clones don't execute constructors)
- State variables cannot be `immutable` (must be set via `initialize()`)
- `initialize()` must be called once per clone to set all state
- `initialized` flag prevents re-initialization attacks

- **Phases**: `Trading`, `Locked`, `Resolved`, `Cancelled`
- **Functions**:
  - `initialize(address _stakeToken, address _oracle, address _feeSink, bytes32 _marketId, bytes32 _questionHash, uint64 _lockTime, uint64 _resolveTime, uint16 _feeBps)` - one-time initialization for clones; sets `factory = msg.sender` and all market parameters
  - `deposit(uint8 outcome, uint256 amount)` - during Trading phase, deposits stake for outcome 1 or 2
  - `close()` - flips to Locked phase at/after `lockTime`
  - `settle()` - in Locked phase after `resolveTime`, reads oracle, sets winner, flips to Resolved
  - `redeem()` - pays pro-rata to winners; losing claims redeem to 0; prevents double-redeem via `redeemed` flag
  - `cancel()` - factory only, sets phase to Cancelled
  - `refund()` - only when Cancelled, returns principal 1:1 to all depositors

**Payout calculation**:
- Winner 1: `payout = (aClaims * gross) / pools.A`
- Winner 2: `payout = (bClaims * gross) / pools.B`
- Gross = `pools.A + pools.B` minus fees (if `feeBps > 0`)

### SettlementOracle.sol

Stores Resolution per marketId. Accepts signed posts from a configured signer (ECDSA with EIP-191 message hash).

- **Constructor**: `(address _signer)` - sets initial signer address
- **State**: `owner` (immutable), `signer` (updatable by owner)
- **Events**: `SignerUpdated`, `Posted`
- **Functions**:
  - `getSigner()` - returns current signer address
  - `setSigner(address s)` - owner only, updates signer
  - `getResolution(bytes32 marketId)` - returns `(winner, snapshotHash, resolvedAt)` for a market
  - `post(Resolution calldata r, bytes calldata sig)` - verifies signature from signer, stores resolution

**Signature verification**: uses `MessageHashUtils.toEthSignedMessageHash()` with EIP-191 prefix for message signing.

## Interfaces

### ISettlementOracle.sol

```solidity
interface ISettlementOracle {
    struct Resolution {
        bytes32 marketId;     // bound to a specific market
        uint8   winner;       // 1 or 2
        bytes32 snapshotHash; // keccak256(json snapshot used to decide)
        uint64  resolvedAt;   // <= block.timestamp
        uint64  challengeUntil; // reserved for optimistic upgrades
        uint256 nonce;        // replay protection
    }

    function getSigner() external view returns (address);
    function getResolution(bytes32 marketId)
        external view returns (uint8 winner, bytes32 snapshotHash, uint64 resolvedAt);
    function post(Resolution calldata r, bytes calldata sig) external;
}
```

## Setup

### Dependencies

- **Foundry** (latest version via `foundryup`)
- **OpenZeppelin Contracts v5.x** (installed as git submodule)

### Installation

```bash
# Install Foundry (if not already installed)
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Clone the repository
git clone <repository-url>
cd smart-contracts

# Install dependencies (if not already present)
forge install OpenZeppelin/openzeppelin-contracts --no-commit
```

The project uses Foundry's remappings for OpenZeppelin contracts. The import path `openzeppelin-contracts/contracts/...` is automatically resolved.

## Build, Test, Deploy

### Build

```bash
forge build
```

### Test

```bash
# Run all tests
forge test

# Run with verbose output
forge test -vv

# Run specific test file
forge test --match-path test/MarketHappy.t.sol
```

**Test Coverage**:
- ✅ Happy paths: deposit → lock → oracle post → settle → redeem
- ✅ Multi-user pro-rata with and without fees
- ✅ Negative cases: invalid outcome, deposit after lock, early settle, missing oracle, bad signature, double-redeem, refund gating
- ✅ Factory: cancel + refunds
- ✅ Fuzz: pro-rata invariant (257 runs)

### Deploy

**Example: Base Sepolia**

```bash
# Set environment variables
export RPC_URL="https://sepolia.base.org"
export PRIVATE_KEY=0xYOUR_PRIVATE_KEY

# Deploy
forge script script/Deploy.s.sol:Deploy \
    --rpc-url $RPC_URL \
    --broadcast \
    --verify \
    -vvvv
```

The deploy script will:
1. Deploy `StakeToken` (mock ERC-20)
2. Deploy `SettlementOracle` with deployer as signer
3. Deploy `ParimutuelMarket` implementation
4. Deploy `MarketFactory` with all addresses
5. Create an example market

## How It Works

### 1. Create a Market

```solidity
factory.createMarket(questionHash, lockTime, resolveTime);
```

Factory clones `ParimutuelMarket` with deterministic `marketId = keccak256(factory, questionHash, lockTime)`.

### 2. Trade

Users call `deposit(outcome, amount)` during Trading phase:
- Outcome 1 → adds to `pools.A` and `aClaims[user]`
- Outcome 2 → adds to `pools.B` and `bClaims[user]`

### 3. Lock

Anyone calls `close()` after `lockTime` to stop deposits and move to Locked phase.

### 4. Oracle Posts Resolution

Off-chain pipeline:
1. Computes daily snapshot JSON
2. Hashes it: `snapshotHash = keccak256(json)`
3. Creates `Resolution` struct with `marketId`, `winner` (1 or 2), `snapshotHash`, `resolvedAt`, `nonce`
4. Signs with EIP-191 message hash: `sig = sign(keccak256("\x19Ethereum Signed Message:\n32", blob))`
5. Calls `oracle.post(r, sig)`

### 5. Settle

Anyone calls `settle()` after `resolveTime`:
- Reads `winner` from oracle
- Sets market phase to Resolved

### 6. Redeem

Winners call `redeem()`:
- Receives pro-rata share: `(claims * gross) / winnerPool`
- Gross = `pools.A + pools.B` minus fees (if any)
- Fees sent to `feeSink` if `feeBps > 0`

Losers can also call `redeem()` but receive 0 payout (marks as redeemed to prevent double-redemption).

### 7. Cancel & Refund (Optional)

Factory owner can cancel market before resolution:
```solidity
factory.cancel(market);
```

Users then call `refund()` to get their original stake back 1:1.

### Implied Odds While Trading

- Probability of outcome A: `π_A = pools.A / (pools.A + pools.B)`
- Probability of outcome B: `π_B = pools.B / (pools.A + pools.B)`
- Payout multiple if A wins: `(pools.A + pools.B) * (1 - fee) / pools.A`

## Security Notes

**MVP Limitations**:
- No pausing/role module yet (only owner checks)
- No reentrancy into external calls besides `SafeERC20` transfers (protected with `nonReentrant`)
- Bounded math uses Solidity 0.8 built-in checks
- Oracle signature uses `MessageHashUtils + ECDSA.recover` with EIP-191 prefix

**Production Recommendations**:
- Migrate to full EIP-712 typed data with explicit domain separator and chain id
- Add `Ownable2Step` or `AccessControl` for role management
- Add `Pausable` for emergency stops
- Consider rate limits and circuit breakers
- Add event indexing for analytics
- Implement liveness checks for oracle posts
- Document market creation policy to avoid one-sided pools (zero-side pools will revert on redeem)

**DoS Considerations**:
- Market can be settled by anyone after `resolveTime` (consider liveness checks in prod)
- Oracle posts are permissionless (signature verification prevents unauthorized posts)
- Replay protection via `usedHash` mapping

## Roadmap

- **ERC-1155 claim tokens**: positions become transferable and tradable on DEXs
- **Optimistic oracle**: dispute window versus single-signer oracle
- **LMSR/AMM markets**: continuous pricing on selected high-interest questions
- **Multi-source leaderboard**: Twitter/Reddit/YouTube with anti-gaming filters; keep `snapshotHash` as on-chain anchor
- **Frontend**: simple market list, deposit UI with post-bet payout preview, and redeem flow
- **Access control**: upgrade to `Ownable2Step` or `AccessControl` for better role management
- **EIP-712**: migrate oracle signatures to full typed data with domain separator

