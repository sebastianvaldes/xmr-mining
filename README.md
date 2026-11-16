# XMR Mining

Installs or updates [XMRig](https://github.com/xmrig/xmrig) as a systemd service on Ubuntu x64, with a single command.

## Usage

On the machine to install or update:

```bash
curl -fsSL https://raw.githubusercontent.com/sebastianvaldes/xmr-mining/main/mine-xmr.sh | sudo bash
```

The same command works for the first install and for updates. The script is not stored on the machine.

It shows a menu to choose the pool profile. To skip the menu, pass the profile name:

```bash
curl -fsSL https://raw.githubusercontent.com/sebastianvaldes/xmr-mining/main/mine-xmr.sh | sudo bash -s -- kryptex
```

## What it does

1. Checks there is enough RAM. If not, it says how much to assign to the VM and changes nothing. Then selects the pool profile (see below).
2. Updates the operating system (`apt update` + `apt upgrade`).
3. Downloads the latest XMRig release from GitHub and verifies its SHA256 (skipped if already installed).
4. Builds `/opt/xmrig/config.json` from [`config/base.json`](config/base.json) + the selected pool profile. The worker is the hostname in uppercase.
5. Configures huge pages (2MB via sysctl and 1GB via a GRUB kernel parameter) and the MSR module.
6. Creates and enables `xmrig.service`.
7. Starts the service and follows its log live:
   - **Connected**: keeps mining. Asks to reboot only when needed (kernel updated or huge pages just configured).
   - **Error**: disables the service, restores the previous XMRig binary and `config.json`, and shows the errors.

## Configuration and pool profiles

```
config/
  base.json            settings shared by every profile (donation, huge pages, ...)
  pools/
    herominers.json    one file per pool profile, with its "pools" list
    kryptex.json
```

The final `config.json` is `base.json` merged with the selected profile. Changes take effect the next time the command runs on each machine.

- **Add a pool:** create `config/pools/<name>.json` and commit. It shows up in the menu automatically.
- **Change pool or wallet:** edit the profile file. `{{WORKER}}` is replaced with the hostname in uppercase; keep the separator the pool expects (`wallet.{{WORKER}}`, `wallet/{{WORKER}}`, ...).
- **Failover:** a profile can list several pools; XMRig uses them in order.
- **Common settings:** edit `base.json`. `donate-level` is the percentage donated to the XMRig developers (minimum 1).
- Available options: <https://xmrig.com/docs/miner/config>

### Profile selection

1. If a profile is passed as an argument, that one is used.
2. Otherwise a menu lists the profiles in the repo. Option 1 is the machine's current profile (Enter keeps it); the rest follow in alphabetical order. On a first install, or if the current profile was removed from the repo, there is no default and a choice is required.
3. Without a terminal to ask, the current profile is kept; if there is none, the script stops and asks for the argument.

The installed profile is stored in `/opt/xmrig/profile`.

## Files on the machine

| Path | Contents |
|---|---|
| `/opt/xmrig/xmrig` | XMRig binary |
| `/opt/xmrig/config.json` | Generated configuration |
| `/opt/xmrig/profile` | Installed pool profile |
| `/opt/xmrig/backup/` | Previous version (binary + config + profile) |
| `/opt/xmrig/YYYY-MM-DD-xmr-mining-install.log` | Installer logs (last 20 kept) |
| `/etc/systemd/system/xmrig.service` | Service |
| `/etc/sysctl.d/99-xmrig-hugepages.conf` | 2MB huge pages |
| `/etc/default/grub.d/99-xmrig-hugepages.cfg` | 1GB huge pages |
| `/etc/modules-load.d/xmrig-msr.conf` | Loads the MSR module |

## Useful commands

```bash
journalctl -fu xmrig          # live log
systemctl status xmrig        # status
sudo systemctl stop xmrig     # stop
sudo systemctl disable xmrig  # don't start at boot
```

## Uninstall

```bash
sudo systemctl disable --now xmrig
sudo rm -rf /opt/xmrig /etc/systemd/system/xmrig.service /etc/sysctl.d/99-xmrig-hugepages.conf /etc/modules-load.d/xmrig-msr.conf
sudo rm -f /etc/default/grub.d/99-xmrig-hugepages.cfg && sudo update-grub
sudo systemctl daemon-reload
```
