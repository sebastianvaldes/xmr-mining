#!/usr/bin/env bash
# =============================================================================
#  XMR Mining - installs or updates XMRig as a systemd service (Ubuntu x64)
#
#  Usage (on the machine to install/update):
#    curl -fsSL https://raw.githubusercontent.com/sebastianvaldes/xmr-mining/main/mine-xmr.sh | sudo bash
#  Choosing the pool profile without the menu:
#    curl -fsSL https://raw.githubusercontent.com/sebastianvaldes/xmr-mining/main/mine-xmr.sh | sudo bash -s -- <profile>
#
#  What it does:
#    0. Checks CPU and RAM before changing anything, then selects the pool
#       profile (config/pools/<profile>.json in the repo)
#    1. Updates the operating system (apt)
#    2. Downloads the latest XMRig release from GitHub (verifies SHA256)
#    3. Builds /opt/xmrig/config.json from config/base.json + the pool profile
#       (worker = hostname)
#    4. Configures huge pages (2MB and 1GB) and the MSR module
#    5. Creates/updates and enables xmrig.service
#    6. Tests the service by following its log live
#       - OK    -> keeps running; asks to reboot only when needed
#       - Error -> disables the service, restores the previous version and reports
# =============================================================================

set -Eeuo pipefail

# ---------- Settings ----------------------------------------------------------
REPO_RAW="${XMR_REPO_RAW:-https://raw.githubusercontent.com/sebastianvaldes/xmr-mining/main}"
PROFILE_ARG="${1:-}"      # optional pool profile passed as: bash -s -- <profile>

INSTALL_DIR="/opt/xmrig"
BACKUP_DIR="$INSTALL_DIR/backup"
PROFILE_FILE="$INSTALL_DIR/profile"   # pool profile currently installed
SERVICE_NAME="xmrig"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
SYSCTL_FILE="/etc/sysctl.d/99-xmrig-hugepages.conf"
GRUB_FILE="/etc/default/grub.d/99-xmrig-hugepages.cfg"
MODULES_FILE="/etc/modules-load.d/xmrig-msr.conf"
LOG="$INSTALL_DIR/$(date +%F)-xmr-mining-install.log"
LOG_KEEP=20               # number of installer logs to keep

XMRIG_API="https://api.github.com/repos/xmrig/xmrig/releases/latest"
TEST_TIMEOUT=60           # max seconds waiting for a pool connection or an error

# ---------- State -------------------------------------------------------------
STEP_MSG=""
INSTALLED_NEW=0           # 1 once files in /opt/xmrig have been replaced
REBOOT_REASONS=()
TMP=""

# ---------- Screen output -----------------------------------------------------
if [[ -t 1 ]]; then
  C_OK=$'\e[32m'; C_ERR=$'\e[31m'; C_WARN=$'\e[33m'; C_DIM=$'\e[2m'; C_B=$'\e[1m'; C_0=$'\e[0m'
  CLR=$'\r\e[K'; IS_TTY=1
else
  C_OK=""; C_ERR=""; C_WARN=""; C_DIM=""; C_B=""; C_0=""; CLR=""; IS_TTY=0
fi

# Starts a step: leaves the "▶ ..." line open until the step completes.
step() {
  STEP_MSG="$1"
  printf '  %s▶%s %s...' "$C_B" "$C_0" "$STEP_MSG"
  (( IS_TTY )) || printf '\n'
  printf '\n=== %s\n' "$STEP_MSG" >>"$LOG"
}
# Rewrites the current step line with a progress text.
progress() {
  (( IS_TTY )) && printf '%s  %s▶%s %s... %s%s%s' "$CLR" "$C_B" "$C_0" "$STEP_MSG" "$C_DIM" "$1" "$C_0"
  return 0
}
# Marks the current step as completed (with optional detail).
ok() {
  printf '%s  %s✔%s %s%s\n' "$CLR" "$C_OK" "$C_0" "$STEP_MSG" "${1:+ ${C_DIM}($1)${C_0}}"
  STEP_MSG=""
}
# Marks the current step as completed with a warning.
ok_warn() {
  printf '%s  %s⚠%s %s%s\n' "$CLR" "$C_WARN" "$C_0" "$STEP_MSG" "${1:+ ${C_WARN}($1)${C_0}}"
  STEP_MSG=""
}
# Marks the current step as failed.
fail_step() {
  printf '%s  %s✖%s %s%s\n' "$CLR" "$C_ERR" "$C_0" "$STEP_MSG" "${1:+ ${C_ERR}($1)${C_0}}"
  STEP_MSG=""
}
# Info line below a step (without closing the current step).
info() {
  printf '%s      %s%s%s\n' "$CLR" "$C_DIM" "$*" "$C_0"
  [[ -n $STEP_MSG ]] && progress ""
  return 0
}
warn() {
  printf '%s      %s%s%s\n' "$CLR" "$C_WARN" "$*" "$C_0"
  [[ -n $STEP_MSG ]] && progress ""
  return 0
}
die() {
  printf '%s%sError:%s %s\n' "$CLR" "$C_ERR" "$C_0" "$*" >&2
  exit 1
}

