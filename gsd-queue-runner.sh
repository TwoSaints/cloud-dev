#!/bin/bash
# gsd-queue-runner.sh — Autonomous GSD queue manager
# Runs in tmux session 'gsd-queue' on the VM.
# Manages concurrent Claude Code sessions across project repos.
#
# Config:  ~/.gsd-queue.conf   (WIP_LIMIT, thresholds)
# Priority: ~/.gsd-priority    (repo names, one per line, highest first)
# State:   ~/.gsd-queue-state  (written each cycle, read by 'dev status')
# Log:     ~/logs/gsd-queue.log

set -uo pipefail

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
RATE_LIMIT_COOLDOWN=900   # 15 minutes
MEMORY_WARN=85            # don't start new sessions above this
MEMORY_CRIT=90            # pause lowest priority above this
MIN_RUN_SECONDS=60        # exit faster than this = rate limited

NTFY_TOPIC="mds-cloud-dev-791a67ce61aaa1fe"

[ -f "$CONF_FILE" ] && source "$CONF_FILE"

# ── Notifications ────────────────────────────────────────────────
notify() {
  local msg="$1"
  local tag="${2:-robot_face}"
  curl -s \
    -H "Title: cloud-dev" \
    -H "Tags: $tag" \
    --data-raw "$msg" \
    "https://ntfy.sh/$NTFY_TOPIC" > /dev/null 2>&1 || true
}

# ── State arrays ─────────────────────────────────────────────────
declare -A REPO_STATUS       # session -> queued|running|rate-limited|done|skipped
declare -A REPO_PATH         # session -> /abs/path
declare -A REPO_PHASE        # session -> phase number
declare -A REPO_START_TIME   # session -> epoch when claude started
declare -A REPO_RETRY_AFTER  # session -> epoch for rate-limit retry
QUEUE_ORDER=()               # ordered list of session names

# ── Logging ──────────────────────────────────────────────────────
log() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  echo "$msg" | tee -a "$LOG"
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

# Get next incomplete phase for a repo
# Output: "status:phase_num" (discussion|planning|execution|verify|done)
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
    [ -n "$has_verify" ] && continue   # phase complete, check next

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

# ── Scan and build queue ─────────────────────────────────────────

scan_and_build_queue() {
  QUEUE_ORDER=()

  # Collect repos with .planning/ that need autonomous work
  declare -A candidates   # session -> path
  for s in $(tmux ls -F "#{session_name}" 2>/dev/null); do
    [ "$s" = "gsd-queue" ] && continue
    local path
    path=$(tmux display-message -t "$s:shell" -p "#{pane_current_path}" 2>/dev/null || \
           tmux display-message -t "$s:main.0" -p "#{pane_current_path}" 2>/dev/null)
    [ -z "$path" ] && continue
    [ ! -d "$path/.planning" ] && continue

    local status_info
    status_info=$(get_repo_gsd_status "$path")
    local status="${status_info%%:*}"
    local phase="${status_info##*:}"

    REPO_PATH[$s]="$path"

    case "$status" in
      discussion)
        # Needs human input — skip (user should run 'dev plan')
        REPO_STATUS[$s]="skipped"
        REPO_PHASE[$s]="$phase"
        log "  $s: needs discussion (phase $phase) — skipping"
        ;;
      planning|execution)
        # Can run autonomously
        REPO_STATUS[$s]="queued"
        REPO_PHASE[$s]="$phase"
        candidates[$s]="$path"
        ;;
      verify)
        # Needs human review
        REPO_STATUS[$s]="skipped"
        REPO_PHASE[$s]="$phase"
        log "  $s: needs verification (phase $phase) — skipping"
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

  # Add remaining candidates alphabetically
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

  # Ensure we're on the main window, claude pane
  tmux select-window -t "$session:main" 2>/dev/null
  tmux select-pane -t "$session:main.0" 2>/dev/null

  # Kill any existing process in the claude pane
  tmux send-keys -t "$session:main.0" C-c C-c 2>/dev/null
  sleep 1

  # Start Claude
  tmux send-keys -t "$session:main.0" \
    "claude --dangerously-skip-permissions" Enter
  sleep 5

  # Send autonomous command
  tmux send-keys -t "$session:main.0" "/gsd:autonomous" Enter

  REPO_STATUS[$session]="running"
  REPO_START_TIME[$session]=$(date +%s)

  notify "$session started (phase ${REPO_PHASE[$session]})" "arrow_forward"
}

# ── Handle session completion ────────────────────────────────────

