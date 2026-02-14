# Digital Ocean Firewall IP Updater

A bash script that automatically updates Digital Ocean firewall rules when your external IP changes. Designed for dynamic IP environments where you need to maintain firewall access without manual intervention.

## Features

- **Smart rule preservation** - Fetches current rules before updating, never overwrites your custom configurations
- **Two update modes**:
  - `swap` - Only replaces your old IP, preserves other IPs in the rule (for shared firewalls)
  - `replace_all` - Replaces all IPs on specified ports (for personal firewalls)
- **Preserves droplet assignments** - Won't accidentally detach droplets from firewalls
- **Preserves outbound rules** - Only modifies inbound rules for specified ports
- **Reliable IP detection** - Uses multiple services with fallback (icanhazip.com, ifconfig.me, ipinfo.io)
- **Silent when unchanged** - Only logs and updates when IP actually changes
- **Multi-firewall support** - Update multiple firewalls with different configurations

## Prerequisites

1. **doctl installed and authenticated**:
   ```bash
   # Install doctl
   # See: https://docs.digitalocean.com/reference/doctl/how-to/install/

   # Authenticate
   doctl auth init
   ```

2. **API token permissions** (in DO dashboard):
   - Firewall: Read + Write
   - Tag: Read (required for firewall updates to work)

3. **curl** installed (usually pre-installed on most systems)

## Installation

1. Clone the repository:
   ```bash
   git clone https://github.com/alanpinnt/digital-ocean-update-firewall-ip-doctl-script.git
   cd digital-ocean-update-firewall-ip-doctl-script
   ```

2. Copy the example config and edit it:
   ```bash
   cp config.example config
   nano config  # or your preferred editor
   ```

3. Make the script executable:
   ```bash
   chmod +x ip-updater.sh
   ```

4. Find your firewall IDs:
   ```bash
   doctl compute firewall list --format ID,Name
   ```

5. Add your firewalls to the config file (see Configuration below)

## Configuration

Edit the `config` file with your firewall settings:

```bash
# Format: "firewall_id:mode:ports"
# Multiple firewalls are space-separated

# Single firewall - update port 22 only, preserve other IPs
FIREWALLS="abc12345-1234-5678-90ab-cdef12345678:swap:22"

# Multiple firewalls with different modes
FIREWALLS="abc12345-...:swap:22 def67890-...:replace_all:22,80,443"
```

### Update Modes

| Mode | Behavior | Use Case |
|------|----------|----------|
| `swap` | Replaces only your old IP with new IP, keeps other IPs | Shared servers where multiple admins have static IPs |
| `replace_all` | Replaces ALL IPs on specified ports with your IP | Personal dev servers where only you need access |

### Environment Variables (Optional)

Override default paths using environment variables:

```bash
IP_UPDATER_CONFIG=/path/to/config ./ip-updater.sh
IP_UPDATER_LOG=/var/log/ip-updater.log ./ip-updater.sh
IP_UPDATER_ERROR_LOG=/var/log/ip-updater-error.log ./ip-updater.sh
```

## Usage

### Manual Run

```bash
./ip-updater.sh
```

### Cron Job (Recommended)

Run every 5 minutes:

```bash
crontab -e

# Add this line:
*/5 * * * * /path/to/ip-updater.sh
```

### Systemd Timer (Alternative)

Create `/etc/systemd/system/ip-updater.service`:
```ini
[Unit]
Description=Update DO firewall with current IP

[Service]
Type=oneshot
ExecStart=/path/to/ip-updater.sh
User=your-username
```

Create `/etc/systemd/system/ip-updater.timer`:
```ini
[Unit]
Description=Run IP updater every 5 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
```

Enable:
```bash
sudo systemctl enable --now ip-updater.timer
```

## Testing

**Force an update by faking an IP change:**
```bash
echo "[2020-01-01 00:00:00] IP: 1.2.3.4" > current-ip.log
./ip-updater.sh
```

**Verify firewall rules after update:**
```bash
doctl compute firewall get YOUR_FIREWALL_ID --format InboundRules
```

**Check error log:**
```bash
cat ip-updater-error.log
```

**Dry run / debug:**
```bash
# Check what IP would be detected
curl -s https://icanhazip.com

# Check stored IP
cat current-ip.log
```

## File Structure

```
.
├── ip-updater.sh       # Main script
├── config              # Your configuration (git-ignored)
├── config.example      # Example configuration
├── current-ip.log      # Stores current IP with timestamp
├── ip-updater-error.log # Error log
└── README.md
```

## Troubleshooting

### "insufficient permissions" error
Add `tag:read` permission to your API token in the Digital Ocean dashboard.

### Droplets getting removed from firewall
This shouldn't happen - the script preserves droplet IDs. If it does, check that your API token has proper permissions.

### IP not updating correctly
1. Check that your stored IP matches what's actually in the firewall
2. On first run, the script will ADD your IP (not swap) since there's no previous IP to replace
3. Verify the firewall ID is correct: `doctl compute firewall list`

### Script not running from cron
1. Check cron logs: `grep CRON /var/log/syslog`
2. Ensure doctl is in cron's PATH or use absolute path
3. Make sure the script has execute permissions

## How It Works

1. Fetches your current external IP (with fallback services)
2. Validates IP format (IPv4)
3. Compares against stored IP in `current-ip.log`
4. If different:
   - For each configured firewall:
     - Fetches current firewall rules from Digital Ocean
     - Fetches current droplet IDs
     - Modifies only the specified port rules based on mode
     - Updates firewall with all preserved settings
   - Logs new IP to `current-ip.log`
5. If same: exits silently (no API calls made)

## License

MIT License - See LICENSE file for details.

## Contributing

Contributions welcome! Please open an issue or submit a pull request.
