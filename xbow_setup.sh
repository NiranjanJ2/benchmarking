#!/bin/bash
# ============================================================
# XBOW Setup Script
# 1. Clones the XBOW repo into the benchmarking directory
# 2. Applies all fixes (expose syntax, slim-buster, mysql:5.7.x)
# 3. Runs full health check and saves working IDs
#
# Expected structure:
#   <parent>/
#   ├── PentestGPT/
#   └── benchmarking/     <- run from here
#       └── xbow_setup.sh
#
# Usage: chmod +x xbow_setup.sh && ./xbow_setup.sh
# ============================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
XBOW_DIR="$SCRIPT_DIR/xbow-validation-benchmarks"
BENCHMARKS="$XBOW_DIR/benchmarks"
OUTPUT_FILE="$SCRIPT_DIR/xbow_healthy_ids.txt"
LOG_FILE="$SCRIPT_DIR/xbow_health_check.log"

echo "=========================================="
echo "  XBOW Setup"
echo "  Benchmarking dir: $SCRIPT_DIR"
echo "  Started: $(date)"
echo "=========================================="

# ── Step 1: Clone ───────────────────────────────────────────
if [[ -d "$XBOW_DIR" ]]; then
  echo "[INFO] Repo already exists, pulling latest..."
  cd "$XBOW_DIR" && git pull && cd "$SCRIPT_DIR"
else
  echo "[INFO] Cloning XBOW repo..."
  git clone https://github.com/xbow-engineering/validation-benchmarks.git "$XBOW_DIR"
fi

# ── Step 2: Fixes ───────────────────────────────────────────
echo "[FIX 1] Patching expose syntax..."
find "$BENCHMARKS" -name "docker-compose.yml" | while read f; do
  sed -i '/expose:/,/- [0-9]*:[0-9]*/{s/expose:/ports:/; s/- \([0-9]*\):\([0-9]*\)/- "\1"/}' "$f"
done
echo "[FIX 1] Done"

echo "[FIX 2] Replacing python:3.8-slim-buster..."
find "$BENCHMARKS" -name "Dockerfile" | xargs sed -i 's/slim-buster/slim/g'
echo "[FIX 2] Done"

echo "[FIX 3] Replacing pinned mysql:5.7.x..."
find "$BENCHMARKS" -name "Dockerfile" | xargs grep -l "mysql:5\.7" | while read f; do
  sed -i 's/mysql:5\.7\.[0-9]*/mysql:5.7/g' "$f"
done
echo "[FIX 3] Done"

# ── Step 3: Health check ────────────────────────────────────
ALL=(
  XBEN-001-24 XBEN-002-24 XBEN-003-24 XBEN-004-24 XBEN-005-24 XBEN-006-24 XBEN-007-24 XBEN-008-24 XBEN-009-24 XBEN-010-24
  XBEN-011-24 XBEN-012-24 XBEN-013-24 XBEN-014-24 XBEN-015-24 XBEN-016-24 XBEN-017-24 XBEN-018-24 XBEN-019-24 XBEN-020-24
  XBEN-021-24 XBEN-022-24 XBEN-023-24 XBEN-024-24 XBEN-025-24 XBEN-026-24 XBEN-027-24 XBEN-028-24 XBEN-029-24 XBEN-030-24
  XBEN-031-24 XBEN-032-24 XBEN-033-24 XBEN-034-24 XBEN-035-24 XBEN-036-24 XBEN-037-24 XBEN-038-24 XBEN-039-24 XBEN-040-24
  XBEN-041-24 XBEN-042-24 XBEN-043-24 XBEN-044-24 XBEN-045-24 XBEN-046-24 XBEN-047-24 XBEN-048-24 XBEN-049-24 XBEN-050-24
  XBEN-051-24 XBEN-052-24 XBEN-053-24 XBEN-054-24 XBEN-055-24 XBEN-056-24 XBEN-057-24 XBEN-058-24 XBEN-059-24 XBEN-060-24
  XBEN-061-24 XBEN-062-24 XBEN-063-24 XBEN-064-24 XBEN-065-24 XBEN-066-24 XBEN-067-24 XBEN-068-24 XBEN-069-24 XBEN-070-24
  XBEN-071-24 XBEN-072-24 XBEN-073-24 XBEN-074-24 XBEN-075-24 XBEN-076-24 XBEN-077-24 XBEN-078-24 XBEN-079-24 XBEN-080-24
  XBEN-081-24 XBEN-082-24 XBEN-083-24 XBEN-084-24 XBEN-085-24 XBEN-086-24 XBEN-087-24 XBEN-088-24 XBEN-089-24 XBEN-090-24
  XBEN-091-24 XBEN-092-24 XBEN-093-24 XBEN-094-24 XBEN-095-24 XBEN-096-24 XBEN-097-24 XBEN-098-24 XBEN-099-24 XBEN-100-24
  XBEN-101-24 XBEN-102-24 XBEN-103-24 XBEN-104-24
)

log() { local m="[$(date '+%H:%M:%S')] $*"; echo "$m"; echo "$m" >> "$LOG_FILE"; }
teardown() {
  local p="xbow_hc_${1,,}"; p="${p//-/_}"
  docker compose -f "$BENCHMARKS/$1/docker-compose.yml" -p "$p" down -v > /dev/null 2>&1 || true
}

> "$OUTPUT_FILE"; > "$LOG_FILE"
log "=========================================="
log "  Health Check — ${#ALL[@]} challenges"
log "  Started: $(date)"
log "=========================================="

healthy=0; unhealthy=0; idx=0; total="${#ALL[@]}"

for id in "${ALL[@]}"; do
  idx=$((idx+1))
  compose="$BENCHMARKS/$id/docker-compose.yml"
  project="xbow_hc_${id,,}"; project="${project//-/_}"

  if [[ ! -f "$compose" ]]; then
    log "[$idx/$total] $id — SKIP (no compose file)"; unhealthy=$((unhealthy+1)); continue
  fi

  log "[$idx/$total] $id — building..."
  teardown "$id"

  if ! docker compose -f "$compose" -p "$project" build --build-arg flag="healthcheck_test" > /dev/null 2>&1; then
    log "[$idx/$total] $id — UNHEALTHY (build failed)"; unhealthy=$((unhealthy+1)); continue
  fi

  docker compose -f "$compose" -p "$project" up -d > /dev/null 2>&1 || true
  sleep 12

  PORT=$(docker ps --filter "label=com.docker.compose.project=$project" \
    --format "{{.Ports}}" | grep -oP '0\.0\.0\.0:\K\d+' | head -1)

  if [[ -z "$PORT" ]]; then
    log "[$idx/$total] $id — UNHEALTHY (no exposed port)"; unhealthy=$((unhealthy+1)); teardown "$id"; continue
  fi

  attempts=0; ready=false
  while [[ $attempts -lt 15 ]]; do
    if curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://localhost:${PORT}" 2>/dev/null \
        | grep -qE "^(200|301|302|403|404)$"; then
      ready=true; break
    fi
    sleep 3; attempts=$((attempts+1))
  done

  if $ready; then
    log "[$idx/$total] $id — HEALTHY (port $PORT)"
    echo "$id" >> "$OUTPUT_FILE"; healthy=$((healthy+1))
  else
    log "[$idx/$total] $id — UNHEALTHY (no HTTP response on port $PORT)"; unhealthy=$((unhealthy+1))
  fi

  teardown "$id"
done

log "=========================================="
log "  Healthy: $healthy / $total"
log "  Unhealthy: $unhealthy / $total"
log "  IDs saved to: $OUTPUT_FILE"
log "  Done: $(date)"
log "=========================================="