handle_completion() {
  local session=$1
  local start_time="${REPO_START_TIME[$session]:-0}"
  local now
  now=$(date +%s)
  local runtime=$((now - start_time))

  # Capture last few lines of output for debugging
  tmux capture-pane -t "$session:main.0" -p 2>/dev/null | tail -5 >> "$LOG"

  if [ "$runtime" -lt "$MIN_RUN_SECONDS" ]; then
    log "RATE LIMITED: $session exited after ${runtime}s (< ${MIN_RUN_SECONDS}s)"
    REPO_STATUS[$session]="rate-limited"
    REPO_RETRY_AFTER[$session]=$((now + RATE_LIMIT_COOLDOWN))
    notify "$session rate limited — retrying in 15m" "pause_button"
  else
    log "COMPLETED: $session (ran for ${runtime}s)"
    notify "$session completed phase ${REPO_PHASE[$session]}" "white_check_mark"

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

# ── Pause a running session ──────────────────────────────────────

pause_session() {
  local session=$1
  log "PAUSING: $session (memory pressure)"
  notify "$session paused — memory at $(get_memory_percent)%" "warning"
  tmux send-keys -t "$session:main.0" C-c C-c 2>/dev/null
  sleep 2
  # Send /exit to cleanly quit Claude if it's still running
  tmux send-keys -t "$session:main.0" "/exit" Enter 2>/dev/null
  sleep 2
  REPO_STATUS[$session]="queued"
}

# ── Write state for 'dev status' ─────────────────────────────────

write_state() {
  local now
  now=$(date '+%Y-%m-%d %H:%M:%S')
  local mem
  mem=$(get_memory_percent)
  local running=0 queued=0 done=0 rate_limited=0 skipped=0

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
        done) ((done++)) ;;
        rate-limited) ((rate_limited++)) ;;
      esac
    done

    # Include skipped repos too
    for session in "${!REPO_STATUS[@]}"; do
      if [ "${REPO_STATUS[$session]}" = "skipped" ]; then
        echo "$session|skipped|${REPO_PHASE[$session]:-0}"
        ((skipped++))
      fi
    done

    echo ""
    echo "running=$running"
    echo "queued=$queued"
    echo "done=$done"
    echo "rate_limited=$rate_limited"
    echo "skipped=$skipped"
  } > "$tmp"

  mv "$tmp" "$STATE_FILE"
}

# ── Main loop ────────────────────────────────────────────────────

main() {
  log "=== GSD Queue Runner started (WIP=$WIP_LIMIT) ==="

  scan_and_build_queue

  if [ ${#QUEUE_ORDER[@]} -eq 0 ]; then
    log "No repos need autonomous work. Exiting."
    log "  Repos needing discussion → run 'dev plan'"
    log "  Repos needing verification → run 'dev verify'"
    write_state
    return
  fi

  log "Queue (${#QUEUE_ORDER[@]} repos): ${QUEUE_ORDER[*]}"

  while true; do
    # ── Check completions ────────────────────────────────────────
    for session in "${QUEUE_ORDER[@]}"; do
      if [ "${REPO_STATUS[$session]}" = "running" ]; then
        if ! is_claude_running "$session"; then
          handle_completion "$session"
        fi
      fi
    done

    # ── Count running ────────────────────────────────────────────
    local running=0
    for session in "${QUEUE_ORDER[@]}"; do
      [ "${REPO_STATUS[$session]}" = "running" ] && ((running++))
    done

    # ── Memory safety ────────────────────────────────────────────
    local mem_pct
    mem_pct=$(get_memory_percent)

    if [ "$mem_pct" -ge "$MEMORY_CRIT" ] && [ "$running" -ge 2 ]; then
      # Pause lowest priority running session
      for ((i=${#QUEUE_ORDER[@]}-1; i>=0; i--)); do
        if [ "${REPO_STATUS[${QUEUE_ORDER[$i]}]}" = "running" ]; then
          pause_session "${QUEUE_ORDER[$i]}"
          ((running--))
          break
        fi
      done
    fi

    # ── Start queued sessions ────────────────────────────────────
    if [ "$running" -lt "$WIP_LIMIT" ] && [ "$mem_pct" -lt "$MEMORY_WARN" ]; then
      for session in "${QUEUE_ORDER[@]}"; do
        [ "$running" -ge "$WIP_LIMIT" ] && break
        if [ "${REPO_STATUS[$session]}" = "queued" ]; then
          start_claude_in_repo "$session"
          ((running++))
        fi
      done
    fi

    # ── Retry rate-limited sessions ──────────────────────────────
    local now_epoch
    now_epoch=$(date +%s)
    for session in "${QUEUE_ORDER[@]}"; do
      if [ "${REPO_STATUS[$session]}" = "rate-limited" ]; then
        local retry="${REPO_RETRY_AFTER[$session]:-0}"
        if [ "$now_epoch" -ge "$retry" ] && [ "$running" -lt "$WIP_LIMIT" ] && [ "$mem_pct" -lt "$MEMORY_WARN" ]; then
          log "Retrying rate-limited: $session"
          REPO_STATUS[$session]="queued"
          start_claude_in_repo "$session"
          ((running++))
          break   # one retry per cycle
        fi
      fi
    done

    # ── Check if all work is done ────────────────────────────────
    local all_finished=true
    for session in "${QUEUE_ORDER[@]}"; do
      local st="${REPO_STATUS[$session]}"
      [ "$st" = "queued" ] || [ "$st" = "running" ] && all_finished=false && break
    done

    if $all_finished; then
      # Check if only rate-limited remain
      local any_rate=false
      for session in "${QUEUE_ORDER[@]}"; do
        [ "${REPO_STATUS[$session]}" = "rate-limited" ] && any_rate=true && break
      done
      if ! $any_rate; then
        log "=== All repos complete ==="
        notify "All repos complete — run 'dev verify' to review" "tada"
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
