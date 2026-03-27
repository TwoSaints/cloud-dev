#!/bin/bash
# gsd-idea-listener.sh — Captures ideas from phone via Ntfy
# Runs in tmux session 'gsd-ideas' on the VM.
#
# Send ideas from the Ntfy app:
#   Title:   repo name (e.g. "todolisto")
#   Message: feature description (can be multi-line markdown)
#   Attach:  optional .md file for detailed requirements
#
# Or from CLI: dev idea <repo> "description"
#
# Ideas land in: <repo>/.planning/todos/pending/<timestamp>-<slug>.md

set -uo pipefail

# ── Environment ──────────────────────────────────────────────────
export FNM_PATH="$HOME/.local/share/fnm"
export PATH="$FNM_PATH:$HOME/.pyenv/bin:$HOME/.local/bin:$HOME/bin:$PATH"
eval "$(fnm env 2>/dev/null)"
eval "$(pyenv init - 2>/dev/null)"

LOG="$HOME/logs/gsd-ideas.log"
CONF_FILE="$HOME/.gsd-queue.conf"
mkdir -p "$HOME/logs"

NTFY_IDEAS_TOPIC="mds-ideas-fb5bf625e6e1a4d2"
NTFY_NOTIFY_TOPIC="mds-cloud-dev-791a67ce61aaa1fe"

[ -f "$CONF_FILE" ] && source "$CONF_FILE"

log() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  echo "$msg" | tee -a "$LOG"
}

notify() {
  local msg="$1"
  local tag="${2:-bulb}"
  curl -s --max-time 5 --connect-timeout 3 \
    -H "Title: cloud-dev" \
    -H "Tags: $tag" \
    --data-raw "$msg" \
    "https://ntfy.sh/$NTFY_NOTIFY_TOPIC" > /dev/null 2>&1 || true
}

# ── Find repo path by session name ───────────────────────────────

find_repo_path() {
  local name="$1"
  # Try tmux session first
  local path
  path=$(tmux display-message -t "$name:shell" -p "#{pane_current_path}" 2>/dev/null || \
         tmux display-message -t "$name:main.0" -p "#{pane_current_path}" 2>/dev/null)
  if [ -n "$path" ] && [ -d "$path" ]; then
    echo "$path"
    return
  fi
  # Search projects directories
  for dir in "$HOME/projects"/*/*; do
    [ -d "$dir" ] && [ "$(basename "$dir")" = "$name" ] && echo "$dir" && return
  done
  return 1
}

# ── Create a backlog item ────────────────────────────────────────

create_todo() {
  local repo_name="$1"
  local title="$2"
  local body="$3"
  local attachment_url="$4"

  local repo_path
  repo_path=$(find_repo_path "$repo_name")
  if [ -z "$repo_path" ]; then
    log "ERROR: repo '$repo_name' not found"
    notify "Idea rejected — repo '$repo_name' not found. Available repos: $(ls -d $HOME/projects/*/* 2>/dev/null | xargs -I{} basename {} | sort | tr '\n' ', ')" "x"
    return 1
  fi

  local todos_dir="$repo_path/.planning/todos/pending"
  mkdir -p "$todos_dir"

  # Generate filename from title
  local timestamp
  timestamp=$(date '+%Y-%m-%d')
  local slug
  slug=$(echo "$title" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '-' | sed 's/^-//;s/-$//' | head -c 60)
  local filename="${timestamp}-${slug}.md"

  # Download attachment if present
  local attachment_content=""
  if [ -n "$attachment_url" ]; then
    attachment_content=$(curl -s --max-time 15 "$attachment_url" 2>/dev/null || true)
  fi

  # Write the todo file
  cat > "$todos_dir/$filename" << TODOEOF
---
created: $(date -u '+%Y-%m-%dT%H:%M:%S.000Z')
title: $title
area: planning
source: ntfy
---

## Problem

$body
TODOEOF

  # Append attachment content if present
  if [ -n "$attachment_content" ]; then
    cat >> "$todos_dir/$filename" << ATTACHEOF

## Detailed Requirements

$attachment_content
ATTACHEOF
  fi

  log "Created: $repo_name — $todos_dir/$filename"
  notify "Idea captured for $repo_name: $title" "white_check_mark"

  # Git commit the new todo
  cd "$repo_path"
  if [ -d ".git" ]; then
    git add "$todos_dir/$filename" 2>/dev/null
    git commit -m "backlog: $title" -m "Captured via ntfy idea listener" 2>/dev/null || true
  fi

  return 0
}

# ── Process a single message ─────────────────────────────────────

process_message() {
  local json="$1"

  # Parse with python3 (guaranteed on the VM)
  local parsed
  parsed=$(python3 -c "
import json, sys
msg = json.loads(sys.argv[1])
title = msg.get('title', '').strip()
body = msg.get('message', '').strip()
attach = ''
if 'attachment' in msg and msg['attachment']:
    attach = msg['attachment'].get('url', '')

# If no title, try to parse 'repo: description' from first line of body
if not title and ':' in body.split('\n')[0]:
    first_line = body.split('\n')[0]
    title = first_line.split(':')[0].strip()
    body = ':'.join(first_line.split(':')[1:]).strip() + '\n' + '\n'.join(body.split('\n')[1:])
    body = body.strip()

# Title is the repo name, body is the description
print(f'{title}')
print(f'---SPLIT---')
print(f'{body}')
print(f'---SPLIT---')
print(f'{attach}')
" "$json" 2>/dev/null) || return 1

  local repo_name title_line body attachment_url
  repo_name=$(echo "$parsed" | head -1)
  body=$(echo "$parsed" | sed -n '/^---SPLIT---$/,/^---SPLIT---$/p' | sed '1d;$d')
  attachment_url=$(echo "$parsed" | tail -1)

  [ -z "$repo_name" ] && {
    log "ERROR: no repo name in message"
    notify "Idea rejected — set the title to the repo name (e.g. 'todolisto')" "x"
    return 1
  }

  # Use first line of body as the todo title, rest as body
  local todo_title
  todo_title=$(echo "$body" | head -1)
  local todo_body
  todo_body=$(echo "$body" | tail -n +2)

  # If body is a single line, use it as both title and body
  if [ -z "$todo_body" ]; then
    todo_body="$todo_title"
  fi

  [ -z "$todo_title" ] && todo_title="Untitled idea"

  create_todo "$repo_name" "$todo_title" "$todo_body" "$attachment_url"
}

# ── Main: stream messages from Ntfy ──────────────────────────────

main() {
  log "=== Idea listener started ==="
  log "Listening on: ntfy.sh/$NTFY_IDEAS_TOPIC"
  notify "Idea listener started — send ideas via Ntfy" "ear"

  # Stream messages as they arrive (long-poll with auto-reconnect)
  while true; do
    curl -s --max-time 0 \
      "https://ntfy.sh/$NTFY_IDEAS_TOPIC/json" 2>/dev/null | \
    while IFS= read -r line; do
      # Skip empty lines and non-message events
      [ -z "$line" ] && continue
      echo "$line" | python3 -c "import json,sys; d=json.load(sys.stdin); exit(0 if d.get('event')=='message' else 1)" 2>/dev/null || continue

      log "Received idea: $(echo "$line" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('title','?') + ': ' + d.get('message','')[:80])" 2>/dev/null)"
      process_message "$line"
    done

    # If curl exits (connection dropped), wait and reconnect
    log "Connection lost, reconnecting in 10s..."
    sleep 10
  done
}

main
