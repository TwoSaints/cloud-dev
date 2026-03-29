#!/bin/bash
# setup-client.sh — Run on any new machine to configure SSH access to cloud-dev
# Works on macOS, Windows (Git Bash), and Linux.
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
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOTAL_STEPS=10
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

# ─── Set platform-specific SSH binaries ───────────────────────────
if [ "$OS" = "windows" ]; then
  SSH_CMD="/c/Windows/System32/OpenSSH/ssh.exe"
  SSH_ADD="/c/Windows/System32/OpenSSH/ssh-add.exe"
else
  SSH_CMD="ssh"
  SSH_ADD="ssh-add"
fi

# ─── Set platform-specific agent socket path ──────────────────────
if [ "$OS" = "mac" ]; then
  AGENT_SOCK="$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
  AGENT_SOCK_EXPORT='export SSH_AUTH_SOCK=~/Library/Group\ Containers/2BUA8C4S2C.com.1password/t/agent.sock'
elif [ "$OS" = "windows" ]; then
  AGENT_SOCK=""
  AGENT_SOCK_EXPORT=""
else
  AGENT_SOCK=""
  AGENT_SOCK_EXPORT=""
fi

# ─── 1. Check 1Password ──────────────────────────────────────────
echo ""
echo "[1/$TOTAL_STEPS] Checking 1Password..."
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
if [ -n "$AGENT_SOCK" ]; then
  if [ ! -S "$AGENT_SOCK" ]; then
    echo ""
    echo "  ⚠️  1Password SSH agent socket not found at:"
    echo "      $AGENT_SOCK"
    echo ""
    echo "  In 1Password: Settings → Developer → Enable 'Use the SSH agent'"
    echo "  Then re-run this script."
    echo ""
    exit 1
  fi
else
  if [ "$OS" = "windows" ]; then
    if ! $SSH_ADD -l &>/dev/null; then
      echo ""
      echo "  ⚠️  SSH agent not responding."
      echo ""
      echo "  In 1Password: Settings → Developer → Enable 'Use the SSH agent'"
      echo "  Also ensure Windows OpenSSH agent service is running:"
      echo "    Get-Service ssh-agent | Set-Service -StartupType Automatic"
      echo "    Start-Service ssh-agent"
      echo ""
      exit 1
    fi
  fi
fi
echo "  ✓ 1Password SSH agent is running"

# ─── 2. Check iTerm2 (macOS only) ────────────────────────────────
echo ""
echo "[2/$TOTAL_STEPS] Checking terminal..."
if [ "$OS" = "mac" ]; then
  if [ -d "/Applications/iTerm.app" ]; then
    echo "  ✓ iTerm2 found"
  else
    echo ""
    echo "  ⚠️  iTerm2 not found."
    echo ""
    echo "  The dev command works best with iTerm2 on macOS."
    echo "  Install from: https://iterm2.com/downloads.html"
    echo ""
    echo "  You can continue without it (Terminal.app will be used as fallback)"
    echo "  but you won't get colour-coded sessions."
    echo ""
    read -rp "  Continue without iTerm2? (y/N): " choice
    if [ "$choice" != "y" ] && [ "$choice" != "Y" ]; then
      echo "  Install iTerm2 and re-run this script."
      exit 1
    fi
  fi
elif [ "$OS" = "windows" ]; then
  echo "  ✓ Windows Terminal (default)"
else
  echo "  ✓ Skipped (Linux)"
fi

# ─── 3. Configure SSH_AUTH_SOCK ───────────────────────────────────
echo ""
echo "[3/$TOTAL_STEPS] Configuring SSH_AUTH_SOCK..."

if [ -z "$AGENT_SOCK_EXPORT" ]; then
  echo "  ✓ Not needed on Windows (agent uses named pipe) — skipping"
elif grep -q "SSH_AUTH_SOCK" "$SHELL_RC" 2>/dev/null; then
  echo "  ✓ SSH_AUTH_SOCK already configured in $SHELL_RC — skipping"
else
  echo "" >> "$SHELL_RC"
  echo "# 1Password SSH agent" >> "$SHELL_RC"
  echo "$AGENT_SOCK_EXPORT" >> "$SHELL_RC"
  echo "  ✓ Added SSH_AUTH_SOCK to $SHELL_RC"
  export SSH_AUTH_SOCK="$AGENT_SOCK"
fi

# ─── 4. Check SSH keys ───────────────────────────────────────────
echo ""
echo "[4/$TOTAL_STEPS] Checking SSH keys in 1Password agent..."

