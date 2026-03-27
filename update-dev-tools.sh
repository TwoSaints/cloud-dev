#!/bin/bash
# update-dev-tools.sh — Auto-update Claude Code, MCP servers, and tooling
# Runs daily via cron. Logs to ~/logs/dev-tools-update.log
# Install: crontab -e → 0 4 * * * ~/bin/update-dev-tools.sh

set -e

LOG_DIR="$HOME/logs"
LOG="$LOG_DIR/dev-tools-update.log"
mkdir -p "$LOG_DIR"

# Load fnm + pyenv (not available in cron environment)
export FNM_PATH="$HOME/.local/share/fnm"
export PATH="$FNM_PATH:$HOME/.pyenv/bin:$HOME/.local/bin:$HOME/bin:$PATH"
eval "$(fnm env 2>/dev/null)"
eval "$(pyenv init - 2>/dev/null)"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

log "=== Update started ==="

# ── Node.js LTS ──────────────────────────────────────────────────
CURRENT_NODE=$(node --version 2>/dev/null)
fnm install --lts 2>/dev/null && fnm default lts-latest 2>/dev/null
NEW_NODE=$(node --version 2>/dev/null)
if [ "$CURRENT_NODE" != "$NEW_NODE" ]; then
  log "Node updated: $CURRENT_NODE → $NEW_NODE"
else
  log "Node: $CURRENT_NODE (up to date)"
fi

# ── Claude Code ──────────────────────────────────────────────────
CURRENT_CLAUDE=$(claude --version 2>/dev/null | head -1)
npm update -g @anthropic-ai/claude-code 2>>"$LOG"
NEW_CLAUDE=$(claude --version 2>/dev/null | head -1)
if [ "$CURRENT_CLAUDE" != "$NEW_CLAUDE" ]; then
  log "Claude Code updated: $CURRENT_CLAUDE → $NEW_CLAUDE"
else
  log "Claude Code: $CURRENT_CLAUDE (up to date)"
fi

# ── MCP Servers ──────────────────────────────────────────────────
for pkg in @playwright/mcp; do
  CURRENT=$(npm ls -g "$pkg" --depth=0 2>/dev/null | grep "$pkg" | awk -F@ '{print $NF}' || echo "?")
  npm update -g "$pkg" 2>>"$LOG"
  NEW=$(npm ls -g "$pkg" --depth=0 2>/dev/null | grep "$pkg" | awk -F@ '{print $NF}' || echo "?")
  if [ "$CURRENT" != "$NEW" ]; then
    log "$pkg updated: $CURRENT → $NEW"
  else
    log "$pkg: $CURRENT (up to date)"
  fi
done

# ── Playwright browsers ─────────────────────────────────────────
npx playwright install chromium 2>>"$LOG" && log "Playwright browsers: updated" || log "Playwright browsers: failed"

# ── Python ───────────────────────────────────────────────────────
CURRENT_PY=$(python3 --version 2>/dev/null)
log "Python: $CURRENT_PY (managed by pyenv — update manually if needed)"

# ── System packages (security updates only) ──────────────────────
sudo -n apt-get update -qq 2>>"$LOG" && \
  sudo -n apt-get upgrade -y -qq 2>>"$LOG" && \
  log "System packages: updated" || \
  log "System packages: skipped (sudo needs password)"

log "=== Update complete ==="
