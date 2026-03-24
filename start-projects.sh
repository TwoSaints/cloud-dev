#!/bin/bash
# start-projects.sh — Bootstrap all project tmux sessions
# Lives at ~/start-projects.sh on the VM
# Auto-started on reboot via systemd (see setup.sh)

# ─── Project config ───────────────────────────────────────────────
# Add frontend/backend start commands per project here.
# Leave empty "" if a project doesn't have one.
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
# 'os' is a special session rooted at ~ for VM management
PROJECTS=(
  "os:$HOME"
  "todolisto:$HOME/projects/personal/todolisto"
  "velais-vdx:$HOME/projects/velais/velais-vdx"
  "m2-labs:$HOME/projects/m2/m2-labs"
  "m2-site:$HOME/projects/m2/m2-site"
)
# ──────────────────────────────────────────────────────────────────

create_session() {
  local name=$1
  local path=$2
  local frontend="${FRONTEND_CMD[$name]}"
  local backend="${BACKEND_CMD[$name]}"

  # Create session with explicit dimensions (required for headless server)
  tmux new-session -d -s "$name" -c "$path" -x 220 -y 50
  tmux rename-window -t "$name" "main"

  if [ "$name" != "os" ]; then
    # Split bottom 10 rows for frontend and backend panes
    tmux split-window -t "$name:main" -v -l 10 -c "$path"
    # Split bottom pane in half horizontally
    tmux split-window -t "$name:main.1" -h -c "$path"

    # Name the panes
    tmux select-pane -t "$name:main.0" -T "claude"
    tmux select-pane -t "$name:main.1" -T "frontend"
    tmux select-pane -t "$name:main.2" -T "backend"

    # Start frontend if configured
    if [ -n "$frontend" ]; then
      tmux send-keys -t "$name:main.1" "$frontend" Enter
    fi

    # Start backend if configured
    if [ -n "$backend" ]; then
      tmux send-keys -t "$name:main.2" "$backend" Enter
    fi
  fi

  # Start Claude remote-control in top pane (or only pane for 'os')
  tmux send-keys -t "$name:main.0" "claude remote-control --spawn=same-dir --dangerously-skip-permissions" Enter
  sleep 3
  tmux send-keys -t "$name:main.0" "y" Enter
}

# ─── Bootstrap ────────────────────────────────────────────────────
for entry in "${PROJECTS[@]}"; do
  name="${entry%%:*}"
  path="${entry##*:}"

  if tmux has-session -t "$name" 2>/dev/null; then
    echo "Session '$name' already running — skipping"
  else
    create_session "$name" "$path"
    echo "Started: $name"
  fi
done

echo ""
echo "Sessions ready. Use 'projects' to list, 'rc <name>' to switch focus."
