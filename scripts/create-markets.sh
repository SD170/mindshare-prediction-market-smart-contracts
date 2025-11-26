#!/bin/bash
# Standalone script to create markets
# Usage: ./scripts/create-markets.sh
# Requires: .env with PRIVATE_KEY, RPC_URL, API_URL

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}📊 Mindshare Prediction Market - Create Markets${NC}\n"

# Check if .env exists
if [ ! -f .env ]; then
    echo -e "${RED}Error: .env file not found${NC}"
    echo "Create .env with:"
    echo "  PRIVATE_KEY=0x..."
    echo "  RPC_URL=https://sepolia.base.org"
    echo "  API_URL=http://localhost:3001"
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
    echo -e "${RED}Error: Backend API not responding at $API_URL${NC}"
    echo "Please start the backend first:"
    echo "  cd ../backend/api && npm run dev"
    exit 1
else
    echo -e "${GREEN}✅ Backend API is running${NC}\n"
fi

# Get factory address from database
echo -e "${BLUE}Fetching factory address from database...${NC}"
FACTORY_ADDRESS=$(curl -s "$API_URL/api/contracts" | python3 -c "import sys, json; data = json.load(sys.stdin); factory = next((c.get('address') for c in data if c.get('type') == 'marketFactory'), None); print(factory) if factory else exit(1)" 2>/dev/null || echo "")

if [ -z "$FACTORY_ADDRESS" ]; then
    echo -e "${RED}Error: MarketFactory address not found in database${NC}"
    echo "Please deploy contracts first using: ./scripts/deploy-all.sh"
    exit 1
fi

echo -e "${GREEN}✅ Found MarketFactory: $FACTORY_ADDRESS${NC}\n"
export FACTORY_ADDRESS

# Fetch market suggestions from API
echo -e "${BLUE}Fetching market suggestions from leaderboard...${NC}"
MARKETS_CONFIG=$(curl -s "$API_URL/api/admin/markets/suggest?top10Count=5&h2hCount=5")

if [ -z "$MARKETS_CONFIG" ] || echo "$MARKETS_CONFIG" | grep -q "error"; then
    echo -e "${RED}Error: Failed to fetch market suggestions${NC}"
    echo "Response: $MARKETS_CONFIG"
    exit 1
fi

# Write config to JSON file and export as env var for Foundry script (in smart-contracts directory)
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
echo "$MARKETS_CONFIG" > "$SCRIPT_DIR/markets-config.json"
export MARKETS_CONFIG_JSON="$MARKETS_CONFIG"
echo -e "${GREEN}✅ Market config generated:${NC}"
echo "$MARKETS_CONFIG" | python3 -m json.tool | head -20
echo ""

# Create markets
echo -e "${YELLOW}Creating markets (5 min lockTime)...${NC}"
echo "Creating markets based on leaderboard (you'll see output below)..."
echo ""

forge script script/CreateMarkets.s.sol:CreateMarkets \
    --rpc-url "$RPC_URL" \
    --broadcast \
    -vv 2>&1 | tee markets.log
echo ""
echo -e "${BLUE}Market creation finished. Extracting JSON...${NC}"

# Extract JSON from log
echo -e "${YELLOW}Extracting markets JSON from logs...${NC}"
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
echo -e "${YELLOW}Importing markets to database...${NC}"
IMPORT_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$API_URL/api/admin/markets/import" \
    -H "Content-Type: application/json" \
    --data "{\"markets\": $MARKETS_JSON, \"clearExisting\": true}")

IMPORT_HTTP_CODE=$(echo "$IMPORT_RESPONSE" | tail -n1)
if [ "$IMPORT_HTTP_CODE" = "200" ]; then
    echo -e "${GREEN}✅ Markets imported successfully${NC}"
    COUNT=$(echo "$IMPORT_RESPONSE" | sed '$d' | python3 -c "import sys, json; data = json.load(sys.stdin); print(data.get('count', 0))" 2>/dev/null || echo "?")
    echo "  Imported $COUNT markets"
    DEPLOYMENT_DATE=$(echo "$IMPORT_RESPONSE" | sed '$d' | python3 -c "import sys, json; data = json.load(sys.stdin); print(data.get('deploymentDate', 'unknown'))" 2>/dev/null || echo "unknown")
    echo "  Deployment date: $DEPLOYMENT_DATE"
else
    echo -e "${RED}Error: Failed to import markets (HTTP $IMPORT_HTTP_CODE)${NC}"
    echo "Response: $(echo "$IMPORT_RESPONSE" | sed '$d')"
    exit 1
fi

echo ""
echo -e "${GREEN}✅ Market creation complete!${NC}\n"
echo "Markets created with 5-minute lockTime"
echo "Markets are now available in the frontend!"