# Runs a long command in the background, showing the elapsed time.
run() {
  local start=$SECONDS pid
  ( trap - ERR; "$@" ) >>"$LOG" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    progress "$((SECONDS - start))s"
    sleep 1
  done
  wait "$pid"
}

# Writes a file only if its content changed. Returns 0 if it was written.
write_if_changed() {
  local file=$1 content=$2
  if [[ -f $file ]] && [[ "$(cat "$file")" == "$content" ]]; then
    return 1
  fi
  mkdir -p "$(dirname "$file")"
  printf '%s\n' "$content" >"$file"
  return 0
}

# ---------- Rollback and error handling ---------------------------------------
rollback() {
  echo
  echo "  Disabling the service autostart..."
  systemctl stop "$SERVICE_NAME" >>"$LOG" 2>&1 || true
  systemctl disable "$SERVICE_NAME" >>"$LOG" 2>&1 || true
  if [[ -f $BACKUP_DIR/xmrig || -f $BACKUP_DIR/config.json ]]; then
    echo "  Restoring the previous XMRig version, config.json and pool profile..."
    [[ -f $BACKUP_DIR/xmrig ]]       && cp -a "$BACKUP_DIR/xmrig" "$INSTALL_DIR/xmrig"
    [[ -f $BACKUP_DIR/config.json ]] && cp -a "$BACKUP_DIR/config.json" "$INSTALL_DIR/config.json"
    [[ -f $BACKUP_DIR/profile ]]     && cp -a "$BACKUP_DIR/profile" "$PROFILE_FILE"
  fi
  echo
  echo "  The service is now ${C_B}disabled${C_0}. Once the problem is fixed, run the"
  echo "  install command again."
}

on_error() {
  local code=$? line=$1
  trap - ERR
  [[ -n $STEP_MSG ]] && fail_step
  echo
  echo "${C_ERR}A command failed (line $line, exit code $code).${C_0} Last lines of the log:"
  tail -n 20 "$LOG" 2>/dev/null | sed 's/^/    /'
  echo "  Full log: $LOG"
  (( INSTALLED_NEW )) && rollback
  exit 1
}
trap 'on_error $LINENO' ERR

cleanup() { [[ -n $TMP && -d $TMP ]] && rm -rf "$TMP"; return 0; }
trap cleanup EXIT

