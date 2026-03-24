# 1Password Setup

## Local Machine — SSH Agent

Enables passwordless SSH from your Mac to the VM.

1. Open 1Password → **Settings → Developer**
2. Enable **Use the SSH agent**
3. Create an SSH Key item in your vault (New Item → SSH Key → Generate)
4. Add the public key to the VM's `~/.ssh/authorized_keys`
5. Add to `~/.zshrc`:

```bash
export SSH_AUTH_SOCK=~/Library/Group\ Containers/2BUA8C4S2C.com.1password/t/agent.sock
```

6. Reload: `source ~/.zshrc`
7. Test: `ssh-add -l` should show your key

## VM — 1Password CLI (op)

Used to inject secrets at runtime so API keys never touch disk in plain text.

### Installation

Already handled by `setup.sh`. To install manually:

```bash
curl -sS https://downloads.1password.com/linux/keys/1password.asc \
  | sudo gpg --dearmor --output /usr/share/keyrings/1password-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/1password-archive-keyring.gpg] \
https://downloads.1password.com/linux/debian/$(dpkg --print-architecture) stable main" \
  | sudo tee /etc/apt/sources.list.d/1password.list
sudo apt update && sudo apt install -y 1password-cli
```

### Sign In

```bash
op signin
```

Opens a browser URL to authenticate. Session is cached until it expires.

### Using Secrets in Projects

Create a `.env.op` file at the project root (gitignored):

```bash
ANTHROPIC_API_KEY=op://Personal/Anthropic API Key/credential
DATABASE_URL=op://Personal/My DB/url
```

Run your app with secrets injected:

```bash
op run --env-file .env.op -- uvicorn main:app --reload
op run --env-file .env.op -- npm run dev
```

### Gitignore

Always add `.env.op` to `.gitignore`:

```
.env
.env.op
.env.local
```

### 1Password Item Reference Format

```
op://<vault>/<item>/<field>
```

Examples:
- `op://Personal/Anthropic API Key/credential`
- `op://Personal/GitHub Token/token`
- `op://Velais/Production DB/password`