KEYS=$($SSH_ADD -l 2>/dev/null || true)
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

# ─── 5. Configure ~/.ssh/config ───────────────────────────────────
echo ""
echo "[5/$TOTAL_STEPS] Configuring ~/.ssh/config..."

mkdir -p ~/.ssh
chmod 700 ~/.ssh

if grep -q "Host cloud-dev" "$SSH_CONFIG" 2>/dev/null; then
  echo "  ✓ cloud-dev entry already exists in $SSH_CONFIG — skipping"
  echo "  (Edit manually if you need to update it)"
else
  if [ "$OS" = "windows" ]; then
    cat >> "$SSH_CONFIG" << EOF

Host cloud-dev
  HostName $CLOUD_DEV_IP
  User $CLOUD_DEV_USER
  IdentitiesOnly yes
  ServerAliveInterval 60
  ServerAliveCountMax 10
EOF
  else
    mkdir -p ~/.ssh/sockets
    cat >> "$SSH_CONFIG" << EOF

Host cloud-dev
  HostName $CLOUD_DEV_IP
  User $CLOUD_DEV_USER
  ServerAliveInterval 60
  ServerAliveCountMax 10
  ControlMaster auto
  ControlPath ~/.ssh/sockets/%r@%h-%p
  ControlPersist 600
EOF
  fi
  chmod 600 "$SSH_CONFIG"
  echo "  ✓ Added cloud-dev to $SSH_CONFIG"
  if [ "$OS" != "windows" ]; then
    echo "  ✓ ControlMaster enabled (connections reuse one TCP session)"
  fi
fi

# ─── 6. Add tunnel functions ─────────────────────────────────────
echo ""
echo "[6/$TOTAL_STEPS] Adding tunnel() function to $SHELL_RC..."

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

# ─── 7. Ensure Bash 4+ (required by dev script) ─────────────────
echo ""
echo "[7/$TOTAL_STEPS] Ensuring Bash 4+ is available..."

BASH_MAJOR=$(bash --version | head -1 | sed 's/.*version \([0-9]*\).*/\1/')
BASH_UPGRADED=false

if [ "$BASH_MAJOR" -ge 4 ] 2>/dev/null; then
  echo "  ✓ Bash $BASH_MAJOR already installed"
  BASH_UPGRADED=true
else
  echo "  Current bash is version $BASH_MAJOR (need 4+)"
  if [ "$OS" = "mac" ]; then
    if command -v brew &>/dev/null; then
      echo "  Attempting to install modern bash via Homebrew..."
      if brew install bash 2>/dev/null; then
        BREW_BASH="$(brew --prefix)/bin/bash"
        if [ -x "$BREW_BASH" ]; then
          NEW_MAJOR=$("$BREW_BASH" --version | head -1 | sed 's/.*version \([0-9]*\).*/\1/')
          if [ "$NEW_MAJOR" -ge 4 ] 2>/dev/null; then
            echo "  ✓ Installed Bash $NEW_MAJOR via Homebrew at $BREW_BASH"
            BASH_UPGRADED=true
            # Ensure Homebrew bin is early in PATH so #!/usr/bin/env bash finds it
            if ! echo "$PATH" | tr ':' '\n' | grep -qx "$(brew --prefix)/bin"; then
              if ! grep -q "$(brew --prefix)/bin" "$SHELL_RC" 2>/dev/null; then
                echo "" >> "$SHELL_RC"
                echo "# Homebrew (ensures modern bash is found)" >> "$SHELL_RC"
                echo "export PATH=\"$(brew --prefix)/bin:\$PATH\"" >> "$SHELL_RC"
                echo "  ✓ Added $(brew --prefix)/bin to PATH in $SHELL_RC"
              fi
              export PATH="$(brew --prefix)/bin:$PATH"
            fi
          else
            echo "  ⚠️  Homebrew bash installed but still not v4+ — will patch dev script"
          fi
        fi
      else
        echo "  ⚠️  brew install bash failed — will patch dev script"
      fi
    else
      echo "  ⚠️  Homebrew not found — will patch dev script"
    fi
  elif [ "$OS" = "linux" ]; then
    echo "  On Linux, update bash via your package manager:"
    echo "    sudo apt-get install bash   # Debian/Ubuntu"
    echo "    sudo yum install bash       # RHEL/CentOS"
    echo "  Will patch dev script as fallback."
  fi
