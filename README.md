# cloud-dev

Configuration and setup scripts for the Hetzner cloud development VM.

## What This Is

An always-on Hetzner CX22 VPS running Claude Code remote-control sessions across all active projects. The VM runs 24/7, sessions survive reboots via systemd, and development can be dispatched from anywhere via the Claude app or claude.ai/code.

## Machine Spec

| Property | Value |
|---|---|
| Provider | Hetzner Cloud |
| Type | CX22 (2 vCPU, 4GB RAM, 80GB SSD) |
| Location | Helsinki (hel1-dc2) |
| OS | Ubuntu 24.04 |
| User | mds |

## Repo Structure

```
cloud-dev/
├── README.md
├── setup.sh                  # Run once to provision a fresh VM
├── start-projects.sh         # Tmux session bootstrap (lives on the VM)
├── config/
│   ├── bashrc_additions      # Shell aliases and functions to append to ~/.bashrc
│   ├── ssh_client_config     # Local machine ~/.ssh/config
│   ├── sshd_config_hardened  # Hardened SSH server settings
│   ├── fail2ban_jail.local   # Fail2ban SSH protection
│   └── claude_global.md      # Global ~/.claude/CLAUDE.md
└── docs/
    ├── hetzner-firewall.md   # Hetzner firewall setup instructions
    └── 1password-setup.md    # 1Password CLI and SSH agent setup
```

## Quick Start (Fresh VM)

1. Create a Hetzner CX22 server with Ubuntu 24.04 and your SSH key
2. SSH in as root: `ssh root@<ip>`
3. Upload and run the setup script:

```bash
scp setup.sh root@<ip>:~/
ssh root@<ip> "bash setup.sh"
```

4. Copy `start-projects.sh` to the VM:

```bash
scp start-projects.sh mds@<ip>:~/
ssh mds@<ip> "chmod +x ~/start-projects.sh"
```

5. Add your local SSH config entry (see `config/ssh_client_config`)
6. Add your shell aliases (see `config/bashrc_additions`) to your local `~/.zshrc`

## Daily Workflow

```bash
ssh cloud-dev          # connect to the VM
projects               # list all tmux sessions
rc todolisto           # point remote control at a project
rc velais-vdx          # switch to another project
tunnel 5173            # forward a port to local browser
newproject TwoSaints/my-repo personal   # clone and spin up a new project
```

## Project Sessions

Each project gets a tmux session with 3 panes:
- **Top (claude):** `claude remote-control` — controlled via Claude app or claude.ai/code
- **Bottom left (frontend):** configurable per project
- **Bottom right (backend):** configurable per project

The `os` session is a special session rooted at `~` for VM management tasks.

## Adding a New Project

```bash
newproject <org>/<repo> <folder>
# e.g. newproject velais-ai-solutions/client-abc velais/client
```

Then add its frontend/backend commands to `start-projects.sh` under the project config block.

## Security

- Root login disabled
- Password authentication disabled (SSH key only)
- Hetzner firewall: only port 22 (SSH) and ICMP allowed
- Fail2ban: bans IPs after 5 failed SSH attempts
- Automatic security updates enabled
- Nothing exposed publicly — dev servers accessed via SSH tunnel only

## SSH Tunneling

To access a dev server running on the VM:

```bash
tunnel 5173   # forwards VM:5173 to localhost:5173
```

Then open `http://localhost:5173` in your browser.
