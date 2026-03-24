#!/bin/bash
# setup-client.sh — Configure SSH access to cloud-dev from Mac, Linux, or Windows (Git Bash)
# Usage: bash setup-client.sh

set -e

echo "=== cloud-dev client setup ==="
echo ""

# ─── Variables ────────────────────────────────────────────────────
CLOUD_DEV_IP="46.62.212.195"
CLOUD_DEV_USER="mds"
SSH_CONFIG="$HOME/.ssh/config"
ZSHRC="$HOME/.zshrc"
BASHRC="$HOME/.bashrc"
# ──────────────────────────────────────────────────────────────────

# ─── Detect OS and shell ──────────────────────────────────────────
OS="unknown"
case "$(uname -s)" in
  Darwin) OS="mac" ;;
  Linux)  OS="linux" ;;
  MINGW*|MSYS*|CYGWIN*) OS="windows" ;;
esac
echo "Detected OS: $OS"

if [ -f "$ZSHRC" ] && [ "$OS" != "windows" ]; then
  SHELL_RC="$ZSHRC"
else
  SHELL_RC="$BASHRC"
fi
echo "Detected shell config: $SHELL_RC"

# ─── Set platform-specific SSH strategy ─────────────────────────
# On Mac/Linux, 1Password exposes a Unix socket — point SSH_AUTH_SOCK at it.
# On Windows, 1Password uses a Windows named pipe that only the Windows
# OpenSSH client can talk to. Git Bash's /usr/bin/ssh cannot use it,
# so we alias ssh/ssh-add to the Windows OpenSSH binaries instead.
# ─────────────────────────────────────────────────────────────────

if [ "$OS" = "mac" ]; then
  AGENT_SOCK="$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
  AGENT_SOCK_EXPORT='export SSH_AUTH_SOCK=~/Library/Group\ Containers/2BUA8C4S2C.com.1password/t/agent.sock'
elif [ "$OS" = "windows" ]; then
  # Windows uses named pipes — no socket path needed
  WIN_SSH="/c/Windows/System32/OpenSSH/ssh.exe"
  WIN_SSH_ADD="/c/Windows/System32/OpenSSH/ssh-add.exe"
  WIN_SSH_KEYSCAN="/c/Windows/System32/OpenSSH/ssh-keyscan.exe"
  AGENT_SOCK=""
  AGENT_SOCK_EXPORT=""
else
  # Linux — 1Password desktop app not typical on servers, skip agent check
  AGENT_SOCK=""
  AGENT_SOCK_EXPORT=""
fi

# ─── 1. Check 1Password is installed ──────────────────────────────
echo ""
echo "[1/5] Checking 1Password..."
if ! command -v op &>/dev/null; then
  echo ""
  echo "  ⚠️  1Password CLI not found."
  if [ "$OS" = "mac" ]; then
    echo "  Install 1Password from https://1password.com/downloads/mac/"
  elif [ "$OS" = "windows" ]; then
    echo "  Install 1Password from https://1password.com/downloads/windows/"
  fi
  echo "  Then re-run this script."
  echo ""
  exit 1
fi
echo "  ✓ 1Password found"

# Check SSH agent is reachable
if [ "$OS" = "windows" ]; then
  # On Windows, verify the Windows OpenSSH client exists
  if [ ! -f "$WIN_SSH" ]; then
    echo ""
    echo "  ⚠️  Windows OpenSSH not found at $WIN_SSH"
    echo "  Install via: Settings → Apps → Optional Features → OpenSSH Client"
    echo ""
    exit 1
  fi
  echo "  ✓ Windows OpenSSH client found"

  # Test that 1Password agent is serving keys via the named pipe
  if ! "$WIN_SSH_ADD" -l &>/dev/null; then
    echo ""
    echo "  ⚠️  1Password SSH agent is not responding."
    echo "  In 1Password: Settings → Developer → Enable 'Use the SSH agent'"
    echo "  Then re-run this script."
    echo ""
    exit 1
  fi
  echo "  ✓ 1Password SSH agent is responding"