fi

# ─── 8. Install dev entrypoint ────────────────────────────────────
echo ""
echo "[8/$TOTAL_STEPS] Installing dev command..."

DEV_SOURCE="$SCRIPT_DIR/dev"

if [ ! -f "$DEV_SOURCE" ]; then
  echo "  ⚠️  dev script not found at $DEV_SOURCE — skipping"
  echo "  (Expected to be in the same directory as setup-client.sh)"
else
  if [ "$OS" = "windows" ]; then
    DEV_TARGET="$HOME/bin/dev"
    mkdir -p "$HOME/bin"
    cp "$DEV_SOURCE" "$DEV_TARGET"
    chmod +x "$DEV_TARGET"

    if ! echo "$PATH" | grep -q "$HOME/bin"; then
      if ! grep -q 'PATH.*\$HOME/bin' "$SHELL_RC" 2>/dev/null; then
        echo "" >> "$SHELL_RC"
        echo '# Local bin' >> "$SHELL_RC"
        echo 'export PATH="$HOME/bin:$PATH"' >> "$SHELL_RC"
        echo "  ✓ Added ~/bin to PATH in $SHELL_RC"
      fi
    fi
    echo "  ✓ Installed dev → $DEV_TARGET"
  elif [ "$OS" = "mac" ]; then
    DEV_TARGET="/usr/local/bin/dev"
    if [ -w "/usr/local/bin" ]; then
      cp "$DEV_SOURCE" "$DEV_TARGET"
      chmod +x "$DEV_TARGET"
      echo "  ✓ Installed dev → $DEV_TARGET"
    else
      sudo cp "$DEV_SOURCE" "$DEV_TARGET"
      sudo chmod +x "$DEV_TARGET"
      echo "  ✓ Installed dev → $DEV_TARGET (via sudo)"
    fi
  else
    DEV_TARGET="$HOME/.local/bin/dev"
    mkdir -p "$HOME/.local/bin"
    cp "$DEV_SOURCE" "$DEV_TARGET"
    chmod +x "$DEV_TARGET"
    echo "  ✓ Installed dev → $DEV_TARGET"
  fi
fi

# ─── 9. Install iTerm2 Terra profiles (macOS only) ────────────────
echo ""
echo "[9/$TOTAL_STEPS] Installing terminal colour profiles..."

if [ "$OS" = "mac" ] && [ -d "/Applications/iTerm.app" ]; then
  PROFILES_DIR="$HOME/Library/Application Support/iTerm2/DynamicProfiles"
  PROFILES_TARGET="$PROFILES_DIR/Terra.json"
  GENERATOR="$SCRIPT_DIR/generate-iterm-profiles.py"

  mkdir -p "$PROFILES_DIR"

  if [ -f "$GENERATOR" ]; then
    python3 "$GENERATOR" > "$PROFILES_TARGET"
    echo "  ✓ Installed Terra colour profiles → iTerm2 DynamicProfiles"
    echo "  ✓ Profiles: Terra, Terra-Velais, Terra-Personal, Terra-M2, Terra-System"
  else
    echo "  ⚠️  generate-iterm-profiles.py not found — skipping"
    echo "  (Expected to be in the same directory as setup-client.sh)"
  fi
elif [ "$OS" = "windows" ]; then
  echo "  ✓ Terra schemes already in Windows Terminal settings"
else
  echo "  ✓ Skipped (iTerm2 not installed)"
fi

# ─── 10. Test connection ─────────────────────────────────────────
echo ""
echo "[10/$TOTAL_STEPS] Testing connection to cloud-dev..."
echo ""

source "$SHELL_RC" 2>/dev/null || true
if [ -n "$AGENT_SOCK" ]; then
  export SSH_AUTH_SOCK="$AGENT_SOCK"
fi

if $SSH_CMD -o ConnectTimeout=5 -o BatchMode=yes cloud-dev "echo '  ✓ Connected successfully'" 2>/dev/null; then
  echo ""
  echo "=== Setup complete ==="
  echo ""
  echo "You can now:"
  echo "  dev                    — pick a session to attach to"
  echo "  dev ls                 — list active sessions on the VM"
  echo "  dev open               — open all sessions as tabs"
  echo "  dev open -g            — open all sessions in a tiled grid"
  echo "  dev <name>             — attach to a specific session"
  echo "  dev tunnel 5173        — forward a port to localhost"
  echo "  ssh cloud-dev          — plain SSH to the VM"
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
