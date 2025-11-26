#!/bin/bash
# Complete automated deployment script
# Usage: ./scripts/deploy-all.sh

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}🚀 Mindshare Prediction Market - Automated Deployment${NC}\n"

# Check if .env exists
if [ ! -f .env ]; then
    echo -e "${RED}Error: .env file not found${NC}"
    echo "Create .env with:"
    echo "  PRIVATE_KEY=0x..."
    echo "  RPC_URL=https://sepolia.base.org"
    echo "  API_URL=http://localhost:3001"
    echo "  STAKE_TOKEN_ADDRESS=0x... (optional, script will check DB first)"
    exit 1
fi

# Load .env
export $(grep -v '^#' .env | xargs)

# Required variables
if [ -z "$PRIVATE_KEY" ] || [ -z "$RPC_URL" ]; then
    echo -e "${RED}Error: PRIVATE_KEY and RPC_URL must be set in .env${NC}"
    exit 1
fi

# Default API_URL
API_URL=${API_URL:-http://localhost:3001}

# Check if backend is running
echo -e "${BLUE}Checking if backend API is running...${NC}"
if ! curl -s "$API_URL/api/contracts" > /dev/null 2>&1; then
    echo -e "${YELLOW}⚠️  Backend API not responding at $API_URL${NC}"
    echo "Please start the backend first:"
    echo "  cd ../backend/api && npm run dev"
    read -p "Continue anyway? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
else
    echo -e "${GREEN}✅ Backend API is running${NC}\n"
fi

# Step 1: Check for existing stake token in database
echo -e "${YELLOW}Step 1: Checking for existing stake token...${NC}"
EXISTING_TOKEN=$(curl -s "$API_URL/api/contracts" | python3 -c "import sys, json; data = json.load(sys.stdin); token = next((c.get('address') for c in data if c.get('type') == 'stakeToken'), None); print(token) if token else exit(1)" 2>/dev/null || echo "")

if [ -n "$EXISTING_TOKEN" ]; then
    echo -e "${BLUE}Found existing stake token in database: $EXISTING_TOKEN${NC}"
    read -p "Reuse this token? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        export STAKE_TOKEN_ADDRESS="$EXISTING_TOKEN"
        echo -e "${GREEN}✅ Will reuse existing token: $EXISTING_TOKEN${NC}\n"
    else
        echo -e "${YELLOW}Will deploy a new token${NC}\n"
        unset STAKE_TOKEN_ADDRESS
    fi
else
    echo -e "${BLUE}No existing stake token found in database${NC}"
    if [ -n "$STAKE_TOKEN_ADDRESS" ]; then
        echo -e "${BLUE}Using STAKE_TOKEN_ADDRESS from .env: $STAKE_TOKEN_ADDRESS${NC}\n"
    else
        echo -e "${BLUE}Will deploy a new token${NC}\n"
    fi
fi

# Step 2: Deploy contracts
echo -e "${YELLOW}Step 2: Deploying contracts...${NC}"
echo "This may take 1-2 minutes (verification can be slow)..."
echo ""

# Check if ETHERSCAN_API_KEY is set for verification
VERIFY_FLAG=""
if [ -n "$ETHERSCAN_API_KEY" ]; then
    VERIFY_FLAG="--verify"
    echo "✓ Verification enabled"
else
    echo "⚠ Verification skipped (set ETHERSCAN_API_KEY to enable)"
fi

# Run deployment - show output in real-time
echo "Running forge script (you'll see output below)..."
echo ""
forge script script/Deploy.s.sol:Deploy \
    --rpc-url "$RPC_URL" \
    --broadcast \
    $VERIFY_FLAG \
    -vv 2>&1 | tee deploy.log
echo ""
echo -e "${BLUE}Deployment script finished. Extracting addresses...${NC}"

# Extract addresses from log
echo -e "${BLUE}Extracting contract addresses from logs...${NC}"
FACTORY_ADDRESS=$(grep "MarketFactory:" deploy.log | tail -1 | awk '{print $2}')
SETTLEMENT_ORACLE=$(grep "SettlementOracle:" deploy.log | tail -1 | awk '{print $2}')
STAKE_TOKEN=$(grep "StakeToken:" deploy.log | tail -1 | awk '{print $2}')
IMPLEMENTATION=$(grep "Implementation:" deploy.log | tail -1 | awk '{print $2}')

if [ -z "$FACTORY_ADDRESS" ] || [ -z "$SETTLEMENT_ORACLE" ] || [ -z "$STAKE_TOKEN" ]; then
    echo -e "${RED}Error: Could not extract all contract addresses${NC}"
    echo "Check deploy.log for details"
    echo "Last 20 lines of deploy.log:"
    tail -20 deploy.log
    exit 1
fi

echo -e "${GREEN}✅ Contracts deployed!${NC}"
echo "  Factory: $FACTORY_ADDRESS"
echo "  Oracle: $SETTLEMENT_ORACLE"
echo "  Token: $STAKE_TOKEN"
echo "  Implementation: $IMPLEMENTATION"
echo ""

# Step 3: Save contracts to API
echo -e "${YELLOW}Step 3: Saving contract addresses to database...${NC}"
CONTRACTS_JSON=$(cat <<EOF
{
  "contracts": [
    {"type": "settlementOracle", "address": "$SETTLEMENT_ORACLE"},
    {"type": "marketFactory", "address": "$FACTORY_ADDRESS"},
    {"type": "stakeToken", "address": "$STAKE_TOKEN"},
    {"type": "implementation", "address": "$IMPLEMENTATION"}
  ]
}
EOF
)

RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$API_URL/api/contracts" \
    -H "Content-Type: application/json" \
    --data "$CONTRACTS_JSON")

HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
if [ "$HTTP_CODE" = "200" ]; then
    echo -e "${GREEN}✅ Contract addresses saved to database${NC}\n"
else
    echo -e "${YELLOW}⚠️  Failed to save contracts (HTTP $HTTP_CODE)${NC}"
    echo "Response: $(echo "$RESPONSE" | sed '$d')"
    echo ""
fi

# Step 4: Fetch market suggestions and create markets
echo -e "${YELLOW}Step 4: Fetching market suggestions from leaderboard...${NC}"
MARKETS_CONFIG=$(curl -s "$API_URL/api/admin/markets/suggest?top10Count=5&h2hCount=5")

if [ -z "$MARKETS_CONFIG" ] || echo "$MARKETS_CONFIG" | grep -q "error"; then
    echo -e "${RED}Error: Failed to fetch market suggestions${NC}"
    echo "Response: $MARKETS_CONFIG"
    exit 1
fi

# Write config to JSON file for Foundry script
echo "$MARKETS_CONFIG" > markets-config.json
export MARKETS_CONFIG_JSON="$MARKETS_CONFIG"
echo -e "${GREEN}✅ Market config generated:${NC}"
echo "$MARKETS_CONFIG" | python3 -m json.tool | head -20
echo ""

echo -e "${YELLOW}Step 5: Creating markets (5 min lockTime)...${NC}"
echo "Creating markets based on leaderboard (you'll see output below)..."
echo ""
export FACTORY_ADDRESS

forge script script/CreateMarkets.s.sol:CreateMarkets \
    --rpc-url "$RPC_URL" \
    --broadcast \
    -vv 2>&1 | tee markets.log
echo ""
echo -e "${BLUE}Market creation finished. Extracting JSON...${NC}"

# Step 6: Extract and import markets
echo -e "${YELLOW}Step 6: Extracting and importing markets...${NC}"

# Extract JSON from log (between markers)
echo "Extracting markets JSON from logs..."
MARKETS_JSON=$(python3 <<PYTHON
import json
import re
import sys

with open('markets.log', 'r') as f:
    lines = f.readlines()

# Find marker
start_idx = None
for i, line in enumerate(lines):
    if 'Market Configuration (JSON)' in line:
        start_idx = i + 1
        break

if start_idx is None:
    print('[]', file=sys.stderr)
    sys.exit(1)

# Collect JSON lines
json_lines = []
for i in range(start_idx, len(lines)):
    line = lines[i].strip()
    if not line:
        continue
    # Stop at end of JSON array
    if line == ']' or line.startswith('Transactions saved'):
        if line == ']':
            json_lines.append(line)
        break
    # Clean up the line (remove leading spaces)
    line = re.sub(r'^\s+', '', line)
    json_lines.append(line)

json_str = ''.join(json_lines)
# Fix missing commas between fields
json_str = re.sub(r'("\w+":\s*"[^"]+")\s*\n\s*(")', r'\1,\n      \2', json_str)
json_str = re.sub(r'("\w+":\s*\d+)\s*\n\s*(")', r'\1,\n      \2', json_str)
# Remove trailing commas
json_str = re.sub(r',(\s*[}\]])', r'\1', json_str)

try:
    data = json.loads(json_str)
    print(json.dumps(data))
except Exception as e:
    print(f'Error: {e}', file=sys.stderr)
    print('[]', file=sys.stderr)
    sys.exit(1)
PYTHON
)

if [ "$MARKETS_JSON" = "[]" ] || [ -z "$MARKETS_JSON" ]; then
    echo -e "${RED}Error: Could not extract markets JSON${NC}"
    echo "Check markets.log for the JSON output"
    exit 1
fi

# Import markets
IMPORT_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$API_URL/api/admin/markets/import" \
    -H "Content-Type: application/json" \
    --data "{\"markets\": $MARKETS_JSON, \"clearExisting\": true}")

IMPORT_HTTP_CODE=$(echo "$IMPORT_RESPONSE" | tail -n1)
if [ "$IMPORT_HTTP_CODE" = "200" ]; then
    echo -e "${GREEN}✅ Markets imported successfully${NC}"
    echo "$IMPORT_RESPONSE" | sed '$d' | grep -o '"count":[0-9]*' || echo "$IMPORT_RESPONSE" | sed '$d'
else
    echo -e "${RED}Error: Failed to import markets (HTTP $IMPORT_HTTP_CODE)${NC}"
    echo "Response: $(echo "$IMPORT_RESPONSE" | sed '$d')"
    exit 1
fi

echo ""
echo -e "${GREEN}✅ Deployment complete!${NC}\n"
echo "Contract addresses saved to database at $API_URL"
echo "Markets created with 5-minute lockTime"
echo ""
echo "Next steps:"
echo "  1. Start backend: cd ../backend/api && npm run dev"
echo "  2. Start frontend: cd ../frontend && npm run dev"
echo "  3. Run oracle: cd ../oracle && npm run dev (after resolveTime)"
echo ""
echo "All services will automatically fetch contract addresses from the database!"

