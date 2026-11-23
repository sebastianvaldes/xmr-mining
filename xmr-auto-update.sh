#!/usr/bin/env bash
# =============================================================================
#  XMR Mining - automatic updater
#
#  Installed by mine-xmr.sh in /opt/xmrig when the "auto" profile is chosen,
#  and run every hour by xmrig-auto-update.timer. It:
#    - reads config/auto in the repo: a pool profile name, or "stop"
#    - "stop": stops and disables the miner (it keeps checking every hour)
#    - a profile: builds config.json and installs new XMRig releases,
#      restarts the miner and tests it; if the test fails it goes back to
#      what was running before (or stays stopped)
#
#  It only downloads JSON files and the official XMRig release (SHA256
#  verified); it never runs code downloaded from the repo. It does not touch
#  the operating system, huge pages or GRUB: that is mine-xmr.sh's job.
#
#  Log: journalctl -u xmrig-auto-update
# =============================================================================

set -uo pipefail

INSTALL_DIR="/opt/xmrig"
BACKUP_DIR="$INSTALL_DIR/backup"
PROFILE_FILE="$INSTALL_DIR/profile"        # "auto" while this updater is in charge
REPO_FILE="$INSTALL_DIR/repo"              # raw base URL of the repo (main or a test branch)
CURRENT_FILE="$INSTALL_DIR/auto-current"   # what is applied now: a profile name or "stop"
FAILED_FILE="$INSTALL_DIR/auto-failed"     # last attempt that failed (not retried until it changes)
LOCK_FILE="/run/xmr-mining.lock"           # shared with mine-xmr.sh
SERVICE_NAME="xmrig"
XMRIG_LATEST="https://github.com/xmrig/xmrig/releases/latest"
XMRIG_DOWNLOAD="https://github.com/xmrig/xmrig/releases/download"
TEST_TIMEOUT=60

log() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*"; exit 1; }

# Only one run at a time; if mine-xmr.sh is running, skip this round.
exec 9>"$LOCK_FILE"
flock -n 9 || { log "Another XMR Mining run is in progress, skipping."; exit 0; }

[[ $(tr -d '[:space:]' <"$PROFILE_FILE" 2>/dev/null) == auto ]] \
  || { log "Profile is not 'auto', nothing to do."; exit 0; }