elif [ -n "$AGENT_SOCK" ]; then
  if [ ! -e "$AGENT_SOCK" ]; then
    echo ""
    echo "  ⚠️  1Password SSH agent socket not found at:"
    echo "      $AGENT_SOCK"
    echo ""
    echo "  In 1Password: Settings → Developer → Enable 'Use the SSH agent'"
    echo "  Then re-run this script."
    echo ""
    exit 1
  fi
  echo "  ✓ 1Password SSH agent is running"
fi

# ─── 2. Configure shell for SSH agent access ─────────────────────
echo ""
if [ "$OS" = "windows" ]; then
  echo "[2/5] Configuring Git Bash to use Windows OpenSSH..."

  if grep -q "# 1Password SSH agent (Windows)" "$SHELL_RC" 2>/dev/null; then
    echo "  ✓ Windows OpenSSH aliases already configured — skipping"
  else
    cat >> "$SHELL_RC" << 'WINEOF'

# 1Password SSH agent (Windows)
# Git Bash's ssh can't talk to 1Password's named pipe — use Windows OpenSSH instead
alias ssh='/c/Windows/System32/OpenSSH/ssh.exe'
alias ssh-add='/c/Windows/System32/OpenSSH/ssh-add.exe'
alias ssh-keyscan='/c/Windows/System32/OpenSSH/ssh-keyscan.exe'
alias scp='/c/Windows/System32/OpenSSH/scp.exe'
alias sftp='/c/Windows/System32/OpenSSH/sftp.exe'
WINEOF
    echo "  ✓ Added Windows OpenSSH aliases to $SHELL_RC"
  fi

  # Use Windows SSH for the rest of this script
  SSH_CMD="$WIN_SSH"
  SSH_ADD_CMD="$WIN_SSH_ADD"
  SSH_KEYSCAN_CMD="$WIN_SSH_KEYSCAN"
else
  echo "[2/5] Configuring SSH_AUTH_SOCK..."
  if grep -q "SSH_AUTH_SOCK" "$SHELL_RC" 2>/dev/null; then
    echo "  ✓ SSH_AUTH_SOCK already configured in $SHELL_RC — skipping"
  else
    echo "" >> "$SHELL_RC"
    echo "# 1Password SSH agent" >> "$SHELL_RC"
    echo "$AGENT_SOCK_EXPORT" >> "$SHELL_RC"
    echo "  ✓ Added SSH_AUTH_SOCK to $SHELL_RC"
  fi

  # Apply to current session
  if [ -n "$AGENT_SOCK" ]; then
    export SSH_AUTH_SOCK="$AGENT_SOCK"
  fi

  SSH_CMD="ssh"
  SSH_ADD_CMD="ssh-add"
  SSH_KEYSCAN_CMD="ssh-keyscan"
fi

# ─── 3. Check a key is available ──────────────────────────────────
echo ""
echo "[3/5] Checking SSH keys in 1Password agent..."

KEYS=$("$SSH_ADD_CMD" -l 2>/dev/null || true)
if [ -z "$KEYS" ] || echo "$KEYS" | grep -q "no identities"; then
  echo ""
  echo "  ⚠️  No SSH keys found in 1Password agent."
  echo ""
  echo "  You need an SSH Key item in your 1Password vault:"
  echo "    1. Open 1Password"
  echo "    2. New Item → SSH Key → Generate (or import existing)"
  echo "    3. The key will be served automatically by the agent"
  echo ""
  echo "  Then add the public key to the cloud-dev VM:"
  echo "    ssh-add -l   (to get the public key)"
  echo "    ssh $CLOUD_DEV_USER@$CLOUD_DEV_IP  (login with password once)"
  echo "    echo 'your-public-key' >> ~/.ssh/authorized_keys"
  echo ""
  echo "  Re-run this script after adding a key."
  exit 1
fi

