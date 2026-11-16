# XMR Mining

Installs or updates [XMRig](https://github.com/xmrig/xmrig) as a systemd service on Ubuntu x64, with a single command.

## Usage

On the machine to install or update:

```bash
curl -fsSL https://raw.githubusercontent.com/sebastianvaldes/xmr-mining/main/mine-xmr.sh | sudo bash
```

The same command works for the first install and for updates. The script is not stored on the machine.

## What it does

1. Checks there is enough RAM. If not, it says how much to assign to the VM and changes nothing.
2. Updates the operating system (`apt update` + `apt upgrade`).
3. Downloads the latest XMRig release from GitHub and verifies its SHA256 (skipped if already installed).
4. Builds `/opt/xmrig/config.json` from [`config/xmrig.json`](config/xmrig.json). The worker is the hostname in uppercase.
5. Configures huge pages (2MB via sysctl and 1GB via a GRUB kernel parameter) and the MSR module.
6. Creates and enables `xmrig.service`.
7. Starts the service and follows its log live:
   - **Connected**: keeps mining. Asks to reboot only when needed (kernel updated or huge pages just configured).
   - **Error**: disables the service, restores the previous XMRig binary and `config.json`, and shows the errors.

## Changing pool, wallet or donation

Edit [`config/xmrig.json`](config/xmrig.json) and commit. The next time the command runs on each machine, it picks up the new configuration.

- `{{WORKER}}` is replaced with the hostname in uppercase.
- `donate-level`: percentage donated to the XMRig developers (minimum 1).
- Available options: <https://xmrig.com/docs/miner/config>

## Files on the machine

| Path | Contents |
|---|---|
| `/opt/xmrig/xmrig` | XMRig binary |
| `/opt/xmrig/config.json` | Generated configuration |
| `/opt/xmrig/backup/` | Previous version (binary + config) |
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