REPO_RAW=$(tr -d '[:space:]' <"$REPO_FILE" 2>/dev/null)
[[ $REPO_RAW =~ ^https://raw\.githubusercontent\.com/ ]] || die "invalid repo URL in $REPO_FILE"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
WORKER=$(hostname | tr '[:lower:]' '[:upper:]')
ts=$(date +%s)   # keeps GitHub's CDN from serving a cached copy

# ---------- What should be running -------------------------------------------
target=$(curl -fsSL "$REPO_RAW/config/auto?t=$ts" | tr -d '[:space:]') \
  || die "could not download config/auto from the repo"
[[ $target =~ ^[A-Za-z0-9._-]+$ ]] || die "config/auto has an invalid value: '$target'"
current=$(tr -d '[:space:]' <"$CURRENT_FILE" 2>/dev/null || true)

# ---------- stop --------------------------------------------------------------
if [[ $target == stop ]]; then
  if systemctl is-active --quiet "$SERVICE_NAME" || systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
    systemctl disable --now "$SERVICE_NAME"
    log "config/auto is 'stop': mining stopped (was: ${current:-unknown})."
  else
    log "config/auto is 'stop': mining already stopped."
  fi
  printf 'stop\n' >"$CURRENT_FILE"
  rm -f "$FAILED_FILE"
  exit 0
fi

# ---------- Build config.json = base.json + pools/<target>.json --------------
curl -fsSL -o "$TMP/base.json" "$REPO_RAW/config/base.json?t=$ts" \
  || die "could not download config/base.json"
curl -fsSL -o "$TMP/profile.json" "$REPO_RAW/config/pools/$target.json?t=$ts" \
  || die "config/auto points to '$target', but config/pools/$target.json could not be downloaded"
jq -e '.pools | type == "array" and length > 0' "$TMP/profile.json" >/dev/null 2>&1 \
  || die "config/pools/$target.json is not valid JSON or has no \"pools\" list"
jq -s --arg w "$WORKER" '(.[0] * .[1]) | (.pools[].user) |= gsub("\\{\\{WORKER\\}\\}"; $w)' \
  "$TMP/base.json" "$TMP/profile.json" >"$TMP/config.json" 2>/dev/null \
  || die "config/base.json is not valid JSON"
if jq -e '[.pools[].user] | any(test("\\{\\{|^\\s*$"))' "$TMP/config.json" >/dev/null; then
  die "config/pools/$target.json has an empty pool user or unreplaced variables"
fi
config_changed=1
cmp -s "$TMP/config.json" "$INSTALL_DIR/config.json" 2>/dev/null && config_changed=0

# ---------- Latest XMRig release ----------------------------------------------
# Read from the redirect of the releases page (not the GitHub API, which is
# limited to 60 requests per hour per public IP).
installed_ver=$("$INSTALL_DIR/xmrig" --version 2>/dev/null | awk 'NR==1 {print $2}' || true)
latest_url=$(curl -fsSI -o /dev/null -w '%{redirect_url}' "$XMRIG_LATEST" || true)
latest_ver=""
[[ $latest_url =~ /tag/v([0-9][0-9A-Za-z.-]*)$ ]] && latest_ver=${BASH_REMATCH[1]}
binary_changed=0
if [[ -z $latest_ver ]]; then
  log "WARNING: could not find the latest XMRig version; keeping v${installed_ver:-?}."
elif [[ $latest_ver != "$installed_ver" ]]; then
  binary_changed=1
fi

# ---------- Anything to do? ---------------------------------------------------
running=0
systemctl is-active --quiet "$SERVICE_NAME" && systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null && running=1
if (( ! config_changed && ! binary_changed && running )) && [[ $current == "$target" ]]; then
  log "No changes ($target, XMRig v$installed_ver)."
  rm -f "$FAILED_FILE"
  exit 0
fi

# An attempt that already failed is not retried until something changes in the
# repo or a new XMRig release is published.
attempt="$target $(sha256sum "$TMP/config.json" | awk '{print $1}') ${latest_ver:-$installed_ver}"
if [[ -f $FAILED_FILE && $(cat "$FAILED_FILE") == "$attempt" ]]; then
  log "Same change as a previous failed attempt ($target, XMRig v${latest_ver:-$installed_ver}); waiting for a change in the repo."
  exit 0
fi

# ---------- Download the new XMRig (SHA256 verified) --------------------------
if (( binary_changed )); then
  asset="xmrig-$latest_ver-linux-static-x64.tar.gz"
  curl -fsSL -o "$TMP/$asset" "$XMRIG_DOWNLOAD/v$latest_ver/$asset" || die "could not download $asset"
  curl -fsSL -o "$TMP/SHA256SUMS" "$XMRIG_DOWNLOAD/v$latest_ver/SHA256SUMS" || die "could not download SHA256SUMS"
  expected=$(grep -F "$asset" "$TMP/SHA256SUMS" | awk '{print tolower($1)}' | head -n1)
  actual=$(sha256sum "$TMP/$asset" | awk '{print $1}')
  [[ -n $expected && $expected == "$actual" ]] || die "SHA256 of $asset does not match the published one"
  tar -xzf "$TMP/$asset" -C "$TMP" || die "could not extract $asset"
  new_bin=$(find "$TMP" -type f -name xmrig -perm -u+x | head -n1)
  [[ -n $new_bin ]] || die "xmrig executable not found inside $asset"
fi

# ---------- Install (keeping a backup) ----------------------------------------
changes=()
[[ $current != "$target" ]] && changes+=("pool ${current:-?} -> $target")
(( config_changed )) && changes+=("config.json")
(( binary_changed )) && changes+=("XMRig v${installed_ver:-?} -> v$latest_ver")
(( running )) || changes+=("miner was not running")
log "Applying: $(IFS=,; printf '%s' "${changes[*]}" | sed 's/,/, /g')"

rm -rf "$BACKUP_DIR"; mkdir -p "$BACKUP_DIR"
[[ -f $INSTALL_DIR/xmrig ]]       && cp -a "$INSTALL_DIR/xmrig" "$BACKUP_DIR/"
[[ -f $INSTALL_DIR/config.json ]] && cp -a "$INSTALL_DIR/config.json" "$BACKUP_DIR/"
systemctl stop "$SERVICE_NAME" 2>/dev/null || true
(( binary_changed )) && install -m 755 "$new_bin" "$INSTALL_DIR/xmrig"
install -m 644 "$TMP/config.json" "$INSTALL_DIR/config.json"

# ---------- Test: start and follow the log (pool connected + miner READY) ----
since=$(date '+%Y-%m-%d %H:%M:%S')
systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
systemctl start "$SERVICE_NAME"
result="timeout"; connected=0; ready=0; error_line=""
re_err='(connect|login|read|dns|tls|socket) error|no active pools|unable to open|no valid configuration|main process exited|failed with result|illegal instruction|segmentation fault|core dumped'
shopt -s nocasematch
while IFS= read -r line; do
  line=$(sed 's/\x1b\[[0-9;]*m//g' <<<"$line")
  if [[ $line =~ $re_err ]]; then error_line=$line; result="error"; break; fi
  [[ $line =~ 'new job from' ]] && connected=1
  [[ $line =~ 'READY threads' ]] && ready=1
  if (( connected && ready )); then result="ok"; break; fi
done < <(timeout "$TEST_TIMEOUT" journalctl -u "$SERVICE_NAME" --since "$since" -f -o cat --no-pager 2>/dev/null)
shopt -u nocasematch
(( connected )) && [[ $result == timeout ]] && result="ok"   # connected; READY may just be slow

if [[ $result == ok ]]; then
  printf '%s\n' "$target" >"$CURRENT_FILE"
  rm -f "$FAILED_FILE"
  log "OK: mining on '$target' with XMRig v$("$INSTALL_DIR/xmrig" --version 2>/dev/null | awk 'NR==1 {print $2}')."
  exit 0
fi

# ---------- Failed: go back to what was there before --------------------------
log "FAILED: ${error_line:-no pool connection within ${TEST_TIMEOUT}s}"
printf '%s\n' "$attempt" >"$FAILED_FILE"
systemctl stop "$SERVICE_NAME" 2>/dev/null || true
[[ -f $BACKUP_DIR/xmrig ]]       && cp -a "$BACKUP_DIR/xmrig" "$INSTALL_DIR/xmrig"
[[ -f $BACKUP_DIR/config.json ]] && cp -a "$BACKUP_DIR/config.json" "$INSTALL_DIR/config.json"
if [[ $current == stop ]] || (( ! running )); then
  systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
  log "Restored the previous version; mining stays stopped."
else
  systemctl start "$SERVICE_NAME"
  log "Restored the previous version; mining on '$current' again."
fi
exit 1
