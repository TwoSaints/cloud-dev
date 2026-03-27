#!/bin/bash
# start-projects.sh — Bootstrap all project tmux sessions
# Lives at ~/start-projects.sh on the VM
# Auto-started on reboot via systemd

# ─── Group colors (earthy Terra palette) ─────────────────────────
# Derived automatically from project path. Used for tmux status bar
# and Windows Terminal tab colors.
declare -A GROUP_COLOR
GROUP_COLOR["velais"]="#6b9bc0"     # blue (Velais brand)
GROUP_COLOR["personal"]="#7a8c5e"  # sage green
GROUP_COLOR["m2"]="#c8a96e"        # gold (M2 black & gold brand)
GROUP_COLOR["system"]="#917068"    # dusty mauve

_derive_group() {
  local path="$1"
  case "$path" in
    */projects/personal/*) echo "personal" ;;
    */projects/velais/*)   echo "velais" ;;
    */projects/m2/*)       echo "m2" ;;
    *)                     echo "system" ;;
  esac
}

# ─── Project config ───────────────────────────────────────────────
# Frontend/backend commands per project.
# Only set these for projects that HAVE a frontend or backend.
# Panes are only created when a command is configured.
declare -A FRONTEND_CMD
declare -A BACKEND_CMD

FRONTEND_CMD["todolisto"]="cd todolisto-ui && npm run dev"
BACKEND_CMD["todolisto"]="python -m uvicorn todolisto.api.app:app --reload"

FRONTEND_CMD["m2-site"]="npm run dev"

# Add more as needed:
# FRONTEND_CMD["velais-vdx"]="npm run dev"
# BACKEND_CMD["velais-vdx"]="uvicorn main:app --reload"
# ──────────────────────────────────────────────────────────────────

# ─── Project list ─────────────────────────────────────────────────
# Format: "session-name:absolute-path"
# Group is derived automatically from the path.
PROJECTS=(
  "os:$HOME"
  "todolisto:$HOME/projects/personal/todolisto"
  "cloud-dev:$HOME/projects/personal/cloud-dev"
  "velais-vdx:$HOME/projects/velais/velais-vdx"
  "velais-content:$HOME/projects/velais/velais-content"
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
  local group=$(_derive_group "$path")
  local color="${GROUP_COLOR[$group]:-#c8a96e}"

  # Skip if path doesn't exist
  if [ ! -d "$path" ]; then
    echo "  ⚠ Skipping '$name' — path not found: $path"
    return
  fi

  # Create session with explicit dimensions (required for headless server)
  tmux new-session -d -s "$name" -c "$path" -x 220 -y 50
  tmux rename-window -t "$name:0" "main"

  # ── Pane layout ────────────────────────────────────────────────
  # Only create panes that the project needs.
  #
  #   Both:         Frontend only:    Backend only:     Neither:
  #   ┌──────────┐  ┌──────────┐      ┌──────────┐     ┌──────────┐
  #   │  claude  │  │  claude  │      │  claude  │     │  claude  │
  #   ├─────┬────┤  ├──────────┤      ├──────────┤     └──────────┘
  #   │ fe  │ be │  │ frontend │      │ backend  │
  #   └─────┴────┘  └──────────┘      └──────────┘

  if [ -n "$frontend" ] && [ -n "$backend" ]; then
    tmux split-window -t "$name:main" -v -l 6 -c "$path"
    tmux split-window -t "$name:main.1" -h -c "$path"
    tmux select-pane -t "$name:main.0" -T "claude"
    tmux select-pane -t "$name:main.1" -T "frontend"
    tmux select-pane -t "$name:main.2" -T "backend"
    tmux send-keys -t "$name:main.1" "$frontend" Enter
    tmux send-keys -t "$name:main.2" "$backend" Enter
  elif [ -n "$frontend" ]; then
    tmux split-window -t "$name:main" -v -l 6 -c "$path"
    tmux select-pane -t "$name:main.0" -T "claude"
    tmux select-pane -t "$name:main.1" -T "frontend"
    tmux send-keys -t "$name:main.1" "$frontend" Enter
  elif [ -n "$backend" ]; then
    tmux split-window -t "$name:main" -v -l 6 -c "$path"
    tmux select-pane -t "$name:main.0" -T "claude"
    tmux select-pane -t "$name:main.1" -T "backend"
    tmux send-keys -t "$name:main.1" "$backend" Enter
  else
    tmux select-pane -t "$name:main.0" -T "claude"
  fi

  # ── Shell window (always, except 'os') ─────────────────────────
  if [ "$name" != "os" ]; then
    tmux new-window -t "$name" -n "shell" -c "$path"
    tmux send-keys -t "$name:shell" "git status" Enter
  fi

  # ── Store group metadata (used by local dev script) ────────────
  tmux set -t "$name" @group "$group"
  tmux set -t "$name" @color "$color"

  # ── Apply group color to status bar ────────────────────────────
  tmux set -t "$name" status-left "#[fg=$color,bold] #S #[fg=#3d3226]│ "

  # Return focus to main window, claude pane
  tmux select-window -t "$name:main"
  tmux select-pane -t "$name:main.0"
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
echo "  Ctrl+B 0  — main (claude + servers)"
echo "  Ctrl+B 1  — shell"
echo "  Ctrl+B D  — detach without killing"
