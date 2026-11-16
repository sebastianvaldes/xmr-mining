#!/usr/bin/env bash
# =============================================================================
#  XMR Mining - instala o actualiza XMRig como servicio systemd (Ubuntu x64)
#
#  Uso (en la máquina a instalar/actualizar):
#    curl -fsSL https://raw.githubusercontent.com/sebastianvaldes/xmr-mining/main/mine-xmr.sh | sudo bash
#
#  Qué hace:
#    1. Actualiza el sistema operativo (apt)
#    2. Descarga la última versión de XMRig publicada en GitHub (verifica SHA256)
#    3. Genera /opt/xmrig/config.json desde la plantilla del repo (worker = hostname)
#    4. Configura huge pages (2MB y 1GB) y el módulo MSR
#    5. Crea/actualiza y habilita el servicio xmrig.service
#    6. Prueba el servicio siguiendo el log en vivo
#       - OK    -> queda corriendo; pide reiniciar solo si hace falta
#       - Error -> deshabilita el servicio, restaura la versión anterior e informa
# =============================================================================

set -Eeuo pipefail

# ---------- Configuración -----------------------------------------------------
REPO_RAW="${XMR_REPO_RAW:-https://raw.githubusercontent.com/sebastianvaldes/xmr-mining/main}"
CONFIG_TEMPLATE_URL="$REPO_RAW/config/xmrig.json"

INSTALL_DIR="/opt/xmrig"
BACKUP_DIR="$INSTALL_DIR/backup"
SERVICE_NAME="xmrig"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
SYSCTL_FILE="/etc/sysctl.d/99-xmrig-hugepages.conf"
GRUB_FILE="/etc/default/grub.d/99-xmrig-hugepages.cfg"
MODULES_FILE="/etc/modules-load.d/xmrig-msr.conf"
LOG="$INSTALL_DIR/$(date +%F)-xmr-mining-install.log"
LOG_KEEP=20               # cantidad de logs del instalador que se conservan

XMRIG_API="https://api.github.com/repos/xmrig/xmrig/releases/latest"
TEST_TIMEOUT=60           # segundos máximos esperando conexión al pool o un error

# ---------- Estado ------------------------------------------------------------
STEP_MSG=""
INSTALLED_NEW=0           # 1 cuando ya se reemplazaron archivos en /opt/xmrig
REBOOT_REASONS=()
TMP=""

# ---------- Salida en pantalla ------------------------------------------------
if [[ -t 1 ]]; then
  C_OK=$'\e[32m'; C_ERR=$'\e[31m'; C_WARN=$'\e[33m'; C_DIM=$'\e[2m'; C_B=$'\e[1m'; C_0=$'\e[0m'
  CLR=$'\r\e[K'; IS_TTY=1
else
  C_OK=""; C_ERR=""; C_WARN=""; C_DIM=""; C_B=""; C_0=""; CLR=""; IS_TTY=0
fi

# Inicia un paso: deja la línea "▶ ..." abierta hasta que se complete.
step() {
  STEP_MSG="$1"
  printf '  %s▶%s %s...' "$C_B" "$C_0" "$STEP_MSG"
  (( IS_TTY )) || printf '\n'
  printf '\n=== %s\n' "$STEP_MSG" >>"$LOG"
}
# Reescribe la línea del paso en curso con un texto de progreso.
progress() {
  (( IS_TTY )) && printf '%s  %s▶%s %s... %s%s%s' "$CLR" "$C_B" "$C_0" "$STEP_MSG" "$C_DIM" "$1" "$C_0"
  return 0
}
# Marca el paso en curso como completado (con detalle opcional).
ok() {
  printf '%s  %s✔%s %s%s\n' "$CLR" "$C_OK" "$C_0" "$STEP_MSG" "${1:+ ${C_DIM}($1)${C_0}}"
  STEP_MSG=""
}
# Marca el paso en curso como completado con advertencia.
ok_warn() {
  printf '%s  %s⚠%s %s%s\n' "$CLR" "$C_WARN" "$C_0" "$STEP_MSG" "${1:+ ${C_WARN}($1)${C_0}}"
  STEP_MSG=""
}
# Marca el paso en curso como fallido.
fail_step() {
  printf '%s  %s✖%s %s%s\n' "$CLR" "$C_ERR" "$C_0" "$STEP_MSG" "${1:+ ${C_ERR}($1)${C_0}}"
  STEP_MSG=""
}
# Línea informativa debajo de un paso (sin cortar el paso en curso).
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

