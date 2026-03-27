#!/bin/bash
# gsd-queue-runner.sh — Autonomous GSD queue manager
# Runs in tmux session 'gsd-queue' on the VM.
# Manages concurrent Claude Code sessions across project repos.
#
# Config:   ~/.gsd-queue.conf   (WIP_LIMIT, thresholds)
# Priority: ~/.gsd-priority     (repo names, one per line, highest first)
# State:    ~/.gsd-queue-state   (written each cycle, read by 'dev status')
# Log:      ~/logs/gsd-queue.log

set -uo pipefail

# ── Singleton lock ───────────────────────────────────────────────
LOCK_FILE="$HOME/.gsd-queue.lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "Another queue runner is already running (lock: $LOCK_FILE)"
  exit 1
fi
echo $$ > "$LOCK_FILE"

# ── Environment ──────────────────────────────────────────────────
export FNM_PATH="$HOME/.local/share/fnm"
export PATH="$FNM_PATH:$HOME/.pyenv/bin:$HOME/.local/bin:$HOME/bin:$PATH"
eval "$(fnm env 2>/dev/null)"
eval "$(pyenv init - 2>/dev/null)"

LOG="$HOME/logs/gsd-queue.log"
STATE_FILE="$HOME/.gsd-queue-state"
CONF_FILE="$HOME/.gsd-queue.conf"
PRIORITY_FILE="$HOME/.gsd-priority"

mkdir -p "$HOME/logs"

# ── Config (defaults) ────────────────────────────────────────────
WIP_LIMIT=2
POLL_INTERVAL=30
RATE_LIMIT_COOLDOWN=900    # 15 minutes
MEMORY_WARN=85             # don't start new sessions above this
MEMORY_CRIT=90             # pause lowest priority above this
MIN_RUN_SECONDS=60         # exit faster than this = rate limited
HANG_TIMEOUT=600           # 10 minutes no output change = hung
MAX_SESSION_RUNTIME=14400  # 4 hours max per session launch
MAX_RETRIES=3              # consecutive errors before marking failed
RESCAN_INTERVAL=300        # re-scan repos every 5 minutes
MAX_LOG_SIZE=$((10 * 1024 * 1024))  # 10MB log rotation

NTFY_TOPIC="mds-cloud-dev-791a67ce61aaa1fe"

[ -f "$CONF_FILE" ] && source "$CONF_FILE"

# ── Notifications ────────────────────────────────────────────────
notify() {
  local msg="$1"
  local tag="${2:-robot_face}"
  curl -s --max-time 5 --connect-timeout 3 \
    -H "Title: cloud-dev" \
    -H "Tags: $tag" \
    --data-raw "$msg" \
    "https://ntfy.sh/$NTFY_TOPIC" > /dev/null 2>&1 || true
}

# ── State arrays ─────────────────────────────────────────────────
declare -A REPO_STATUS            # session -> queued|running|rate-limited|done|skipped|error|failed
declare -A REPO_PATH              # session -> /abs/path
declare -A REPO_PHASE             # session -> phase number
declare -A REPO_START_TIME        # session -> epoch when claude started
declare -A REPO_RETRY_AFTER       # session -> epoch for retry
declare -A REPO_ERROR_COUNT       # session -> consecutive error count
declare -A REPO_LAST_OUTPUT_HASH  # session -> md5 of last captured pane
declare -A REPO_LAST_CHANGE_TIME  # session -> epoch of last output change
QUEUE_ORDER=()                    # ordered list of session names
SHUTTING_DOWN=false
LAST_RESCAN=0

# ── Graceful shutdown ────────────────────────────────────────────
graceful_shutdown() {
  SHUTTING_DOWN=true
  log "=== Graceful shutdown initiated ==="
  for session in "${QUEUE_ORDER[@]}"; do
    if [ "${REPO_STATUS[$session]:-}" = "running" ]; then
      log "Stopping: $session"
      tmux send-keys -t "$session:main.0" C-c C-c 2>/dev/null
      sleep 2
      tmux send-keys -t "$session:main.0" "/exit" Enter 2>/dev/null
      REPO_STATUS[$session]="queued"
    fi
  done
  write_state
  notify "Queue runner stopped gracefully" "stop_sign"
  log "=== GSD Queue Runner stopped ==="
  exit 0
}

trap graceful_shutdown SIGTERM SIGINT

# ── Logging ──────────────────────────────────────────────────────
log() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  echo "$msg" | tee -a "$LOG"
}

