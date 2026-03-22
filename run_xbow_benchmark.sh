#!/bin/bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$(dirname "$SCRIPT_DIR")"
PENTESTGPT_DIR="$PARENT_DIR/PentestGPT"
XBOW_DIR="$SCRIPT_DIR/xbow-validation-benchmarks/benchmarks"
HEALTHY_IDS_FILE="$SCRIPT_DIR/xbow_healthy_ids.txt"
LOGS_DIR="$SCRIPT_DIR/xbow-logs"
MANIFEST="$LOGS_DIR/flag_manifest.csv"
MAX_CHALLENGES="${1:-0}"
RUN_TIMEOUT=600
AGENT_CMD="docker compose run --rm pentestgpt --target %TARGET% --non-interactive --no-telemetry"
to_lower() { echo "$1" | tr '[:upper:]' '[:lower:]'; }
log() { echo "[$(date '+%H:%M:%S')] $*"; }
generate_flag() { if command -v uuidgen > /dev/null 2>&1; then echo "flag{$(uuidgen | tr -d '-' | tr '[:upper:]' '[:lower:]')}"; else echo "flag{$(cat /proc/sys/kernel/random/uuid | tr -d '-')}"; fi; }
get_compose_file() { echo "$XBOW_DIR/$1/docker-compose.yml"; }
get_project_name() { echo "xbow_run_$(to_lower "$1" | tr '-' '_')"; }
build_and_start() {
  local id="$1" flag="$2" compose_file project
  compose_file=$(get_compose_file "$id"); project=$(get_project_name "$id")
  log "[$id] Building..."
  if ! docker compose -f "$compose_file" -p "$project" build --build-arg flag="$flag" > "$LOGS_DIR/build_${id}.log" 2>&1; then log "[$id] Build failed"; return 1; fi
  log "[$id] Starting..."
  if ! docker compose -f "$compose_file" -p "$project" up -d > "$LOGS_DIR/start_${id}.log" 2>&1; then log "[$id] Start failed"; return 1; fi
  return 0
}
get_port() { local project; project=$(get_project_name "$1"); docker ps --filter "label=com.docker.compose.project=$project" --format "{{.Ports}}" | grep -oE '0\.0\.0\.0:[0-9]+' | head -1 | cut -d: -f2; }
wait_http() {
  local id="$1" port="$2" attempts=0
  log "[$id] Waiting for HTTP on port $port..."
  while [[ $attempts -lt 20 ]]; do
    if curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://localhost:${port}" 2>/dev/null | grep -qE "^(200|301|302|403|404)$"; then log "[$id] Ready"; return 0; fi
    sleep 3; attempts=$((attempts+1))
  done
  log "[$id] WARNING: not responding — proceeding anyway"; return 0
}
teardown() {
  local id="$1" compose_file project
  compose_file=$(get_compose_file "$id"); project=$(get_project_name "$id")
  log "[$id] Tearing down..."
  docker compose -f "$compose_file" -p "$project" down -v > /dev/null 2>&1 || true
}
run_agent() {
  local id="$1" port="$2" log_file="$3"
  local target="http://host.docker.internal:${port}"
  local cmd="${AGENT_CMD//%TARGET%/$target}"
  log "[$id] Agent starting → $target"
  cd "$PENTESTGPT_DIR"
  timeout "$RUN_TIMEOUT" bash -c "$cmd" 2>&1 | tee "$log_file"
  local rc="${PIPESTATUS[0]}"
  cd - > /dev/null
  if [[ "$rc" -eq 124 ]]; then log "[$id] Timed out"; elif [[ "$rc" -ne 0 ]]; then log "[$id] Exited $rc"; else log "[$id] Done"; fi
}
NEXT_ID="" NEXT_PORT="" NEXT_FLAG=""
try_next() {
  while [[ $NEXT_IDX -lt $TOTAL ]]; do
    local id="${CHALLENGES[$NEXT_IDX]}" flag; flag=$(generate_flag); NEXT_IDX=$((NEXT_IDX+1))
    if build_and_start "$id" "$flag"; then
      sleep 3; local port; port=$(get_port "$id")
      if [[ -n "$port" ]]; then NEXT_ID="$id"; NEXT_PORT="$port"; NEXT_FLAG="$flag"; return 0
      else log "[$id] No port — skipping"; teardown "$id"; fi
    fi
  done; return 1
}
score_results() {
  log ""; log "══════════════════════════════════════════"; log "  SCORING RESULTS"; log "══════════════════════════════════════════"
  local found=0 total=0
  echo "challenge_id,flag,flag_found,log_file" > "$LOGS_DIR/score_results.csv"
  while IFS=, read -r id flag; do
    [[ "$id" == "challenge_id" ]] && continue
    local lf="$LOGS_DIR/${id}.log"; total=$((total+1))
    if [[ -f "$lf" ]] && grep -qF "$flag" "$lf"; then log "  ✓ $id — FLAG FOUND"; echo "$id,$flag,YES,$lf" >> "$LOGS_DIR/score_results.csv"; found=$((found+1))
    else log "  ✗ $id — not found"; echo "$id,$flag,NO,$lf" >> "$LOGS_DIR/score_results.csv"; fi
  done < "$MANIFEST"
  log ""; log "Score: $found / $total"; log "Results → $LOGS_DIR/score_results.csv"; log "══════════════════════════════════════════"
}
main() {
  log "══════════════════════════════════════════"; log "  XBOW Benchmark Runner"; log "  Benchmarking dir: $SCRIPT_DIR"; log "  PentestGPT dir:   $PENTESTGPT_DIR"; log "  Started: $(date)"; log "══════════════════════════════════════════"
  [[ ! -d "$PENTESTGPT_DIR" ]] && { log "ERROR: PentestGPT not found at $PENTESTGPT_DIR"; exit 1; }
  [[ ! -d "$XBOW_DIR" ]] && { log "ERROR: XBOW dir not found at $XBOW_DIR"; exit 1; }
  [[ ! -f "$HEALTHY_IDS_FILE" ]] && { log "ERROR: $HEALTHY_IDS_FILE not found — run xbow_setup.sh first"; exit 1; }
  mkdir -p "$LOGS_DIR"
  CHALLENGES=()
  while IFS= read -r line || [[ -n "$line" ]]; do [[ -z "$line" ]] && continue; CHALLENGES+=("$line"); done < "$HEALTHY_IDS_FILE"
  TOTAL="${#CHALLENGES[@]}"
  if [[ "$MAX_CHALLENGES" -gt 0 && "$MAX_CHALLENGES" -lt "$TOTAL" ]]; then CHALLENGES=("${CHALLENGES[@]:0:$MAX_CHALLENGES}"); TOTAL="$MAX_CHALLENGES"; fi
  log "Running $TOTAL challenges"
  echo "challenge_id,flag" > "$MANIFEST"
  NEXT_IDX=0; S1_ID="" S1_PORT="" S1_FLAG="" S2_ID="" S2_PORT="" S2_FLAG="" S2_PID=""
  SLOT2_FILE="$LOGS_DIR/.slot2_result"
  log "Bootstrap: building slot 1..."
  if ! try_next; then log "ERROR: Could not build any challenge — aborting"; exit 1; fi
  S1_ID="$NEXT_ID"; S1_PORT="$NEXT_PORT"; S1_FLAG="$NEXT_FLAG"
  wait_http "$S1_ID" "$S1_PORT"; echo "$S1_ID,$S1_FLAG" >> "$MANIFEST"; log "Slot 1 ready: $S1_ID on port $S1_PORT"
  if [[ $NEXT_IDX -lt $TOTAL ]]; then
    local _id="${CHALLENGES[$NEXT_IDX]}" _flag; _flag=$(generate_flag); NEXT_IDX=$((NEXT_IDX+1))
    S2_ID="$_id"; S2_FLAG="$_flag"; rm -f "$SLOT2_FILE"; log "Bootstrap: background building slot 2 → $_id"
    ( if build_and_start "$_id" "$_flag"; then sleep 3; local _port; _port=$(get_port "$_id")
      if [[ -n "$_port" ]]; then wait_http "$_id" "$_port"; echo "$_id|$_port|$_flag" > "$SLOT2_FILE"; echo "$_id,$_flag" >> "$MANIFEST"
      else echo "FAILED" > "$SLOT2_FILE"; teardown "$_id"; fi
      else echo "FAILED" > "$SLOT2_FILE"; fi ) &
    S2_PID=$!
  fi
  while [[ -n "$S1_ID" ]]; do
    local cur_id="$S1_ID" cur_port="$S1_PORT"; S1_ID="" S1_PORT="" S1_FLAG=""
    log ""; log "── Testing: $cur_id (port $cur_port) ──"
    if [[ -n "$S2_PID" ]]; then
      log "Waiting for background build of $S2_ID..."; wait "$S2_PID" || true; S2_PID=""
      if [[ -f "$SLOT2_FILE" ]]; then
        local result; result=$(cat "$SLOT2_FILE"); rm -f "$SLOT2_FILE"
        if [[ "$result" != "FAILED" ]]; then
          S1_ID=$(echo "$result"|cut -d'|' -f1); S1_PORT=$(echo "$result"|cut -d'|' -f2); S1_FLAG=$(echo "$result"|cut -d'|' -f3)
          log "Slot 1 ready: $S1_ID on port $S1_PORT"
        else
          log "Slot 2 failed for $S2_ID — trying next synchronously"
          if try_next; then S1_ID="$NEXT_ID"; S1_PORT="$NEXT_PORT"; S1_FLAG="$NEXT_FLAG"; wait_http "$S1_ID" "$S1_PORT"; echo "$S1_ID,$S1_FLAG" >> "$MANIFEST"; fi
        fi
      fi
      S2_ID="" S2_FLAG=""
    fi
    if [[ $NEXT_IDX -lt $TOTAL ]]; then
      local _id="${CHALLENGES[$NEXT_IDX]}" _flag; _flag=$(generate_flag); NEXT_IDX=$((NEXT_IDX+1))
      S2_ID="$_id"; S2_FLAG="$_flag"; rm -f "$SLOT2_FILE"; log "Background: building slot 2 → $_id"
      ( if build_and_start "$_id" "$_flag"; then sleep 3; local _port; _port=$(get_port "$_id")
        if [[ -n "$_port" ]]; then wait_http "$_id" "$_port"; echo "$_id|$_port|$_flag" > "$SLOT2_FILE"; echo "$_id,$_flag" >> "$MANIFEST"
        else echo "FAILED" > "$SLOT2_FILE"; teardown "$_id"; fi
        else echo "FAILED" > "$SLOT2_FILE"; fi ) &
      S2_PID=$!
    fi
    run_agent "$cur_id" "$cur_port" "$LOGS_DIR/${cur_id}.log"
    teardown "$cur_id"
  done
  [[ -n "$S1_ID" ]] && teardown "$S1_ID"; [[ -n "$S2_ID" ]] && teardown "$S2_ID"
  score_results
  log ""; log "Done. Logs: $LOGS_DIR | Manifest: $MANIFEST | Scores: $LOGS_DIR/score_results.csv"
}
main "$@"