# Ejecuta un comando largo en segundo plano mostrando el tiempo transcurrido.
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

# Escribe un archivo solo si su contenido cambió. Devuelve 0 si lo escribió.
write_if_changed() {
  local file=$1 content=$2
  if [[ -f $file ]] && [[ "$(cat "$file")" == "$content" ]]; then
    return 1
  fi
  mkdir -p "$(dirname "$file")"
  printf '%s\n' "$content" >"$file"
  return 0
}

# ---------- Rollback y manejo de errores --------------------------------------
rollback() {
  echo
  echo "  Deshabilitando el inicio automático del servicio..."
  systemctl stop "$SERVICE_NAME" >>"$LOG" 2>&1 || true
  systemctl disable "$SERVICE_NAME" >>"$LOG" 2>&1 || true
  if [[ -f $BACKUP_DIR/xmrig || -f $BACKUP_DIR/config.json ]]; then
    echo "  Restaurando la versión anterior de XMRig y config.json..."
    [[ -f $BACKUP_DIR/xmrig ]]       && cp -a "$BACKUP_DIR/xmrig" "$INSTALL_DIR/xmrig"
    [[ -f $BACKUP_DIR/config.json ]] && cp -a "$BACKUP_DIR/config.json" "$INSTALL_DIR/config.json"
  fi
  echo
  echo "  El servicio quedó ${C_B}deshabilitado${C_0}. Una vez resuelto el problema, volvé a"
  echo "  ejecutar el comando de instalación."
}

on_error() {
  local code=$? line=$1
  trap - ERR
  [[ -n $STEP_MSG ]] && fail_step
  echo
  echo "${C_ERR}Falló un comando (línea $line, código $code).${C_0} Últimas líneas del log:"
  tail -n 20 "$LOG" 2>/dev/null | sed 's/^/    /'
  echo "  Log completo: $LOG"
  (( INSTALLED_NEW )) && rollback
  exit 1
}
trap 'on_error $LINENO' ERR

cleanup() { [[ -n $TMP && -d $TMP ]] && rm -rf "$TMP"; return 0; }
trap cleanup EXIT

# =============================================================================
#  Verificaciones previas
# =============================================================================
[[ $EUID -eq 0 ]] || die "hay que ejecutarlo como root: curl -fsSL <url> | sudo bash"
[[ -r /etc/os-release ]] && . /etc/os-release
[[ ${ID:-} == ubuntu ]] || die "este script es solo para Ubuntu (detectado: ${PRETTY_NAME:-desconocido})"
[[ $(uname -m) == x86_64 ]] || die "este script es solo para x86_64 (detectado: $(uname -m))"
command -v systemctl >/dev/null || die "systemd no está disponible"

