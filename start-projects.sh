#!/bin/bash
# start-projects.sh — Bootstrap all project tmux sessions
# Lives at ~/start-projects.sh on the VM
# Auto-started on reboot via systemd

# ─── Project config ───────────────────────────────────────────────
# Add frontend/backend start commands per project here.
# Leave empty "" if a project doesn't have one.
# Windows are only created for commands that are non-empty.
declare -A FRONTEND_CMD
declare -A BACKEND_CMD

FRONTEND_CMD["todolisto"]="cd todolisto-ui && npm run dev"
BACKEND_CMD["todolisto"]="python -m uvicorn todolisto.api.app:app --reload"

# Add more projects here as needed:
# FRONTEND_CMD["velais-vdx"]="npm run dev"
# BACKEND_CMD["velais-vdx"]="uvicorn main:app --reload"
# FRONTEND_CMD["m2-site"]="npm run dev"
# BACKEND_CMD["m2-site"]=""
# ──────────────────────────────────────────────────────────────────

# ─── Project list ─────────────────────────────────────────────────
# Format: "session-name:absolute-path"
# 'os' is special — rooted at ~ for VM-level management tasks
PROJECTS=(
  "os:$HOME"
  "todolisto:$HOME/projects/personal/todolisto"
  "velais-vdx:$HOME/projects/velais/velais-vdx"
  "aihub-infra:$HOME/projects/velais/client/aihub-infra"
  "m2-labs:$HOME/projects/m2/m2-labs"
  "m2-site:$HOME/projects/m2/m2-site"
)
# ──────────────────────────────────────────────────────────────────

create_session() {
  local name=$1
  local path=$2
  local frontend="${FRONTEND_CMD[$name]}"
  local backend="${BACKEND_CMD[$name]}"

  # Skip if path doesn't exist
  if [ ! -d "$path" ]; then
    echo "  ⚠ Skipping '$name' — path not found: $path"
    return
  fi

  # Create session with explicit dimensions (required for headless server)
  tmux new-session -d -s "$name" -c "$path" -x 220 -y 50

  # Window 0: claude (always) ──────────────────────────────────────
  tmux rename-window -t "$name:0" "claude"
  tmux send-keys -t "$name:claude" \
    "claude remote-control --spawn=same-dir --dangerously-skip-permissions" Enter
  sleep 3
  tmux send-keys -t "$name:claude" "y" Enter

  # Window 1: shell (always, except 'os') ──────────────────────────
  if [ "$name" != "os" ]; then
    tmux new-window -t "$name" -n "shell" -c "$path"
    tmux send-keys -t "$name:shell" "git status" Enter
  fi

  # Window 2: frontend (conditional) ───────────────────────────────
  if [ -n "$frontend" ]; then
    tmux new-window -t "$name" -n "frontend" -c "$path"
    tmux send-keys -t "$name:frontend" "$frontend" Enter
  fi

  # Window 3: backend (conditional) ────────────────────────────────
  if [ -n "$backend" ]; then
    tmux new-window -t "$name" -n "backend" -c "$path"
    tmux send-keys -t "$name:backend" "$backend" Enter
  fi

  # Return focus to claude window
  tmux select-window -t "$name:claude"
}

# ─── Bootstrap ────────────────────────────────────────────────────
for entry in "${PROJECTS[@]}"; do
  name="${entry%%:*}"
  path="${entry##*:}"

  if tmux has-session -t "$name" 2>/dev/null; then
    echo "  ↩ '$name' already running — skipping"
  else
    create_session "$name" "$path"
    echo "  ✓ Started: $name"
  fi
done

echo ""
echo "Sessions ready."
echo ""
echo "  projects        — list all sessions"
echo "  rc <name>       — point remote control at a project"
echo "  go <name>       — attach terminal to a session"
echo "  restart <name>  — kill and recreate a session"
echo "  newproject <org>/<repo> <folder>  — clone and spin up a new project"
echo ""
echo "  Ctrl+B 0  — claude (always)"
echo "  Ctrl+B 1  — shell  (always)"
echo "  Ctrl+B 2  — frontend (if configured)"
echo "  Ctrl+B 3  — backend  (if configured)"
echo "  Ctrl+B D  — detach without killing"
