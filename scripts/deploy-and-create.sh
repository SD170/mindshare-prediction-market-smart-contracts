#!/bin/bash
# Complete deployment and market creation script
# Usage: ./scripts/deploy-and-create.sh

set -e  # Exit on error

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${GREEN}🚀 Mindshare Prediction Market - Deployment Script${NC}"
echo ""

# Check if .env exists
if [ ! -f .env ]; then
    echo -e "${RED}Error: .env file not found${NC}"
    echo "Please create .env file with:"
    echo "  PRIVATE_KEY=0x..."
    echo "  RPC_URL=https://sepolia.base.org"
    echo "  ETHERSCAN_API_KEY=... (optional)"
    exit 1
fi

# Load .env
export $(grep -v '^#' .env | xargs)

if [ -z "$PRIVATE_KEY" ] || [ -z "$RPC_URL" ]; then
    echo -e "${RED}Error: PRIVATE_KEY and RPC_URL must be set in .env${NC}"
    exit 1
fi

echo -e "${YELLOW}Step 1: Deploying contracts...${NC}"
forge script script/Deploy.s.sol:Deploy \
    --rpc-url "$RPC_URL" \
    --broadcast \
    --verify \
    -vvvv 2>&1 | tee deploy.log

# Extract factory address from deploy output
FACTORY_ADDRESS=$(grep "MarketFactory:" deploy.log | tail -1 | awk '{print $2}')

if [ -z "$FACTORY_ADDRESS" ]; then
    echo -e "${RED}Error: Could not extract MarketFactory address${NC}"
    exit 1
fi

echo ""
echo -e "${GREEN}✅ Contracts deployed!${NC}"
echo "Factory Address: $FACTORY_ADDRESS"
echo ""

# Extract and update oracle contracts.json
echo -e "${YELLOW}Step 2: Updating oracle contract addresses...${NC}"
SETTLEMENT_ORACLE=$(grep "SettlementOracle:" deploy.log | tail -1 | awk '{print $2}')
STAKE_TOKEN=$(grep "StakeToken:" deploy.log | tail -1 | awk '{print $2}')
IMPLEMENTATION=$(grep "Implementation:" deploy.log | tail -1 | awk '{print $2}')
DEPLOYER=$(grep "Deployer:" deploy.log | tail -1 | awk '{print $2}')
SIGNER=$(grep "Signer:" deploy.log | tail -1 | awk '{print $2}')

if [ -n "$SETTLEMENT_ORACLE" ] && [ -n "$STAKE_TOKEN" ]; then
    cat > ../oracle/config/contracts.json << EOF
{
  "settlementOracle": "$SETTLEMENT_ORACLE",
  "marketFactory": "$FACTORY_ADDRESS",
  "stakeToken": "$STAKE_TOKEN"
}
EOF
    echo -e "${GREEN}✅ Updated oracle/config/contracts.json${NC}"
else
    echo -e "${YELLOW}⚠️  Could not extract all addresses. Please update oracle/config/contracts.json manually${NC}"
fi

# Push contract addresses to backend API if API_URL is set
if [ -n "$API_URL" ] && [ -n "$SETTLEMENT_ORACLE" ] && [ -n "$STAKE_TOKEN" ]; then
    cat > contracts_payload.json << EOF
{
  "contracts": [
    {"type": "settlementOracle", "address": "$SETTLEMENT_ORACLE"},
    {"type": "marketFactory", "address": "$FACTORY_ADDRESS"},
    {"type": "stakeToken", "address": "$STAKE_TOKEN"},
    {"type": "implementation", "address": "$IMPLEMENTATION"},
    {"type": "deployer", "address": "$DEPLOYER"},
    {"type": "signer", "address": "$SIGNER"}
  ]
}
EOF
    echo "Syncing contracts to API at $API_URL ..."
    curl -s -X POST "$API_URL/api/contracts" \
        -H "Content-Type: application/json" \
        --data @contracts_payload.json || echo "Warning: failed to sync contracts to API."
fi

echo ""
echo -e "${YELLOW}Step 3: Creating markets...${NC}"
export FACTORY_ADDRESS

