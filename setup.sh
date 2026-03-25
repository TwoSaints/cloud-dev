#!/bin/bash
# setup.sh — Run once on a fresh Hetzner Ubuntu 24.04 VM as root
# Usage: bash setup.sh

set -e

echo "=== cloud-dev VM setup ==="
echo ""

# ─── Variables ────────────────────────────────────────────────────
USERNAME="mds"
# ──────────────────────────────────────────────────────────────────

# ─── 1. Create user ───────────────────────────────────────────────
echo "[1/9] Creating user '$USERNAME'..."
if id "$USERNAME" &>/dev/null; then
  echo "User '$USERNAME' already exists — skipping"
else
  adduser --gecos "" "$USERNAME"
  usermod -aG sudo "$USERNAME"
fi

# Copy SSH key from root
mkdir -p /home/$USERNAME/.ssh
cp /root/.ssh/authorized_keys /home/$USERNAME/.ssh/
chown -R $USERNAME:$USERNAME /home/$USERNAME/.ssh
chmod 700 /home/$USERNAME/.ssh
chmod 600 /home/$USERNAME/.ssh/authorized_keys
echo "Done."

# ─── 2. Harden SSH ────────────────────────────────────────────────
echo "[2/9] Hardening SSH..."
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^#*X11Forwarding.*/X11Forwarding no/' /etc/ssh/sshd_config
sed -i 's/^#*MaxAuthTries.*/MaxAuthTries 3/' /etc/ssh/sshd_config
sed -i 's/^#*ClientAliveInterval.*/ClientAliveInterval 300/' /etc/ssh/sshd_config
sed -i 's/^#*ClientAliveCountMax.*/ClientAliveCountMax 2/' /etc/ssh/sshd_config

# Ensure AllowTcpForwarding is on (needed for SSH tunnels and Remote Control)
grep -q "^AllowTcpForwarding" /etc/ssh/sshd_config \
  && sed -i 's/^AllowTcpForwarding.*/AllowTcpForwarding yes/' /etc/ssh/sshd_config \
  || echo "AllowTcpForwarding yes" >> /etc/ssh/sshd_config

systemctl restart ssh
echo "Done."

# ─── 3. Install core packages ─────────────────────────────────────
echo "[3/9] Installing core packages..."
apt update && apt upgrade -y
apt install -y git tmux curl wget build-essential unzip tree \
  libssl-dev libffi-dev libbz2-dev libreadline-dev libsqlite3-dev zlib1g-dev
echo "Done."

# ─── 4. Install fail2ban ──────────────────────────────────────────
echo "[4/9] Installing fail2ban..."
apt install -y fail2ban
cat > /etc/fail2ban/jail.local << 'FAIL2BAN'
[sshd]
enabled = true
port = ssh
maxretry = 5
bantime = 3600
findtime = 600
FAIL2BAN
systemctl enable fail2ban
systemctl start fail2ban
echo "Done."

# ─── 5. Automatic security updates ───────────────────────────────
echo "[5/9] Enabling automatic security updates..."
apt install -y unattended-upgrades
echo 'Unattended-Upgrade::Automatic-Reboot "false";' \
  >> /etc/apt/apt.conf.d/50unattended-upgrades
dpkg-reconfigure -f noninteractive unattended-upgrades
echo "Done."

# ─── 6. Secure shared memory ─────────────────────────────────────
echo "[6/9] Securing shared memory..."
grep -q "tmpfs /run/shm" /etc/fstab \
  || echo "tmpfs /run/shm tmpfs defaults,noexec,nosuid 0 0" >> /etc/fstab
echo "Done."

# ─── 7. Install fnm (Node version manager) ───────────────────────
echo "[7/9] Installing fnm and Node 22..."
su - $USERNAME -c '
  curl -fsSL https://fnm.vercel.app/install | bash
  export PATH="$HOME/.local/share/fnm:$PATH"
  eval "$(fnm env)"
  fnm install 22
  fnm default 22
'
echo "Done."

# ─── 8. Install pyenv (Python version manager) ───────────────────
echo "[8/9] Installing pyenv and Python 3.12..."
su - $USERNAME -c '
  curl https://pyenv.run | bash
  export PYENV_ROOT="$HOME/.pyenv"
  export PATH="$PYENV_ROOT/bin:$PATH"
  eval "$(pyenv init -)"
  pyenv install 3.12
  pyenv global 3.12
'

# Add pyenv to .bashrc
cat >> /home/$USERNAME/.bashrc << 'PYENV'

# pyenv
export PYENV_ROOT="$HOME/.pyenv"
export PATH="$PYENV_ROOT/bin:$PATH"
eval "$(pyenv init -)"
PYENV
chown $USERNAME:$USERNAME /home/$USERNAME/.bashrc
echo "Done."

# ─── 9. Configure git identity ───────────────────────────────────
echo "[9/10] Configuring git identity..."
su - $USERNAME -c '
git config --global user.name "MDS"
git config --global user.email "michaeljamesds@gmail.com"
git config --global user.useConfigOnly true
git config --global init.defaultBranch main
git config --global pull.rebase false
git config --global includeIf.gitdir:~/projects/velais/.path ~/.gitconfig-velais
git config --global includeIf.gitdir:~/projects/velais/client/.path ~/.gitconfig-velais
git config --global includeIf.gitdir:~/projects/m2/.path ~/.gitconfig-velais

cat > ~/.gitconfig-velais << "VELAIS"
[user]
  email = michael.dos.santos@velais.com
VELAIS
'
echo "Done."

# ─── 10. Install 1Password CLI ───────────────────────────────────
echo "[10/11] Installing 1Password CLI..."
curl -sS https://downloads.1password.com/linux/keys/1password.asc \
  | gpg --dearmor --output /usr/share/keyrings/1password-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/1password-archive-keyring.gpg] \
https://downloads.1password.com/linux/debian/$(dpkg --print-architecture) stable main" \
  | tee /etc/apt/sources.list.d/1password.list
apt update && apt install -y 1password-cli
echo "Done."

# ─── 11. Install GSD (Get Shit Done) globally ─────────────────────
echo "[11/11] Installing GSD for Claude Code..."
su - $USERNAME -c '
  npx get-shit-done-cc@latest --claude --global --yes
'
echo "Done."

echo ""
echo "=== Setup complete ==="
echo ""
echo "Next steps:"
echo "  1. Open a new terminal and test: ssh $USERNAME@<ip>"
echo "  2. SSH in as $USERNAME and run:"
echo "     - ssh-keygen -t ed25519 -C 'hetzner-cloud-dev' -f ~/.ssh/github_vm"
echo "     - Add ~/.ssh/github_vm.pub to GitHub SSH keys"
echo "     - npm install -g @anthropic-ai/claude-code"
echo "     - claude  (then /login to authenticate)"
echo "     - Copy start-projects.sh to ~/ and run it"
echo "  3. Set up Hetzner firewall (see docs/hetzner-firewall.md)"
echo "  4. Reboot to apply kernel updates: sudo reboot"
echo ""
echo "GSD is installed globally at ~/.claude/commands/gsd/"
echo "Verify with: /gsd:help inside any Claude Code session"
echo "     - npm install -g @anthropic-ai/claude-code"
echo "     - claude  (then /login to authenticate)"
echo "     - Copy start-projects.sh to ~/ and run it"
echo "  3. Set up Hetzner firewall (see docs/hetzner-firewall.md)"
echo "  4. Reboot to apply kernel updates: sudo reboot"