rotate_log() {
  local size
  size=$(stat -c%s "$LOG" 2>/dev/null || echo 0)
  if [ "$size" -gt "$MAX_LOG_SIZE" ]; then
    mv "$LOG" "$LOG.1"
    log "Log rotated (was ${size} bytes)"
  fi
}

# ── Helpers ──────────────────────────────────────────────────────

get_memory_percent() {
  awk '/MemTotal/{t=$2} /MemAvailable/{a=$2} END{printf "%d", (t-a)*100/t}' /proc/meminfo
}

# Check if claude is running in a tmux pane
is_claude_running() {
  local session=$1
  local pane_pid
  pane_pid=$(tmux display-message -t "$session:main.0" -p "#{pane_pid}" 2>/dev/null) || return 1
  [ -z "$pane_pid" ] && return 1
  pgrep -P "$pane_pid" -f "claude" > /dev/null 2>&1
}

# Wait for a shell prompt in the pane (after killing previous process)
wait_for_shell() {
  local session=$1
  local max_wait=15
  for ((w = 0; w < max_wait; w++)); do
    local content
    content=$(tmux capture-pane -t "$session:main.0" -p 2>/dev/null | tail -3)
    if echo "$content" | grep -qE '^\s*\$\s*$|^\s*mds@'; then
      return 0
    fi
    sleep 1
  done
  return 1
}

# Wait for Claude to be ready (showing its input prompt)
wait_for_claude_ready() {
  local session=$1
  local max_wait=30
  for ((w = 0; w < max_wait; w++)); do
    local content
    content=$(tmux capture-pane -t "$session:main.0" -p 2>/dev/null | tail -5)
    # Claude shows various ready indicators
    if echo "$content" | grep -qiE 'Type a message|What would you like|claude>|> $|tips:'; then
      return 0
    fi
    sleep 1
  done
  return 1
}