export DEBIAN_FRONTEND=noninteractive
TMP=$(mktemp -d)
WORKER=$(hostname | tr '[:lower:]' '[:upper:]')
mkdir -p "$INSTALL_DIR"
# Si se ejecuta varias veces el mismo día, se agrega al log de ese día.
printf '\n########## XMR Mining - %s - %s ##########\n' "$(date '+%F %T')" "$WORKER" >>"$LOG"
# Conservar solo los últimos $LOG_KEEP logs del instalador.
ls -1t "$INSTALL_DIR"/*-xmr-mining-install.log 2>/dev/null | tail -n +$((LOG_KEEP + 1)) | xargs -r rm -f || true

echo
echo "${C_B}XMR Mining${C_0} - instalación / actualización de XMRig"
echo "${C_DIM}  Equipo: $WORKER · ${PRETTY_NAME} · log: $LOG${C_0}"
echo

APT_OPTS=(-o DPkg::Lock::Timeout=600 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

# =============================================================================
#  0. Requisitos de hardware: se verifica antes de tocar nada
# =============================================================================
step "Verificando CPU y memoria RAM"
threads=$(nproc)
nodes=$(find /sys/devices/system/node -maxdepth 1 -name 'node[0-9]*' 2>/dev/null | wc -l)
(( nodes > 0 )) || nodes=1
mem_mb=$(awk '/^MemTotal:/ {print int($2 / 1024)}' /proc/meminfo)

# RandomX usa por cada nodo NUMA: dataset de 2080 MB + cache de 256 MB, y 2 MB por hilo.
# - Con páginas de 1GB: el dataset va en 3 páginas de 1GB; cache e hilos en páginas de 2MB.
# - Sin páginas de 1GB: todo va en páginas de 2MB.
if grep -qw pdpe1gb /proc/cpuinfo; then
  gb_pages=$(( 3 * nodes ))
  pages_2m=$(( 128 * nodes + threads + 16 ))
else
  gb_pages=0
  pages_2m=$(( 1168 * nodes + threads + 16 ))
fi
need_mb=$(( gb_pages * 1024 + pages_2m * 2 ))   # RAM reservada para huge pages
min_mb=$(( need_mb + 1536 ))                     # + margen para el sistema operativo
rec_gb=$(( (need_mb + 2048 + 1023) / 1024 ))     # RAM a asignar a la VM (redondeada)
printf 'threads=%s nodes=%s mem_mb=%s gb_pages=%s pages_2m=%s need_mb=%s min_mb=%s\n' \
  "$threads" "$nodes" "$mem_mb" "$gb_pages" "$pages_2m" "$need_mb" "$min_mb" >>"$LOG"

if (( mem_mb < min_mb )); then
  fail_step "RAM insuficiente"
  echo
  echo "  RAM disponible: ${C_B}${mem_mb} MB${C_0} · necesaria: ${C_B}${min_mb} MB${C_0}"
  echo "  (${need_mb} MB reservados para XMRig + ~1.5 GB para el sistema operativo)"
  echo
  echo "  ${C_WARN}→ Asigná al menos ${rec_gb} GB de RAM a la VM y volvé a ejecutar el comando.${C_0}"
  echo "  No se modificó nada en el equipo."
  exit 1
fi
if (( gb_pages > 0 )); then
  ok "$threads hilos, $mem_mb MB de RAM, soporta páginas de 1GB"
else
  ok_warn "$threads hilos, $mem_mb MB de RAM, la CPU no expone páginas de 1GB"
  warn "En una VM, configurar el tipo de CPU como 'host' habilita las páginas de 1GB (más hashrate)."
fi

# =============================================================================
#  1. Sistema operativo
# =============================================================================
step "Actualizando la lista de paquetes (apt update)"
run apt-get "${APT_OPTS[@]}" update
ok

step "Actualizando el sistema operativo (apt upgrade)"
pending=$(apt-get -s --with-new-pkgs upgrade 2>/dev/null | grep -c '^Inst ' || true)
run dpkg --configure -a
run apt-get "${APT_OPTS[@]}" -y --with-new-pkgs upgrade
ok "${pending:-0} paquetes actualizados"

step "Instalando dependencias"
run apt-get "${APT_OPTS[@]}" -y install --no-install-recommends curl jq tar ca-certificates
ok

# =============================================================================
#  2. XMRig: última versión publicada en GitHub
# =============================================================================
step "Buscando la última versión de XMRig en GitHub"
release_json=$(curl -fsSL -H 'Accept: application/vnd.github+json' "$XMRIG_API")
latest_ver=$(jq -r '.tag_name' <<<"$release_json")
latest_ver=${latest_ver#v}
asset_name=$(jq -r '.assets[].name | select(test("^xmrig-.*-linux-static-x64\\.tar\\.gz$"))' <<<"$release_json" | head -n1)
asset_url=$(jq -r --arg n "$asset_name" '.assets[] | select(.name == $n) | .browser_download_url' <<<"$release_json")
sums_url=$(jq -r '.assets[] | select(.name == "SHA256SUMS") | .browser_download_url' <<<"$release_json")
[[ -n $asset_name && -n $asset_url ]] || { fail_step; die "no se encontró el binario linux-static-x64 en la release $latest_ver"; }

current_ver=""
if [[ -x $INSTALL_DIR/xmrig ]]; then
  current_ver=$("$INSTALL_DIR/xmrig" --version 2>/dev/null | awk 'NR==1 {print $2}' || true)
fi
if [[ $current_ver == "$latest_ver" ]]; then
  ok "v$latest_ver, ya instalada"
  NEED_DOWNLOAD=0
else
  ok "v$latest_ver${current_ver:+, instalada: v$current_ver}"
  NEED_DOWNLOAD=1
fi

if (( NEED_DOWNLOAD )); then
  step "Descargando XMRig v$latest_ver"
  run curl -fsSL -o "$TMP/$asset_name" "$asset_url"
  ok

  step "Verificando la firma SHA256"
  if [[ -n $sums_url ]]; then
    curl -fsSL -o "$TMP/SHA256SUMS" "$sums_url"
    expected=$(grep -F "$asset_name" "$TMP/SHA256SUMS" | awk '{print tolower($1)}' | head -n1 || true)
    actual=$(sha256sum "$TMP/$asset_name" | awk '{print $1}')
    if [[ -z $expected ]]; then
      ok_warn "la release no publica el hash de este archivo"
    elif [[ $expected != "$actual" ]]; then
      fail_step "no coincide"
      die "el SHA256 del archivo descargado no coincide con el publicado. Se canceló la instalación."
    else
      ok
    fi
  else
    ok_warn "la release no publica SHA256SUMS"
  fi

  step "Extrayendo XMRig"
  tar -xzf "$TMP/$asset_name" -C "$TMP"
  new_bin=$(find "$TMP" -type f -name xmrig -perm -u+x | head -n1)
  [[ -n $new_bin ]] || { fail_step; die "no se encontró el ejecutable xmrig dentro del archivo"; }
  ok
fi

# =============================================================================
#  3. config.json desde la plantilla del repo
# =============================================================================
step "Descargando la configuración del repo"
# El parámetro evita que el CDN de GitHub devuelva una versión cacheada.
curl -fsSL -o "$TMP/template.json" "${CONFIG_TEMPLATE_URL}?t=$(date +%s)"
jq --arg w "$WORKER" '(.pools[].user) |= gsub("\\{\\{WORKER\\}\\}"; $w)' \
  "$TMP/template.json" >"$TMP/config.json" 2>>"$LOG" \
  || { fail_step; die "la plantilla config/xmrig.json del repo no es un JSON válido"; }
if jq -e '[.pools[].user] | any(test("\\{\\{|^\\s*$"))' "$TMP/config.json" >/dev/null; then
  fail_step; die "la plantilla tiene un usuario de pool vacío o con variables sin reemplazar"
fi
pool_url=$(jq -r '.pools[0].url' "$TMP/config.json")
if [[ -f $INSTALL_DIR/config.json ]] && cmp -s "$TMP/config.json" "$INSTALL_DIR/config.json"; then
  ok "sin cambios"
else
  ok "pool $pool_url, worker $WORKER"
fi

# =============================================================================
#  4. Instalación en /opt/xmrig (con backup de la versión anterior)
# =============================================================================
step "Instalando en $INSTALL_DIR"
if systemctl is-active --quiet "$SERVICE_NAME"; then
  systemctl stop "$SERVICE_NAME" >>"$LOG" 2>&1
fi
mkdir -p "$INSTALL_DIR"
rm -rf "$BACKUP_DIR"
mkdir -p "$BACKUP_DIR"
[[ -f $INSTALL_DIR/xmrig ]]       && cp -a "$INSTALL_DIR/xmrig" "$BACKUP_DIR/"
[[ -f $INSTALL_DIR/config.json ]] && cp -a "$INSTALL_DIR/config.json" "$BACKUP_DIR/"
INSTALLED_NEW=1
(( NEED_DOWNLOAD )) && install -m 755 "$new_bin" "$INSTALL_DIR/xmrig"
install -m 644 "$TMP/config.json" "$INSTALL_DIR/config.json"
if [[ -n $(ls -A "$BACKUP_DIR") ]]; then ok "backup en $BACKUP_DIR"; else ok; fi

# =============================================================================
#  5. Huge pages y MSR
# =============================================================================
step "Configurando huge pages y MSR"
hp_note=""

# Páginas de 2MB: se aplican en caliente vía sysctl.
if write_if_changed "$SYSCTL_FILE" "# Generado por XMR Mining: huge pages de 2MB para RandomX
vm.nr_hugepages = $pages_2m"; then
  info "vm.nr_hugepages = $pages_2m"
fi
sysctl -q -p "$SYSCTL_FILE" >>"$LOG" 2>&1 || true
got_2m=$(cat /proc/sys/vm/nr_hugepages)
if (( got_2m < pages_2m )); then
  REBOOT_REASONS+=("huge pages de 2MB: solo se reservaron $got_2m de $pages_2m (memoria fragmentada)")
fi

# Páginas de 1GB: solo se reservan de forma confiable al arrancar (parámetro de kernel).
if (( gb_pages > 0 )); then
  if grep -q 'hugepagesz=1G' /etc/default/grub 2>/dev/null; then
    info "huge pages de 1GB ya configuradas en /etc/default/grub"
  elif ! command -v update-grub >/dev/null; then
    hp_note="sin GRUB, no se configuraron páginas de 1GB"
  elif write_if_changed "$GRUB_FILE" "# Generado por XMR Mining: huge pages de 1GB para RandomX
GRUB_CMDLINE_LINUX_DEFAULT=\"\$GRUB_CMDLINE_LINUX_DEFAULT hugepagesz=1G hugepages=$gb_pages\""; then
    run update-grub
    info "huge pages de 1GB: $gb_pages (parámetro de kernel)"
    REBOOT_REASONS+=("huge pages de 1GB recién configuradas en el kernel")
  fi
elif [[ -f $GRUB_FILE ]]; then
  rm -f "$GRUB_FILE"
  run update-grub
fi

# Módulo MSR: XMRig lo usa para optimizar la CPU (requiere root).
write_if_changed "$MODULES_FILE" "msr" || true
modprobe msr >>"$LOG" 2>&1 || true

if [[ -n $hp_note ]]; then
  ok_warn "$hp_note"
elif (( gb_pages > 0 )); then
  ok "$pages_2m × 2MB + $gb_pages × 1GB"
else
  ok "$pages_2m × 2MB, la CPU no soporta páginas de 1GB"
fi

# =============================================================================
#  6. Servicio systemd
# =============================================================================
step "Configurando el servicio $SERVICE_NAME"
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
ok "habilitado al inicio"

# =============================================================================
#  7. Prueba: arrancar y seguir el log en vivo
# =============================================================================
step "Probando el servicio"
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
    (( $? > 128 )) || break        # EOF: se cumplió el tiempo máximo
  fi
  progress "esperando conexión al pool ($((SECONDS - t0))s)"
done
shopt -u nocasematch
kill "$JPID" 2>/dev/null || true
exec {JFD}<&-

case $result in
  ok)
    ok "conectado al pool en $((SECONDS - t0))s"
    ;;
  *)
    if [[ $result == timeout ]]; then
      fail_step "sin conexión al pool en ${TEST_TIMEOUT}s"
    else
      fail_step "error detectado"
    fi
    echo
    echo "  ${C_ERR}Errores encontrados:${C_0}"
    for l in "${error_lines[@]}"; do echo "    $l"; done
    echo "  Últimas líneas del servicio:"
    journalctl -u "$SERVICE_NAME" --since "$since" -n 15 -o cat --no-pager 2>/dev/null \
      | sed 's/\x1b\[[0-9;]*m//g; s/^/    /'
    trap - ERR
    rollback
    exit 1
    ;;
esac

# =============================================================================
#  8. Limpieza de instalaciones anteriores (formato viejo en /home/*/xmrig)
#     Se borra la carpeta completa, con todo su contenido.
# =============================================================================
old_dirs=()
for d in /home/*/xmrig /root/xmrig; do
  [[ -f $d/start-xmrig.sh ]] && old_dirs+=("$d")
done
if (( ${#old_dirs[@]} )); then
  step "Eliminando la instalación anterior"
  for d in "${old_dirs[@]}"; do
    rm -rf "$d"
    info "eliminado $d"
  done
  ok
fi

# =============================================================================
#  9. Resumen y reinicio (solo si hace falta)
# =============================================================================
if [[ -f /var/run/reboot-required ]]; then
  pkgs=""
  [[ -f /var/run/reboot-required.pkgs ]] && pkgs=$(sort -u /var/run/reboot-required.pkgs | paste -sd ',' | sed 's/,/, /g')
  REBOOT_REASONS+=("actualizaciones del sistema${pkgs:+: $pkgs}")
fi

echo
echo "${C_OK}${C_B}Listo.${C_0} XMRig v$latest_ver está minando como servicio."
echo "${C_DIM}  Worker: $WORKER · Pool: $pool_url"
echo "  Ver el log en vivo:  journalctl -fu $SERVICE_NAME"
echo "  Estado del servicio: systemctl status $SERVICE_NAME${C_0}"
echo

if (( ${#REBOOT_REASONS[@]} )); then
  echo "${C_WARN}Se recomienda reiniciar:${C_0}"
  for r in "${REBOOT_REASONS[@]}"; do echo "  - $r"; done
  if { exec 3</dev/tty; } 2>/dev/null; then
    printf '\n¿Reiniciar ahora? [s/N] '
    read -r answer <&3 || answer=""
    exec 3<&-
    if [[ $answer =~ ^[sSyY] ]]; then
      echo "Reiniciando..."
      reboot
    else
      echo "No se reinicia. Acordate de reiniciar más tarde: sudo reboot"
    fi
  else
    echo "Reiniciá cuando puedas: sudo reboot"
  fi
else
  echo "${C_DIM}No hace falta reiniciar.${C_0}"
fi