echo "  ✓ Keys available in agent:"
echo "$KEYS" | sed 's/^/    /'

# ─── 4. Configure ~/.ssh/config ───────────────────────────────────
echo ""
echo "[4/5] Configuring ~/.ssh/config..."

mkdir -p ~/.ssh
if [ "$OS" != "windows" ]; then
  chmod 700 ~/.ssh
fi

if grep -q "Host cloud-dev" "$SSH_CONFIG" 2>/dev/null; then
  echo "  ✓ cloud-dev entry already exists in $SSH_CONFIG — skipping"
  echo "  (Edit manually if you need to update it)"
else
  cat >> "$SSH_CONFIG" << EOF

Host cloud-dev
  HostName $CLOUD_DEV_IP
  User $CLOUD_DEV_USER
  ServerAliveInterval 60
  ServerAliveCountMax 10
EOF
  if [ "$OS" != "windows" ]; then
    chmod 600 "$SSH_CONFIG"
  fi
  echo "  ✓ Added cloud-dev to $SSH_CONFIG"
fi

# ─── Ensure host key is in known_hosts ────────────────────────────
if ! grep -q "$CLOUD_DEV_IP" ~/.ssh/known_hosts 2>/dev/null; then
  echo "  Adding host key to known_hosts..."
  "$SSH_KEYSCAN_CMD" -T 5 "$CLOUD_DEV_IP" >> ~/.ssh/known_hosts 2>/dev/null
  echo "  ✓ Host key added"
fi

# ─── 5. Add tunnel function to shell ──────────────────────────────
echo ""
echo "[5/5] Adding tunnel() function to $SHELL_RC..."

if grep -q "^tunnel()" "$SHELL_RC" 2>/dev/null; then
  echo "  ✓ tunnel() already configured — skipping"
else
  cat >> "$SHELL_RC" << 'EOF'

# SSH tunnel to cloud-dev VM
# Usage: tunnel 5173
tunnel() {
  echo "Tunnelling port ${1} → localhost:${1} (Ctrl+C to stop)"
  ssh -L ${1}:localhost:${1} -N cloud-dev
}

# Tunnel multiple ports at once
# Usage: tunnels 3000 8000 5173
tunnels() {
  local args=""
  for port in "$@"; do
    args="$args -L ${port}:localhost:${port}"
  done
  echo "Tunnelling ports $@ → localhost (Ctrl+C to stop)"
  ssh $args -N cloud-dev
}
EOF
  echo "  ✓ Added tunnel() and tunnels() to $SHELL_RC"
fi

# ─── Test connection ──────────────────────────────────────────────
echo ""
echo "=== Testing connection to cloud-dev ==="
echo ""

if "$SSH_CMD" -o ConnectTimeout=5 -o BatchMode=yes cloud-dev 'echo "  ✓ Connected successfully as $(whoami) on $(hostname)"' 2>/dev/null; then
  echo ""
  echo "=== Setup complete ==="
  echo ""
  echo "You can now:"
  echo "  ssh cloud-dev          — connect to the VM"
  echo "  tunnel 5173            — forward VM port 5173 to localhost"
  echo "  tunnels 3000 8000      — forward multiple ports at once"
  echo ""
  echo "Reload your shell to apply changes:"
  echo "  source $SHELL_RC"
else
  echo ""
  echo "  ⚠️  Could not connect automatically."
  echo ""
  echo "  This likely means your 1Password public key isn't on the VM yet."
  echo "  Get your public key:"
  echo ""
  echo "    ssh-add -l -E sha256"
  echo "    # or copy it from the 1Password app (SSH Key item → public key field)"
  echo ""
  echo "  Then add it to the VM (using password auth once):"
  echo ""
  echo "    ssh $CLOUD_DEV_USER@$CLOUD_DEV_IP"
  echo "    echo 'your-public-key' >> ~/.ssh/authorized_keys"
  echo ""
  echo "  Then test: ssh cloud-dev"
fi