# Get next incomplete phase for a repo
get_repo_gsd_status() {
  local path=$1

  local phases_dir="$path/.planning/phases"
  if [ ! -d "$phases_dir" ]; then
    phases_dir=$(find "$path/.planning/milestones" -maxdepth 2 -name "*phases" -type d 2>/dev/null | head -1)
  fi
  [ -z "$phases_dir" ] && echo "done" && return

  for phase_dir in $(ls -d "$phases_dir"/*/ 2>/dev/null | sort); do
    local phase_num
    phase_num=$(basename "$phase_dir" | grep -oP '^\d+')
    [ -z "$phase_num" ] && continue

    local has_verify has_context has_plans has_summary
    has_verify=$(find "$phase_dir" -name "*VERIFICATION*" 2>/dev/null | head -1)
    [ -n "$has_verify" ] && continue

    has_context=$(find "$phase_dir" -name "*CONTEXT*" 2>/dev/null | head -1)
    has_plans=$(find "$phase_dir" -name "*PLAN*" 2>/dev/null | head -1)
    has_summary=$(find "$phase_dir" -name "*SUMMARY*" 2>/dev/null | head -1)

    if [ -z "$has_context" ]; then
      echo "discussion:$phase_num"
    elif [ -z "$has_plans" ]; then
      echo "planning:$phase_num"
    elif [ -z "$has_summary" ]; then
      echo "execution:$phase_num"
    else
      echo "verify:$phase_num"
    fi
    return
  done
  echo "done"
}

# Get stripped pane content (no ANSI codes) for comparison
get_pane_content() {
  local session=$1
  tmux capture-pane -t "$session:main.0" -p 2>/dev/null | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g'
}

# ── Scan and build queue ─────────────────────────────────────────

scan_and_build_queue() {
  local preserve_running=false
  [ ${#QUEUE_ORDER[@]} -gt 0 ] && preserve_running=true

  # Save running/rate-limited state before rescan
  declare -A saved_status
  if $preserve_running; then
    for session in "${QUEUE_ORDER[@]}"; do
      local st="${REPO_STATUS[$session]:-}"
      if [ "$st" = "running" ] || [ "$st" = "rate-limited" ] || [ "$st" = "error" ]; then
        saved_status[$session]="$st"
      fi
    done
  fi

  QUEUE_ORDER=()

  declare -A candidates
  for s in $(tmux ls -F "#{session_name}" 2>/dev/null); do
    [ "$s" = "gsd-queue" ] && continue
    local path
    path=$(tmux display-message -t "$s:shell" -p "#{pane_current_path}" 2>/dev/null || \
           tmux display-message -t "$s:main.0" -p "#{pane_current_path}" 2>/dev/null)
    [ -z "$path" ] && continue
    [ ! -d "$path/.planning" ] && continue

    # If this session was already running/rate-limited, preserve its state
    if [ -n "${saved_status[$s]+x}" ]; then
      REPO_PATH[$s]="$path"
      candidates[$s]="$path"
      continue
    fi

    local status_info
    status_info=$(get_repo_gsd_status "$path")
    local status="${status_info%%:*}"
    local phase="${status_info##*:}"

    REPO_PATH[$s]="$path"

    case "$status" in
      discussion)
        REPO_STATUS[$s]="skipped"
        REPO_PHASE[$s]="$phase"
        ;;
      planning|execution)
        REPO_STATUS[$s]="queued"
        REPO_PHASE[$s]="$phase"
        candidates[$s]="$path"
        ;;
      verify)
        REPO_STATUS[$s]="skipped"
        REPO_PHASE[$s]="$phase"
        ;;
      done)
        REPO_STATUS[$s]="done"
        REPO_PHASE[$s]="0"
        ;;
    esac
  done

  # Sort by priority file, then alphabetical
  if [ -f "$PRIORITY_FILE" ]; then
    while IFS= read -r name; do
      name=$(echo "$name" | tr -d '[:space:]')
      [ -z "$name" ] && continue
      [ -n "${candidates[$name]+x}" ] && QUEUE_ORDER+=("$name")
    done < "$PRIORITY_FILE"
  fi

  for name in $(echo "${!candidates[@]}" | tr ' ' '\n' | sort); do
    local already=false
    for q in "${QUEUE_ORDER[@]}"; do
      [ "$q" = "$name" ] && already=true && break
    done
    $already || QUEUE_ORDER+=("$name")
  done
}

# ── Start Claude in a repo ───────────────────────────────────────

start_claude_in_repo() {
  local session=$1
  log "Starting Claude in $session (phase ${REPO_PHASE[$session]})"

  tmux select-window -t "$session:main" 2>/dev/null
  tmux select-pane -t "$session:main.0" 2>/dev/null

  # Kill any existing process and wait for clean shell
  tmux send-keys -t "$session:main.0" C-c C-c 2>/dev/null
  sleep 1
  tmux send-keys -t "$session:main.0" C-c 2>/dev/null

  # Clean stale git locks from prior crashes
  tmux send-keys -t "$session:main.0" "rm -f .git/index.lock 2>/dev/null" Enter
  sleep 1

  if ! wait_for_shell "$session"; then
    log "ERROR: $session — pane not at shell prompt, skipping"
    REPO_STATUS[$session]="error"
    REPO_ERROR_COUNT[$session]=$(( ${REPO_ERROR_COUNT[$session]:-0} + 1 ))
    return
  fi

  # Start Claude
  tmux send-keys -t "$session:main.0" \
    "claude --dangerously-skip-permissions" Enter

  if ! wait_for_claude_ready "$session"; then
    log "ERROR: $session — Claude failed to start within 30s"
    # Capture what's on screen for debugging
    get_pane_content "$session" | tail -10 >> "$LOG"
    REPO_STATUS[$session]="error"
    REPO_ERROR_COUNT[$session]=$(( ${REPO_ERROR_COUNT[$session]:-0} + 1 ))
    REPO_RETRY_AFTER[$session]=$(( $(date +%s) + 60 ))
    notify "$session failed to start Claude" "x"
    return
  fi

  # Send autonomous command
  tmux send-keys -t "$session:main.0" "/gsd:autonomous" Enter

  # Verify the command was received (check for autonomous banner)
  sleep 10
  local banner
  banner=$(get_pane_content "$session")
  if ! echo "$banner" | grep -qiE "autonomous|AUTONOMOUS|phase|GSD"; then
    log "WARNING: $session — /gsd:autonomous may not have started, retrying"
    tmux send-keys -t "$session:main.0" "/gsd:autonomous" Enter
    sleep 10
    banner=$(get_pane_content "$session")
    if ! echo "$banner" | grep -qiE "autonomous|AUTONOMOUS|phase|GSD"; then
      log "ERROR: $session — autonomous command failed to start"
      get_pane_content "$session" | tail -10 >> "$LOG"
      REPO_STATUS[$session]="error"
      REPO_ERROR_COUNT[$session]=$(( ${REPO_ERROR_COUNT[$session]:-0} + 1 ))
      notify "$session autonomous command failed" "x"
      return
    fi
  fi

  REPO_STATUS[$session]="running"
  REPO_START_TIME[$session]=$(date +%s)
  REPO_ERROR_COUNT[$session]=0
  REPO_LAST_CHANGE_TIME[$session]=$(date +%s)
  REPO_LAST_OUTPUT_HASH[$session]=""

  notify "$session started (phase ${REPO_PHASE[$session]})" "arrow_forward"
}

# ── Handle session completion ────────────────────────────────────

handle_completion() {
  local session=$1
  local start_time="${REPO_START_TIME[$session]:-0}"
  local now
  now=$(date +%s)
  local runtime=$((now - start_time))

  # Capture exit context for debugging
  local last_output
  last_output=$(get_pane_content "$session" | tail -20)
  echo "$last_output" >> "$LOG"

  # Check for error indicators
  local is_crash=false
  if echo "$last_output" | grep -qiE 'error|panic|killed|segfault|ENOMEM|OOM|Traceback|fatal|SIGKILL'; then
    is_crash=true
  fi

  local error_count="${REPO_ERROR_COUNT[$session]:-0}"

  if [ "$runtime" -lt "$MIN_RUN_SECONDS" ]; then
    if $is_crash; then
      error_count=$((error_count + 1))
      REPO_ERROR_COUNT[$session]=$error_count
      log "CRASHED: $session after ${runtime}s (error $error_count/$MAX_RETRIES)"
      if [ "$error_count" -ge "$MAX_RETRIES" ]; then
        REPO_STATUS[$session]="failed"
        notify "$session failed after $MAX_RETRIES crashes — needs manual attention" "sos"
      else
        REPO_STATUS[$session]="error"
        REPO_RETRY_AFTER[$session]=$((now + 60 * error_count))
        notify "$session crashed — retry $error_count/$MAX_RETRIES in $((60 * error_count))s" "x"
      fi
    else
      log "RATE LIMITED: $session exited after ${runtime}s"
      REPO_STATUS[$session]="rate-limited"
      REPO_RETRY_AFTER[$session]=$((now + RATE_LIMIT_COOLDOWN))
      notify "$session rate limited — retrying in 15m" "pause_button"
    fi
  elif $is_crash; then
    error_count=$((error_count + 1))
    REPO_ERROR_COUNT[$session]=$error_count
    log "CRASHED: $session after ${runtime}s (error $error_count/$MAX_RETRIES)"
    if [ "$error_count" -ge "$MAX_RETRIES" ]; then
      REPO_STATUS[$session]="failed"
      notify "$session failed after $MAX_RETRIES crashes — needs manual attention" "sos"
    else
      REPO_STATUS[$session]="error"
      REPO_RETRY_AFTER[$session]=$((now + 120))
      notify "$session crashed after ${runtime}s — retrying" "x"
    fi
  else
    log "COMPLETED: $session (ran for ${runtime}s)"
    notify "$session completed phase ${REPO_PHASE[$session]}" "white_check_mark"
    REPO_ERROR_COUNT[$session]=0

    # Re-check if there's more work
    local new_status
    new_status=$(get_repo_gsd_status "${REPO_PATH[$session]}")
    local status="${new_status%%:*}"
    local phase="${new_status##*:}"

    case "$status" in
      planning|execution)
        log "  $session has more autonomous work (phase $phase) — re-queuing"
        REPO_STATUS[$session]="queued"
        REPO_PHASE[$session]="$phase"
        ;;
      *)
        REPO_STATUS[$session]="done"
        ;;
    esac
  fi
}

# ── Hang detection ───────────────────────────────────────────────

check_for_hangs() {
  local now
  now=$(date +%s)

  for session in "${QUEUE_ORDER[@]}"; do
    [ "${REPO_STATUS[$session]}" != "running" ] && continue

    # Check max runtime
    local start="${REPO_START_TIME[$session]:-0}"
    local elapsed=$((now - start))
    if [ "$elapsed" -ge "$MAX_SESSION_RUNTIME" ]; then
      log "TIMEOUT: $session running for ${elapsed}s (max ${MAX_SESSION_RUNTIME}s)"
      pause_session "$session"
      REPO_STATUS[$session]="error"
      REPO_ERROR_COUNT[$session]=$(( ${REPO_ERROR_COUNT[$session]:-0} + 1 ))
      notify "$session timed out after $((elapsed / 3600))h" "hourglass"
      continue
    fi

    # Check output staleness
    local content_hash
    content_hash=$(get_pane_content "$session" | md5sum | cut -d' ' -f1)

    local prev_hash="${REPO_LAST_OUTPUT_HASH[$session]:-}"
    if [ "$content_hash" != "$prev_hash" ]; then
      REPO_LAST_OUTPUT_HASH[$session]="$content_hash"
      REPO_LAST_CHANGE_TIME[$session]=$now
    else
      local last_change="${REPO_LAST_CHANGE_TIME[$session]:-$now}"
      local stale=$((now - last_change))
      if [ "$stale" -ge "$HANG_TIMEOUT" ]; then
        log "HUNG: $session — no output change for ${stale}s"
        get_pane_content "$session" | tail -10 >> "$LOG"

        # Check if stuck on a question prompt
        local content
        content=$(get_pane_content "$session")
        if echo "$content" | grep -qiE 'AskUser|select.*option|Enter.*choice|\?.*\[|y/n|Y/N'; then
          log "  Detected interactive prompt — killing session"
        fi

        pause_session "$session"
        REPO_STATUS[$session]="error"
        REPO_ERROR_COUNT[$session]=$(( ${REPO_ERROR_COUNT[$session]:-0} + 1 ))
        notify "$session hung (no output for $((stale / 60))m) — restarting" "warning"
      fi
    fi
  done
}

# ── Pause a running session ──────────────────────────────────────

pause_session() {
  local session=$1
  log "PAUSING: $session"
  tmux send-keys -t "$session:main.0" C-c C-c 2>/dev/null
  sleep 2
  tmux send-keys -t "$session:main.0" "/exit" Enter 2>/dev/null
  sleep 2
  # If still running, force kill
  if is_claude_running "$session"; then
    local pane_pid
    pane_pid=$(tmux display-message -t "$session:main.0" -p "#{pane_pid}" 2>/dev/null)
    if [ -n "$pane_pid" ]; then
      pkill -P "$pane_pid" -f "claude" 2>/dev/null || true
    fi
  fi
}

# ── Write state for 'dev status' ─────────────────────────────────

write_state() {
  local now
  now=$(date '+%Y-%m-%d %H:%M:%S')
  local mem
  mem=$(get_memory_percent)
  local running=0 queued=0 done_count=0 rate_limited=0 skipped=0 errors=0 failed=0

  local tmp
  tmp=$(mktemp)
  {
    echo "updated=$now"
    echo "memory=${mem}%"
    echo "wip_limit=$WIP_LIMIT"
    echo ""

    for session in "${QUEUE_ORDER[@]}"; do
      local st="${REPO_STATUS[$session]}"
      echo "$session|$st|${REPO_PHASE[$session]:-0}"
      case "$st" in
        running) ((running++)) ;;
        queued) ((queued++)) ;;
        done) ((done_count++)) ;;
        rate-limited) ((rate_limited++)) ;;
        error) ((errors++)) ;;
        failed) ((failed++)) ;;
      esac
    done

    for session in "${!REPO_STATUS[@]}"; do
      if [ "${REPO_STATUS[$session]}" = "skipped" ]; then
        echo "$session|skipped|${REPO_PHASE[$session]:-0}"
        ((skipped++))
      fi
    done

    echo ""
    echo "running=$running"
    echo "queued=$queued"
    echo "done=$done_count"
    echo "rate_limited=$rate_limited"
    echo "errors=$errors"
    echo "failed=$failed"
    echo "skipped=$skipped"
  } > "$tmp"

  mv "$tmp" "$STATE_FILE"
}

# ── Main loop ────────────────────────────────────────────────────

main() {
  log "=== GSD Queue Runner started (WIP=$WIP_LIMIT) ==="
  notify "Queue runner started (WIP=$WIP_LIMIT)" "rocket"

  scan_and_build_queue
  LAST_RESCAN=$(date +%s)

  if [ ${#QUEUE_ORDER[@]} -eq 0 ]; then
    log "No repos need autonomous work. Exiting."
    notify "No repos need autonomous work" "shrug"
    write_state
    return
  fi

  log "Queue (${#QUEUE_ORDER[@]} repos): ${QUEUE_ORDER[*]}"

  while true; do
    $SHUTTING_DOWN && break

    rotate_log

    # ── Check completions ────────────────────────────────────────
    for session in "${QUEUE_ORDER[@]}"; do
      if [ "${REPO_STATUS[$session]}" = "running" ]; then
        if ! is_claude_running "$session"; then
          handle_completion "$session"
        fi
      fi
    done

    # ── Check for hangs ──────────────────────────────────────────
    check_for_hangs

    # ── Count running ────────────────────────────────────────────
    local running=0
    for session in "${QUEUE_ORDER[@]}"; do
      [ "${REPO_STATUS[$session]}" = "running" ] && ((running++))
    done

    # ── Memory safety ────────────────────────────────────────────
    local mem_pct
    mem_pct=$(get_memory_percent)

    if [ "$mem_pct" -ge "$MEMORY_CRIT" ] && [ "$running" -ge 2 ]; then
      for ((i=${#QUEUE_ORDER[@]}-1; i>=0; i--)); do
        if [ "${REPO_STATUS[${QUEUE_ORDER[$i]}]}" = "running" ]; then
          log "MEMORY CRITICAL: ${mem_pct}% — pausing ${QUEUE_ORDER[$i]}"
          notify "${QUEUE_ORDER[$i]} paused — memory at ${mem_pct}%" "warning"
          pause_session "${QUEUE_ORDER[$i]}"
          REPO_STATUS[${QUEUE_ORDER[$i]}]="queued"
          ((running--))
          break
        fi
      done
    fi

    # ── Start queued sessions ────────────────────────────────────
    if [ "$running" -lt "$WIP_LIMIT" ] && [ "$mem_pct" -lt "$MEMORY_WARN" ]; then
      for session in "${QUEUE_ORDER[@]}"; do
        $SHUTTING_DOWN && break
        [ "$running" -ge "$WIP_LIMIT" ] && break
        if [ "${REPO_STATUS[$session]}" = "queued" ]; then
          start_claude_in_repo "$session"
          [ "${REPO_STATUS[$session]}" = "running" ] && ((running++))
        fi
      done
    fi

    # ── Retry errored/rate-limited sessions ──────────────────────
    local now_epoch
    now_epoch=$(date +%s)
    for session in "${QUEUE_ORDER[@]}"; do
      $SHUTTING_DOWN && break
      local st="${REPO_STATUS[$session]}"
      if [ "$st" = "rate-limited" ] || [ "$st" = "error" ]; then
        local retry="${REPO_RETRY_AFTER[$session]:-0}"
        if [ "$now_epoch" -ge "$retry" ] && [ "$running" -lt "$WIP_LIMIT" ] && [ "$mem_pct" -lt "$MEMORY_WARN" ]; then
          log "Retrying: $session ($st)"
          REPO_STATUS[$session]="queued"
          start_claude_in_repo "$session"
          [ "${REPO_STATUS[$session]}" = "running" ] && ((running++))
          break
        fi
      fi
    done

    # ── Periodic re-scan ─────────────────────────────────────────
    if [ $((now_epoch - LAST_RESCAN)) -ge "$RESCAN_INTERVAL" ]; then
      log "Periodic re-scan..."
      scan_and_build_queue
      LAST_RESCAN=$now_epoch
    fi

    # ── Check if all work is done ────────────────────────────────
    local all_finished=true
    for session in "${QUEUE_ORDER[@]}"; do
      local st="${REPO_STATUS[$session]}"
      if [ "$st" = "queued" ] || [ "$st" = "running" ]; then
        all_finished=false
        break
      fi
    done

    if $all_finished; then
      local any_retryable=false
      for session in "${QUEUE_ORDER[@]}"; do
        local st="${REPO_STATUS[$session]}"
        if [ "$st" = "rate-limited" ] || [ "$st" = "error" ]; then
          any_retryable=true
          break
        fi
      done
      if ! $any_retryable; then
        # Check for failed sessions
        local any_failed=false
        for session in "${QUEUE_ORDER[@]}"; do
          [ "${REPO_STATUS[$session]}" = "failed" ] && any_failed=true && break
        done
        if $any_failed; then
          log "=== Queue finished with failures ==="
          notify "Queue finished — some repos failed and need manual attention" "warning"
        else
          log "=== All repos complete ==="
          notify "All repos complete — run 'dev verify' to review" "tada"
        fi
        write_state
        break
      fi
    fi

    write_state
    sleep "$POLL_INTERVAL"
  done

  log "=== GSD Queue Runner finished ==="
}

main
