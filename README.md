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
   - **Nothing changed** (same XMRig version, config, profile and service) and the service is running: it is not restarted and the backup is left untouched.
8. With the `auto` profile, sets up the hourly automatic updates (see below); with any other profile, removes them.

## Configuration and pool profiles

```
config/
  auto                 profile followed by machines in "auto" mode, or "stop"
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

## Automatic updates (`auto` profile)

Choosing `auto` in the menu (or `bash -s -- auto`) makes the machine follow [`config/auto`](config/auto), a one-line file with a profile name or `stop`. A systemd timer runs `/opt/xmrig/xmr-auto-update.sh` every hour, which:

| `config/auto` | What it does |
|---|---|
| a profile (`herominers`, ...) | Builds `config.json` from `base.json` + that profile and installs new XMRig releases. If something changed, restarts the miner and tests it; if the test fails it goes back to the previous version and config (or stays stopped, if it was stopped). A failed change is not retried until the repo or the XMRig release changes. |
| `stop` | Stops the miner and disables it at boot. It keeps checking every hour, so changing `config/auto` back to a profile resumes mining. |

- The updater only downloads the JSON files and the official XMRig release (SHA256 verified); it never runs code from the repo. It is installed or updated only when `mine-xmr.sh` runs.
- It does not update the operating system, huge pages or GRUB: run the install command for that.
- Running the install command while `config/auto` is `stop` updates everything but leaves mining stopped.
- Choosing any other profile removes the timer and the updater.
- Log: `journalctl -u xmrig-auto-update`. Next run: `systemctl list-timers xmrig-auto-update`.

## Files on the machine

| Path | Contents |
|---|---|
| `/opt/xmrig/xmrig` | XMRig binary |
| `/opt/xmrig/config.json` | Generated configuration |
| `/opt/xmrig/profile` | Installed pool profile (`auto` in auto mode) |
| `/opt/xmrig/xmr-auto-update.sh` | Automatic updater (auto mode only) |
| `/opt/xmrig/repo`, `auto-current`, `auto-failed` | Updater state: repo followed, profile applied, last failed attempt |
| `/opt/xmrig/backup/` | Previous version (binary + config + profile) |
| `/opt/xmrig/YYYY-MM-DD-xmr-mining-install.log` | Installer logs (last 20 kept) |
| `/etc/systemd/system/xmrig.service` | Service |
| `/etc/systemd/system/xmrig-auto-update.{service,timer}` | Hourly automatic update (auto mode only) |
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
sudo systemctl disable --now xmrig xmrig-auto-update.timer
sudo rm -rf /opt/xmrig /etc/systemd/system/xmrig.service /etc/systemd/system/xmrig-auto-update.* /etc/sysctl.d/99-xmrig-hugepages.conf /etc/modules-load.d/xmrig-msr.conf
sudo rm -f /etc/default/grub.d/99-xmrig-hugepages.cfg && sudo update-grub
sudo systemctl daemon-reload
```
