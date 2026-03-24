# Hetzner Firewall Setup

## Rules

Configure in **Hetzner Console → Firewalls → Create Firewall**.

### Inbound Rules

| Protocol | Port | Source | Purpose |
|---|---|---|---|
| TCP | 22 | Any IPv4, Any IPv6 | SSH |
| ICMP | — | Any IPv4, Any IPv6 | Ping |

**Block everything else.** No HTTP, HTTPS, or any other ports should be open publicly.

### Outbound Rules

Leave outbound unrestricted (no rules defined). The VM needs to reach:
- Anthropic API (Claude Code)
- GitHub (git operations)
- Package registries (apt, npm, pip)

## Apply to Server

After creating the firewall, go to:
**Servers → cloud-dev → Firewalls → Apply Firewall**

Or apply during firewall creation by selecting the server in the "Apply to Servers" step.

## Accessing Dev Servers

Never open additional ports publicly. Use SSH tunneling instead:

```bash
# On your local machine
tunnel 5173    # forwards VM:5173 → localhost:5173
tunnel 8000    # forwards VM:8000 → localhost:8000

# Multiple ports at once
ssh -L 3000:localhost:3000 -L 8000:localhost:8000 -N cloud-dev
```

Then open `http://localhost:<port>` in your browser.

## Verifying Nothing is Exposed

Run this on the VM to confirm only port 22 is listening:

```bash
sudo ss -tlnp
```

Expected output — only SSH (22) and the internal DNS resolver (127.0.0.x:53).
