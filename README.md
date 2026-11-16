# XMR Mining

Instala o actualiza [XMRig](https://github.com/xmrig/xmrig) como servicio systemd en Ubuntu x64, con un solo comando.

## Uso

En la máquina a instalar o actualizar:

```bash
curl -fsSL https://raw.githubusercontent.com/CAMBIAR_USUARIO/xmr-mining/main/mine-xmr.sh | sudo bash
```

El mismo comando sirve para la primera instalación y para actualizar. El script no queda guardado en la máquina.

## Qué hace

1. Verifica que haya RAM suficiente (si no, indica cuánta asignar a la VM y no toca nada).
1. Actualiza el sistema operativo (`apt update` + `apt upgrade`).
2. Descarga la última versión de XMRig publicada en GitHub y verifica su SHA256 (si ya está instalada, no la vuelve a bajar).
3. Genera `/opt/xmrig/config.json` a partir de [`config/xmrig.json`](config/xmrig.json). El worker es el hostname en mayúsculas.
4. Configura huge pages (2MB vía sysctl y 1GB vía parámetro de kernel en GRUB) y el módulo MSR.
5. Crea y habilita `xmrig.service`.
6. Arranca el servicio y sigue el log en vivo:
   - **Conexión OK**: queda minando. Pide reiniciar solo si hace falta (kernel actualizado o huge pages recién configuradas).
   - **Error**: deshabilita el servicio, restaura la versión anterior de XMRig y `config.json`, y muestra los errores.

## Cambiar pool, wallet o donación

Editar [`config/xmrig.json`](config/xmrig.json) y hacer commit. La próxima vez que se ejecute el comando en cada máquina, toma la configuración nueva.

- `{{WORKER}}` se reemplaza por el hostname en mayúsculas.
- `donate-level`: porcentaje donado a los desarrolladores de XMRig (mínimo 1).
- Opciones disponibles: <https://xmrig.com/docs/miner/config>

## Archivos en la máquina

| Ruta | Contenido |
|---|---|
| `/opt/xmrig/xmrig` | Binario de XMRig |
| `/opt/xmrig/config.json` | Configuración generada |
| `/opt/xmrig/backup/` | Versión anterior (binario + config) |
| `/etc/systemd/system/xmrig.service` | Servicio |
| `/etc/sysctl.d/99-xmrig-hugepages.conf` | Huge pages de 2MB |
| `/etc/default/grub.d/99-xmrig-hugepages.cfg` | Huge pages de 1GB |
| `/etc/modules-load.d/xmrig-msr.conf` | Carga del módulo MSR |
| `/opt/xmrig/AAAA-MM-DD-xmr-mining-install.log` | Logs del instalador (se conservan los últimos 20) |

## Comandos útiles

```bash
journalctl -fu xmrig          # log en vivo
systemctl status xmrig        # estado
sudo systemctl stop xmrig     # detener
sudo systemctl disable xmrig  # no arrancar al inicio
```

## Desinstalar

```bash
sudo systemctl disable --now xmrig
sudo rm -rf /opt/xmrig /etc/systemd/system/xmrig.service /etc/sysctl.d/99-xmrig-hugepages.conf /etc/modules-load.d/xmrig-msr.conf
sudo rm -f /etc/default/grub.d/99-xmrig-hugepages.cfg && sudo update-grub
sudo systemctl daemon-reload
```