# =============================================================================
#  Pre-flight checks
# =============================================================================
[[ $EUID -eq 0 ]] || die "must run as root: curl -fsSL <url> | sudo bash"
[[ -r /etc/os-release ]] && . /etc/os-release
[[ ${ID:-} == ubuntu ]] || die "this script only supports Ubuntu (detected: ${PRETTY_NAME:-unknown})"
[[ $(uname -m) == x86_64 ]] || die "this script only supports x86_64 (detected: $(uname -m))"
command -v systemctl >/dev/null || die "systemd is not available"
[[ -z $PROFILE_ARG || $PROFILE_ARG =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid profile name: $PROFILE_ARG"
# GitHub API URL that lists config/pools, derived from REPO_RAW (.../<owner>/<repo>/<branch>).
if [[ $REPO_RAW =~ ^https://raw\.githubusercontent\.com/([^/]+)/([^/]+)/(.+)$ ]]; then
  PROFILES_API="https://api.github.com/repos/${BASH_REMATCH[1]}/${BASH_REMATCH[2]}/contents/config/pools?ref=${BASH_REMATCH[3]}"
else
  die "XMR_REPO_RAW must look like https://raw.githubusercontent.com/<owner>/<repo>/<branch>"
fi

export DEBIAN_FRONTEND=noninteractive
TMP=$(mktemp -d)
WORKER=$(hostname | tr '[:lower:]' '[:upper:]')
mkdir -p "$INSTALL_DIR"
# Several runs on the same day are appended to that day's log.
printf '\n########## XMR Mining - %s - %s ##########\n' "$(date '+%F %T')" "$WORKER" >>"$LOG"
# Keep only the last $LOG_KEEP installer logs.
ls -1t "$INSTALL_DIR"/*-xmr-mining-install.log 2>/dev/null | tail -n +$((LOG_KEEP + 1)) | xargs -r rm -f || true

echo
echo "${C_B}XMR Mining${C_0} - XMRig install / update"
echo "${C_DIM}  Host: $WORKER · ${PRETTY_NAME} · log: $LOG${C_0}"
echo

APT_OPTS=(-o DPkg::Lock::Timeout=600 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

# =============================================================================
#  0. Hardware requirements: checked before changing anything
# =============================================================================
step "Checking CPU and RAM"
threads=$(nproc)
nodes=$(find /sys/devices/system/node -maxdepth 1 -name 'node[0-9]*' 2>/dev/null | wc -l)
(( nodes > 0 )) || nodes=1
mem_mb=$(awk '/^MemTotal:/ {print int($2 / 1024)}' /proc/meminfo)

# Per NUMA node RandomX uses: a 2080 MB dataset + a 256 MB cache, plus 2 MB per thread.
# - With 1GB pages: the dataset goes in 3 x 1GB pages; cache and threads in 2MB pages.
# - Without 1GB pages: everything goes in 2MB pages.
if grep -qw pdpe1gb /proc/cpuinfo; then
  gb_pages=$(( 3 * nodes ))
  pages_2m=$(( 128 * nodes + threads + 16 ))
else
  gb_pages=0
  pages_2m=$(( 1168 * nodes + threads + 16 ))
fi
need_mb=$(( gb_pages * 1024 + pages_2m * 2 ))   # RAM reserved for huge pages
min_mb=$(( need_mb + 1536 ))                     # + headroom for the OS
rec_gb=$(( (need_mb + 2048 + 1023) / 1024 ))     # RAM to assign to the VM (rounded up)
printf 'threads=%s nodes=%s mem_mb=%s gb_pages=%s pages_2m=%s need_mb=%s min_mb=%s\n' \
  "$threads" "$nodes" "$mem_mb" "$gb_pages" "$pages_2m" "$need_mb" "$min_mb" >>"$LOG"

if (( mem_mb < min_mb )); then
  fail_step "not enough RAM"
  echo
  echo "  Available RAM: ${C_B}${mem_mb} MB${C_0} · required: ${C_B}${min_mb} MB${C_0}"
  echo "  (${need_mb} MB reserved for XMRig + ~1.5 GB for the operating system)"
  echo
  echo "  ${C_WARN}→ Assign at least ${rec_gb} GB of RAM to the VM and run the command again.${C_0}"
  echo "  No system changes were made (only this run's log was written to $INSTALL_DIR)."
  exit 1
fi
if (( gb_pages > 0 )); then
  ok "$threads threads, $mem_mb MB RAM, 1GB pages supported"
else
  ok_warn "$threads threads, $mem_mb MB RAM, CPU does not expose 1GB pages"
  warn "On a VM, setting the CPU type to 'host' enables 1GB pages (higher hashrate)."
fi

# =============================================================================
#  0b. Pool profile: asked up front so the rest runs unattended
#      Priority: argument > menu (if there is a terminal) > current profile
# =============================================================================
step "Looking up pool profiles in the repo"
profiles_json=$(curl -fsSL -H 'Accept: application/vnd.github+json' "$PROFILES_API") \
  || { fail_step; die "could not list config/pools in the repo ($PROFILES_API)"; }
mapfile -t available < <(grep -oE '"name": *"[A-Za-z0-9._-]+\.json"' <<<"$profiles_json" \
  | sed -E 's/.*"([^"]+)\.json"$/\1/' | sort)
(( ${#available[@]} )) || { fail_step; die "no profiles found in config/pools"; }
ok "${#available[@]} available"

in_list() { local p; for p in "${available[@]}"; do [[ $p == "$1" ]] && return 0; done; return 1; }

current_profile=""
[[ -f $PROFILE_FILE ]] && current_profile=$(tr -d '[:space:]' <"$PROFILE_FILE")
current_valid=0
[[ -n $current_profile ]] && in_list "$current_profile" && current_valid=1
printf 'profiles=%s current=%s valid=%s arg=%s\n' "${available[*]}" "$current_profile" "$current_valid" "$PROFILE_ARG" >>"$LOG"

PROFILE=""
if [[ -n $PROFILE_ARG ]]; then
  in_list "$PROFILE_ARG" || die "profile '$PROFILE_ARG' not found. Available: ${available[*]}"
  PROFILE=$PROFILE_ARG
elif { exec 3</dev/tty; } 2>/dev/null; then
  # Menu: option 1 is the current profile (if it still exists), the rest in alphabetical order.
  menu=()
  (( current_valid )) && menu+=("$current_profile")
  for p in "${available[@]}"; do
    (( current_valid )) && [[ $p == "$current_profile" ]] && continue
    menu+=("$p")
  done
  echo
  if [[ -n $current_profile ]] && (( ! current_valid )); then
    echo "  ${C_WARN}⚠ Current profile \"$current_profile\" no longer exists in the repo.${C_0}"
  fi
  echo "  Available pool profiles:"
  for i in "${!menu[@]}"; do
    label=""
    (( i == 0 && current_valid )) && label="   ${C_DIM}(current)${C_0}"
    printf '    %d) %s%s\n' "$((i + 1))" "${menu[$i]}" "$label"
  done
  while [[ -z $PROFILE ]]; do
    if (( current_valid )); then printf '  Select profile [1]: '; else printf '  Select profile: '; fi
    read -r choice <&3 || die "no answer received"
    [[ -z $choice ]] && (( current_valid )) && choice=1
    if [[ $choice =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#menu[@]} )); then
      PROFILE=${menu[choice - 1]}
    elif [[ -n $choice ]] && in_list "$choice"; then
      PROFILE=$choice
    else
      echo "  ${C_WARN}Invalid option, choose a number from 1 to ${#menu[@]}.${C_0}"
    fi
  done
  exec 3<&-
  echo
elif (( current_valid )); then
  PROFILE=$current_profile
else
  die "no terminal to ask for a pool profile and no valid current profile.
  Pass it as an argument: curl -fsSL <url> | sudo bash -s -- <profile>
  Available: ${available[*]}"
fi

step "Pool profile"
if [[ -n $current_profile && $PROFILE != "$current_profile" ]]; then
  ok "$PROFILE, changing from $current_profile"
else
  ok "$PROFILE"
fi

# =============================================================================
#  1. Operating system
# =============================================================================
step "Updating package lists (apt update)"
run apt-get "${APT_OPTS[@]}" update
ok

step "Upgrading the operating system (apt upgrade)"
pending=$(apt-get -s --with-new-pkgs upgrade 2>/dev/null | grep -c '^Inst ' || true)
run dpkg --configure -a
run apt-get "${APT_OPTS[@]}" -y --with-new-pkgs upgrade
ok "${pending:-0} packages upgraded"

step "Installing dependencies"
run apt-get "${APT_OPTS[@]}" -y install --no-install-recommends curl jq tar ca-certificates
ok

# =============================================================================
#  2. XMRig: latest release published on GitHub
# =============================================================================
step "Looking up the latest XMRig release on GitHub"
release_json=$(curl -fsSL -H 'Accept: application/vnd.github+json' "$XMRIG_API")
latest_ver=$(jq -r '.tag_name' <<<"$release_json")
latest_ver=${latest_ver#v}
asset_name=$(jq -r '.assets[].name | select(test("^xmrig-.*-linux-static-x64\\.tar\\.gz$"))' <<<"$release_json" | head -n1)
asset_url=$(jq -r --arg n "$asset_name" '.assets[] | select(.name == $n) | .browser_download_url' <<<"$release_json")
sums_url=$(jq -r '.assets[] | select(.name == "SHA256SUMS") | .browser_download_url' <<<"$release_json")
[[ -n $asset_name && -n $asset_url ]] || { fail_step; die "linux-static-x64 binary not found in release $latest_ver"; }

current_ver=""
if [[ -x $INSTALL_DIR/xmrig ]]; then
  current_ver=$("$INSTALL_DIR/xmrig" --version 2>/dev/null | awk 'NR==1 {print $2}' || true)
fi
if [[ $current_ver == "$latest_ver" ]]; then
  ok "v$latest_ver, already installed"
  NEED_DOWNLOAD=0
else
  ok "v$latest_ver${current_ver:+, installed: v$current_ver}"
  NEED_DOWNLOAD=1
fi

if (( NEED_DOWNLOAD )); then
  step "Downloading XMRig v$latest_ver"
  run curl -fsSL -o "$TMP/$asset_name" "$asset_url"
  ok

  step "Verifying SHA256 checksum"
  if [[ -n $sums_url ]]; then
    curl -fsSL -o "$TMP/SHA256SUMS" "$sums_url"
    expected=$(grep -F "$asset_name" "$TMP/SHA256SUMS" | awk '{print tolower($1)}' | head -n1 || true)
    actual=$(sha256sum "$TMP/$asset_name" | awk '{print $1}')
    if [[ -z $expected ]]; then
      ok_warn "the release does not publish a hash for this file"
    elif [[ $expected != "$actual" ]]; then
      fail_step "mismatch"
      die "the SHA256 of the downloaded file does not match the published one. Installation aborted."
    else
      ok
    fi
  else
    ok_warn "the release does not publish SHA256SUMS"
  fi

  step "Extracting XMRig"
  tar -xzf "$TMP/$asset_name" -C "$TMP"
  new_bin=$(find "$TMP" -type f -name xmrig -perm -u+x | head -n1)
  [[ -n $new_bin ]] || { fail_step; die "xmrig executable not found inside the archive"; }
  ok
fi

# =============================================================================
#  3. config.json = config/base.json + config/pools/<profile>.json
# =============================================================================
step "Downloading the configuration from the repo"
# The query parameter keeps GitHub's CDN from serving a cached copy.
ts=$(date +%s)
curl -fsSL -o "$TMP/base.json" "$REPO_RAW/config/base.json?t=$ts"
curl -fsSL -o "$TMP/profile.json" "$REPO_RAW/config/pools/$PROFILE.json?t=$ts"
jq -e '.pools | type == "array" and length > 0' "$TMP/profile.json" >/dev/null 2>>"$LOG" \
  || { fail_step; die "config/pools/$PROFILE.json is not valid JSON or has no \"pools\" list"; }
jq -s --arg w "$WORKER" '(.[0] * .[1]) | (.pools[].user) |= gsub("\\{\\{WORKER\\}\\}"; $w)' \
  "$TMP/base.json" "$TMP/profile.json" >"$TMP/config.json" 2>>"$LOG" \
  || { fail_step; die "config/base.json is not valid JSON"; }
if jq -e '[.pools[].user] | any(test("\\{\\{|^\\s*$"))' "$TMP/config.json" >/dev/null; then
  fail_step; die "config/pools/$PROFILE.json has an empty pool user or unreplaced variables"
fi
pool_url=$(jq -r '.pools[0].url' "$TMP/config.json")
if [[ -f $INSTALL_DIR/config.json ]] && cmp -s "$TMP/config.json" "$INSTALL_DIR/config.json"; then
  ok "unchanged"
else
  ok "pool $pool_url, worker $WORKER"
fi

# =============================================================================
#  4. Install into /opt/xmrig (backing up the previous version)
# =============================================================================
step "Installing into $INSTALL_DIR"
if systemctl is-active --quiet "$SERVICE_NAME"; then
  systemctl stop "$SERVICE_NAME" >>"$LOG" 2>&1
fi
mkdir -p "$INSTALL_DIR"
rm -rf "$BACKUP_DIR"
mkdir -p "$BACKUP_DIR"
[[ -f $INSTALL_DIR/xmrig ]]       && cp -a "$INSTALL_DIR/xmrig" "$BACKUP_DIR/"
[[ -f $INSTALL_DIR/config.json ]] && cp -a "$INSTALL_DIR/config.json" "$BACKUP_DIR/"
[[ -f $PROFILE_FILE ]]            && cp -a "$PROFILE_FILE" "$BACKUP_DIR/"
INSTALLED_NEW=1
(( NEED_DOWNLOAD )) && install -m 755 "$new_bin" "$INSTALL_DIR/xmrig"
install -m 644 "$TMP/config.json" "$INSTALL_DIR/config.json"
printf '%s\n' "$PROFILE" >"$PROFILE_FILE"
if [[ -n $(ls -A "$BACKUP_DIR") ]]; then ok "backup in $BACKUP_DIR"; else ok; fi

# =============================================================================
#  5. Huge pages and MSR
# =============================================================================
step "Configuring huge pages and MSR"
hp_note=""

# 2MB pages: applied live through sysctl.
if write_if_changed "$SYSCTL_FILE" "# Generated by XMR Mining: 2MB huge pages for RandomX
vm.nr_hugepages = $pages_2m"; then
  info "vm.nr_hugepages = $pages_2m"
fi
sysctl -q -p "$SYSCTL_FILE" >>"$LOG" 2>&1 || true
got_2m=$(cat /proc/sys/vm/nr_hugepages)
if (( got_2m < pages_2m )); then
  REBOOT_REASONS+=("2MB huge pages: only $got_2m of $pages_2m reserved (fragmented memory)")
fi

# 1GB pages: only reliably reserved at boot (kernel parameter).
if (( gb_pages > 0 )); then
  if grep -q 'hugepagesz=1G' /etc/default/grub 2>/dev/null; then
    info "1GB huge pages already configured in /etc/default/grub"
  elif ! command -v update-grub >/dev/null; then
    hp_note="no GRUB, 1GB pages not configured"
  elif write_if_changed "$GRUB_FILE" "# Generated by XMR Mining: 1GB huge pages for RandomX
GRUB_CMDLINE_LINUX_DEFAULT=\"\$GRUB_CMDLINE_LINUX_DEFAULT hugepagesz=1G hugepages=$gb_pages\""; then
    run update-grub
    info "1GB huge pages: $gb_pages (kernel parameter)"
    REBOOT_REASONS+=("1GB huge pages just configured in the kernel")
  fi
elif [[ -f $GRUB_FILE ]]; then
  rm -f "$GRUB_FILE"
  run update-grub
fi

# MSR module: XMRig uses it to tune the CPU (requires root).
write_if_changed "$MODULES_FILE" "msr" || true
modprobe msr >>"$LOG" 2>&1 || true

if [[ -n $hp_note ]]; then
  ok_warn "$hp_note"
elif (( gb_pages > 0 )); then
  ok "$pages_2m × 2MB + $gb_pages × 1GB"
else
  ok "$pages_2m × 2MB, CPU does not support 1GB pages"
fi

# =============================================================================
#  6. systemd service
# =============================================================================
step "Configuring the $SERVICE_NAME service"
unit="[Unit]
Description=XMRig Monero miner
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/xmrig --config=$INSTALL_DIR/config.json
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target"
write_if_changed "$SERVICE_FILE" "$unit" || true
systemctl daemon-reload
systemctl enable "$SERVICE_NAME" >>"$LOG" 2>&1
ok "enabled at boot"

# =============================================================================
#  7. Test: start the service and follow its log live
# =============================================================================
step "Testing the service"
systemctl stop "$SERVICE_NAME" >>"$LOG" 2>&1 || true
sleep 1
since=$(date '+%Y-%m-%d %H:%M:%S')
systemctl start "$SERVICE_NAME"

exec {JFD}< <(timeout "$TEST_TIMEOUT" journalctl -u "$SERVICE_NAME" --since "$since" -f -o cat --no-pager 2>/dev/null)
JPID=$!
result="timeout"
error_lines=()
t0=$SECONDS
shopt -s nocasematch
re_ok='new job from'
re_err='(connect|login|read|dns|tls|socket) error|no active pools|unable to open|no valid configuration|main process exited|failed with result|illegal instruction|segmentation fault|core dumped'
re_warn='failed|0%|unavailable|disabled|cannot|not supported'
re_show='huge pages|1gb pages|msr|use pool|randomx .*(allocated|init)|cpu .*threads'

while true; do
  if IFS= read -r -t 1 -u "$JFD" line; then
    line=$(sed 's/\x1b\[[0-9;]*m//g' <<<"$line")
    printf '%s\n' "$line" >>"$LOG"
    if [[ $line =~ $re_err ]]; then
      error_lines+=("$line"); result="error"; break
    elif [[ $line =~ $re_ok ]]; then
      info "$line"; result="ok"; break
    elif [[ $line =~ $re_show ]]; then
      if [[ $line =~ $re_warn ]]; then warn "$line"; else info "$line"; fi
    fi
  else
    (( $? > 128 )) || break        # EOF: the timeout was reached
  fi
  progress "waiting for pool connection ($((SECONDS - t0))s)"
done
shopt -u nocasematch
kill "$JPID" 2>/dev/null || true
exec {JFD}<&-

case $result in
  ok)
    ok "connected to the pool in $((SECONDS - t0))s"
    ;;
  *)
    if [[ $result == timeout ]]; then
      fail_step "no pool connection within ${TEST_TIMEOUT}s"
    else
      fail_step "error detected"
    fi
    echo
    echo "  ${C_ERR}Errors found:${C_0}"
    for l in "${error_lines[@]}"; do echo "    $l"; done
    echo "  Last lines from the service:"
    journalctl -u "$SERVICE_NAME" --since "$since" -n 15 -o cat --no-pager 2>/dev/null \
      | sed 's/\x1b\[[0-9;]*m//g; s/^/    /'
    trap - ERR
    rollback
    exit 1
    ;;
esac

# =============================================================================
#  8. Remove previous installs (old layout in /home/*/xmrig)
#     The whole folder is deleted, with all its contents.
# =============================================================================
old_dirs=()
for d in /home/*/xmrig /root/xmrig; do
  [[ -f $d/start-xmrig.sh ]] && old_dirs+=("$d")
done
if (( ${#old_dirs[@]} )); then
  step "Removing the previous install"
  for d in "${old_dirs[@]}"; do
    rm -rf "$d"
    info "removed $d"
  done
  ok
fi

# =============================================================================
#  9. Summary and reboot (only when needed)
# =============================================================================
if [[ -f /var/run/reboot-required ]]; then
  pkgs=""
  [[ -f /var/run/reboot-required.pkgs ]] && pkgs=$(sort -u /var/run/reboot-required.pkgs | paste -sd ',' | sed 's/,/, /g')
  REBOOT_REASONS+=("system updates${pkgs:+: $pkgs}")
fi

echo
echo "${C_OK}${C_B}Done.${C_0} XMRig v$latest_ver is mining as a service."
echo "${C_DIM}  Profile: $PROFILE · Worker: $WORKER · Pool: $pool_url"
echo "  Live log:       journalctl -fu $SERVICE_NAME"
echo "  Service status: systemctl status $SERVICE_NAME${C_0}"
echo

if (( ${#REBOOT_REASONS[@]} )); then
  echo "${C_WARN}A reboot is recommended:${C_0}"
  for r in "${REBOOT_REASONS[@]}"; do echo "  - $r"; done
  if { exec 3</dev/tty; } 2>/dev/null; then
    printf '\nReboot now? [y/N] '
    read -r answer <&3 || answer=""
    exec 3<&-
    if [[ $answer =~ ^[yYsS] ]]; then
      echo "Rebooting..."
      reboot
    else
      echo "Not rebooting. Remember to reboot later: sudo reboot"
    fi
  else
    echo "Reboot when possible: sudo reboot"
  fi
else
  echo "${C_DIM}No reboot needed.${C_0}"
fi