forge script script/CreateMarkets.s.sol:CreateMarkets \
    --rpc-url "$RPC_URL" \
    --broadcast \
    -vvvv 2>&1 | tee markets.log

echo ""
echo -e "${YELLOW}Step 4: Importing market configuration via API...${NC}"

# Extract markets JSON from log
# The JSON appears after "=== Market Configuration (JSON) ==="
# Foundry logs show console.log output with 2-space indentation
# Extract lines between the markers and save to temp file, then format with Python
TEMP_JSON=$(mktemp)
sed -n '/=== Market Configuration (JSON) ===/,/^  \]$/p' markets.log | \
    grep -E '^\s+(\{|\[|"|}|]|,)' | \
    sed 's/^  //' > "$TEMP_JSON"

# Use Python to parse and format the JSON properly
if command -v python3 &> /dev/null; then
    MARKETS_JSON=$(python3 -c "
import json
import sys
with open('$TEMP_JSON', 'r') as f:
    lines = [line.rstrip() for line in f if line.strip()]
    json_str = ''.join(lines)
    # Remove trailing comma before closing brace if present
    json_str = json_str.replace(',}', '}').replace(',]', ']')
    try:
        data = json.loads(json_str)
        print(json.dumps(data))
    except:
        print('[]')
")
else
    # Fallback: try to format manually (less reliable)
    MARKETS_JSON=$(cat "$TEMP_JSON" | tr '\n' ' ' | sed 's/  */ /g' | sed 's/, }/}/g' | sed 's/, ]/]/g')
fi
rm -f "$TEMP_JSON"

# If still empty, try to find JSON array in the log
if [ -z "$MARKETS_JSON" ] || [ "$MARKETS_JSON" = "[]" ]; then
    echo -e "${YELLOW}⚠️  Could not extract markets JSON from log${NC}"
    echo "Checking if markets.log contains JSON output..."
    if grep -q "Market Configuration" markets.log; then
        echo "Found 'Market Configuration' marker, but JSON extraction failed"
        echo "Showing relevant lines from log:"
        grep -A 50 "=== Market Configuration" markets.log | head -60
    else
        echo "No 'Market Configuration' marker found in markets.log"
    fi
    echo ""
    echo "Markets may need to be imported manually. Check markets.log for the JSON output."
else
    # Default API_URL if not set
    API_URL=${API_URL:-http://localhost:3001}
    
    echo "Extracted markets JSON (first 200 chars): ${MARKETS_JSON:0:200}..."
    echo "Importing markets to $API_URL (clearing old markets first)..."
    
    # Save to temp file for debugging
    echo "$MARKETS_JSON" > markets_extracted.json
    
    RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$API_URL/api/admin/markets/import" \
        -H "Content-Type: application/json" \
        --data "{\"markets\": $MARKETS_JSON, \"clearExisting\": true}")
    
    HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
    BODY=$(echo "$RESPONSE" | sed '$d')
    
    if [ "$HTTP_CODE" = "200" ]; then
        echo -e "${GREEN}✅ Markets imported successfully${NC}"
        echo "$BODY" | grep -o '"count":[0-9]*' || echo "$BODY"
        rm -f markets_extracted.json
    else
        echo -e "${RED}⚠️  Failed to import markets (HTTP $HTTP_CODE)${NC}"
        echo "Response: $BODY"
        echo ""
        echo "Extracted JSON saved to markets_extracted.json for debugging"
        echo "You can try importing manually:"
        echo "  curl -X POST $API_URL/api/admin/markets/import \\"
        echo "    -H \"Content-Type: application/json\" \\"
        echo "    --data \"{\\\"markets\\\": $(cat markets_extracted.json), \\\"clearExisting\\\": true}\""
    fi
fi

echo ""
echo -e "${GREEN}✅ Deployment complete!${NC}"
echo ""
echo "Next steps:"
echo "  1. Review oracle/config/contracts.json"
echo "  2. Set up oracle/.env with PRIVATE_KEY (must match signer)"
echo "  3. Run oracle: cd oracle && npm install && npm run dev"

