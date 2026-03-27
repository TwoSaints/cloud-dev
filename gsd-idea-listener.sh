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
IDEA_PIN=""  # set in ~/.gsd-queue.conf

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

# ── Clone a new repo ─────────────────────────────────────────────

process_newproject() {
  local body="$1"

  # Parse: "org/repo folder"
  local repo folder
  repo=$(echo "$body" | awk '{print $1}')
  folder=$(echo "$body" | awk '{print $2}')

  if [ -z "$repo" ] || [ -z "$folder" ]; then
    log "ERROR: newproject needs 'org/repo folder'"
    notify "New project rejected — format: org/repo folder\ne.g. TwoSaints/my-app personal" "x"
    return 1
  fi

  log "Cloning new project: $repo → $folder"
  notify "Cloning $repo..." "hourglass"

  # Source bashrc to get the newproject function
  source "$HOME/.bashrc" 2>/dev/null

  # Run newproject (defined in bashrc_additions)
  if newproject "$repo" "$folder" >> "$LOG" 2>&1; then
    local name
    name=$(basename "$repo")

    # Apply group colour
    local path="$HOME/projects/$folder/$name"
    local group="system" color="#917068"
    case "$path" in
      */projects/personal/*) group="personal" color="#7a8c5e" ;;
      */projects/velais/*)   group="velais"   color="#6b9bc0" ;;
      */projects/m2/*)       group="m2"       color="#c8a96e" ;;
    esac
    tmux set -t "$name" @group "$group" 2>/dev/null
    tmux set -t "$name" @color "$color" 2>/dev/null
    tmux set -t "$name" status-left "#[fg=$color,bold] $name #[fg=#3d3226]│ " 2>/dev/null

    log "Project created: $name ($group)"
    notify "Project $name is ready\ngo $name — attach\ndev open — see all sessions" "white_check_mark"
  else
    log "ERROR: newproject failed for $repo"
    notify "Failed to clone $repo — check logs" "x"
  fi
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

# Title is the repo name (possibly with PIN prefix)
print(f'{title}')
print(f'---SPLIT---')
print(f'{body}')
print(f'---SPLIT---')
print(f'{attach}')
" "$json" 2>/dev/null) || return 1

  local raw_title body attachment_url
  raw_title=$(echo "$parsed" | head -1)

  # ── PIN validation ───────────────────────────────────────────
  local repo_name="$raw_title"
  if [ -n "$IDEA_PIN" ]; then
    # Expect format: PIN:repo_name
    local msg_pin="${raw_title%%:*}"
    if [ "$msg_pin" != "$IDEA_PIN" ]; then
      log "REJECTED: invalid PIN in title '$raw_title'"
      return 1
    fi
    repo_name="${raw_title#*:}"
    repo_name=$(echo "$repo_name" | tr -d '[:space:]')
  fi
  body=$(echo "$parsed" | sed -n '/^---SPLIT---$/,/^---SPLIT---$/p' | sed '1d;$d')
  attachment_url=$(echo "$parsed" | tail -1)

  [ -z "$repo_name" ] && {
    log "ERROR: no repo name in message"
    notify "Idea rejected — set the title to the repo name (e.g. 'todolisto')" "x"
    return 1
  }

  # Route: if title is "newproject", clone a repo instead
  if [ "$repo_name" = "newproject" ]; then
    process_newproject "$body"
    return
  fi

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
