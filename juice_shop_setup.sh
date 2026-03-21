#!/bin/bash
# ============================================================
# Juice Shop Benchmark Setup
# Starts Juice Shop in CTF mode and snapshots baseline state.
#
# Expected structure:
#   <parent>/
#   ├── PentestGPT/
#   └── benchmarking/
#       └── juice_shop_setup.sh
#
# Usage: ./juice_shop_setup.sh
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CTF_KEY="agent-benchmarking-1234"
PORT=3000
LOGS_DIR="$SCRIPT_DIR/juice-shop-logs"
CONTAINER_NAME="juice-shop-benchmark"

mkdir -p "$LOGS_DIR"
docker rm -f "$CONTAINER_NAME" > /dev/null 2>&1 || true

echo "[$(date '+%H:%M:%S')] Starting Juice Shop in CTF mode on port $PORT..."
docker run -d \
  --name "$CONTAINER_NAME" \
  -e "NODE_ENV=ctf" \
  -e "CTF_KEY=$CTF_KEY" \
  -p "${PORT}:3000" \
  bkimminich/juice-shop

attempts=0
until curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PORT" 2>/dev/null | grep -qE "^(200|301|302)$"; do
  sleep 3; attempts=$((attempts+1))
  [[ $attempts -gt 20 ]] && { echo "ERROR: Juice Shop did not start after 60s"; exit 1; }
done
echo "[$(date '+%H:%M:%S')] Juice Shop up at http://localhost:$PORT"

echo "[$(date '+%H:%M:%S')] Snapshotting baseline challenge state..."
curl -s "http://localhost:$PORT/api/Challenges" \
  | python3 -c "
import json, sys
data = json.load(sys.stdin)
challenges = [{'key': c['key'], 'name': c['name'], 'category': c['category'],
               'difficulty': c['difficulty'], 'solved': c['solved']} for c in data['data']]
print(json.dumps(challenges, indent=2))
" > "$LOGS_DIR/baseline.json"

total=$(python3 -c "import json; print(len(json.load(open('$LOGS_DIR/baseline.json'))))")
echo "[$(date '+%H:%M:%S')] Baseline saved — $total challenges tracked"
echo "[$(date '+%H:%M:%S')] Target for PentestGPT: http://host.docker.internal:$PORT"
echo "[$(date '+%H:%M:%S')] After agent run, score with: ./juice_shop_score.sh [label]"