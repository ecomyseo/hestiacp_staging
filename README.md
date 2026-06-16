# HestiaCP Plugins — Watchdog & Staging

> Dos plugins autocontenidos para [HestiaCP](https://hestiacp.com/) que añaden
> **monitorización del servidor** (Watchdog) y **clonado de dominios/BBDD con
> push-to-live** (Staging), integrados en la UI del panel y operables desde la
> línea de comandos con comandos nativos `v-*`.

![HestiaCP](https://img.shields.io/badge/HestiaCP-1.6%2B-1f6feb)
![Bash](https://img.shields.io/badge/Bash-POSIX-4EAA25?logo=gnubash&logoColor=white)
![PowerShell](https://img.shields.io/badge/Deploy-PowerShell%20%2B%20plink-5391FE?logo=powershell&logoColor=white)
![License](https://img.shields.io/badge/License-AFL--3.0-green)

---

## Tabla de contenidos

- [Características](#características)
- [Estructura del repositorio](#estructura-del-repositorio)
- [Requisitos](#requisitos)
- [Instalación rápida (Windows → servidor)](#instalación-rápida-windows--servidor)
- [Instalación manual (en el servidor)](#instalación-manual-en-el-servidor)
- [Kill switches (lee esto antes de usar)](#kill-switches-lee-esto-antes-de-usar)
- [Plugin Watchdog](#plugin-watchdog)
- [Plugin Staging](#plugin-staging)
- [Interfaz web del panel](#interfaz-web-del-panel)
- [Actualización y desinstalación](#actualización-y-desinstalación)
- [Solución de problemas](#solución-de-problemas)
- [Seguridad](#seguridad)
- [Licencia](#licencia)

---

## Características

**Watchdog (vigilancia del servidor)**
- 9 *checks* nativos: recursos, servicios, base de datos, HTTP/HTTPS, SSL, DNS,
  cola de Exim, backups y seguridad básica.
- Umbrales configurables (CPU/RAM/disco/carga) con escalado WARNING → CRITICAL.
- 5 canales de notificación: Email, Telegram, Slack, Discord y webhook genérico.
- Anti-inundación: ventana anti-duplicado, *rate limit* por hora y *digest* por ejecución.
- Cron cada 5 min registrado con la herramienta nativa `v-add-cron-job`.

**Staging (clonado de dominios y BBDD)**
- Clona un dominio de producción a un entorno de staging (subdominio, dominio o usuario aparte).
- Reescritura *serialize-safe* de URLs para WordPress, PrestaShop, Laravel, Joomla y estáticos.
- Push-to-live **destructivo** protegido por kill switch + backup obligatorio + rollback.
- Staging protegido por defecto: `noindex` + HTTP Basic Auth + pasarelas/emails desactivados.

**Comunes**
- **Idempotentes**: re-ejecutar `install.sh` no duplica cron, comandos ni estado.
- **Kill switches activados por defecto**: nada sale al exterior ni sobrescribe producción sin confirmación.
- Integración en la UI del panel (menú superior + botones en *Server Settings*) con backup y validación `php -l`.
- Sin dependencias de Composer; solo Bash y utilidades estándar del sistema.

---

## Estructura del repositorio

```
hestiacp/
├── deploy.ps1            # Despliegue desde Windows vía PuTYY/plink (stdin, sin SFTP)
├── deploy.sh             # Despliegue desde Linux/macOS
├── INSTALL.md            # Guía de instalación manual detallada
├── PLAN_WATCHDOG.md      # Diseño técnico del Watchdog
├── PLAN_STAGING.md       # Diseño técnico del Staging
├── watchdog/
│   ├── install.sh        # Instalador idempotente
│   ├── bin/v-watchdog-*  # Comandos CLI
│   ├── checks/*.sh       # Checks de monitorización
│   ├── notifiers/*.sh    # Canales: email, telegram, slack, discord, webhook
│   ├── lib/              # common.sh, alerts.sh
│   ├── conf/watchdog.conf
│   └── web/index.php     # UI del panel
└── staging/
    ├── install.sh        # Instalador idempotente
    ├── bin/v-staging-*   # Comandos CLI
    ├── lib/*.sh          # clone_db, clone_files, push_live, rollback, sync, rewrite, ssl_dns…
    ├── conf/staging.conf
    └── web/index.php     # UI del panel
```

Tras la instalación, los plugins viven en `/usr/local/hestia/plugins/<plugin>/` y
los comandos se publican en `/usr/local/hestia/bin/` (ya en el PATH del panel).

---

## Requisitos

- HestiaCP **1.6+** sobre Debian 11/12 o Ubuntu 20.04/22.04/24.04.
- Acceso **root** por SSH.
- Paquetes (normalmente ya presentes): `bash`, `curl`, `flock`, `rsync`,
  cliente `mysql`/`mariadb` y/o `psql`.
- Opcional (staging WordPress): **WP-CLI** para `search-replace` serialize-safe.
- Para el despliegue desde Windows: **PuTTY** (`plink.exe`) y `tar.exe` (incluido en Windows 10/11).

---

## Instalación rápida (Windows → servidor)

El script [`deploy.ps1`](deploy.ps1) empaqueta `watchdog/` y `staging/`, los
sube por **stdin sobre plink** (no usa pscp/SFTP, que muchos servidores tienen
deshabilitado), normaliza saltos de línea, ajusta permisos, ejecuta los
instaladores y publica la UI. Es idempotente y **preserva `conf/` y `state/`**.

1. Instala PuTTY si no lo tienes:
   ```powershell
   winget install --id PuTTY.PuTTY -e
   ```
2. Edita la cabecera de `deploy.ps1` con los datos del servidor:
   ```powershell
   $Server = '00.00.00.00'      # IP o host del servidor HestiaCP
   $User   = 'root'
   $Pass   = '...'              # contraseña root del servidor destino
   $Port   = '22'
   ```
3. Ejecútalo:
   ```powershell
   .\deploy.ps1
   # si la política lo bloquea:
   powershell -ExecutionPolicy Bypass -File .\deploy.ps1
   ```

El script realiza 6 pasos y termina mostrando los kill switches y las URLs de la UI:

```
[0/6] Cacheo de host key      [3/6] LF + sincronización + permisos
[1/6] Verificación HestiaCP   [4/6] Instaladores (cron + menú + botones)
[2/6] Empaquetado y subida    [5/6] Publicación de UI (symlinks)
                              [6/6] Verificación final
```

> Desde Linux/macOS existe el equivalente [`deploy.sh`](deploy.sh).

---

## Instalación manual (en el servidor)

Resumen; la guía completa está en [INSTALL.md](INSTALL.md).

```bash
# 1) Subir las carpetas (ajusta TU_SERVIDOR)
scp -r ./watchdog ./staging root@TU_SERVIDOR:/usr/local/hestia/plugins/

# 2) Normalizar saltos de línea (si se editaron en Windows)
apt-get install -y dos2unix
find /usr/local/hestia/plugins/{watchdog,staging} -type f \
  \( -name '*.sh' -o -name 'v-*' \) -exec dos2unix {} \;

# 3) Ejecutar los instaladores (idempotentes)
cd /usr/local/hestia/plugins/watchdog && bash install.sh
cd /usr/local/hestia/plugins/staging  && bash install.sh
```

---

## Kill switches (lee esto antes de usar)

Ambos plugins arrancan **bloqueados** por seguridad. No envían nada al exterior
ni sobrescriben producción hasta que los desactivas conscientemente.

| Plugin   | Clave                     | Por defecto | Efecto mientras está `true`                          |
|----------|---------------------------|-------------|------------------------------------------------------|
| Watchdog | `WD_KILL_SWITCH`          | `'true'`    | Los checks se ejecutan y registran, pero **no** se envía ninguna notificación. |
| Staging  | `STG_PUSH_KILL_SWITCH`    | `'true'`    | Crear/sincronizar staging es seguro; el **push-to-live** está bloqueado. |

```bash
# Validar canales del watchdog y activar el envío real
v-watchdog-test-notify telegram
v-watchdog-config-set WD_KILL_SWITCH 'false'

# Solo cuando vayas a publicar a producción, y tras tener backup verificado
v-staging-config-set STG_PUSH_KILL_SWITCH 'false'
```

---

## Plugin Watchdog

### Comandos CLI

| Comando                  | Función |
|--------------------------|---------|
| `v-watchdog-run`         | Orquestador: ejecuta los checks y dispara las alertas (lo invoca el cron). |
| `v-watchdog-status`      | Estado agregado (semáforo por categoría). |
| `v-watchdog-list-alerts` | Lista las alertas registradas en el journal. |
| `v-watchdog-ack`         | Marca alertas como reconocidas (ACK). |
| `v-watchdog-test-notify` | Envía una notificación de prueba por los canales. |
| `v-watchdog-config-get`  | Lee valores de `conf/watchdog.conf`. |
| `v-watchdog-config-set`  | Escribe/actualiza una clave de configuración. |
| `v-watchdog-debug`       | Activa/desactiva la depuración y muestra diagnóstico. |

```bash
v-watchdog-run --dry-run        # pasada en seco (no notifica)
v-watchdog-status               # semáforo por categoría
v-watchdog-list-alerts          # historial de alertas
```

### Checks de monitorización

| Check       | Qué vigila |
|-------------|------------|
| `resources` | CPU, RAM, disco y carga del sistema (umbrales configurables). |
| `services`  | Servicios del sistema (nginx, apache, mysql, exim…). |
| `database`  | MariaDB/MySQL y PostgreSQL. |
| `http`      | Disponibilidad HTTP/HTTPS de los dominios alojados. |
| `ssl`       | Caducidad de certificados SSL por dominio. |
| `dns`       | Resolución DNS de zonas gestionadas por bind/named. |
| `exim_queue`| Tamaño de la cola de correo de Exim. |
| `backups`   | Antigüedad del último backup por usuario. |
| `security`  | Comprobaciones de seguridad básicas. |

### Configuración (`conf/watchdog.conf`)

Umbrales (`WD_CPU_WARN/CRIT`, `WD_RAM_*`, `WD_DISK_*`, `WD_LOAD_*`), ventana
anti-duplicado (`WD_NOTIFY_WINDOW`), *rate limit* (`WD_RATE_MAX_HOUR`), escalado
(`WD_ESCALATE_AFTER`), *digest* (`WD_DIGEST`) y los canales:

```ini
WD_CHANNEL_TELEGRAM='true'
WD_TELEGRAM_TOKEN='123456:ABC...'
WD_TELEGRAM_CHAT_ID='987654321'
```

Canales soportados: **Email**, **Telegram**, **Slack**, **Discord**, **webhook**
genérico. Los secretos viven en el `.conf` con permisos `640` y **nunca** se
escriben en los logs.

---

## Plugin Staging

### Comandos CLI

| Comando              | Función |
|----------------------|---------|
| `v-staging-create`   | Crea un entorno de staging a partir de un dominio de producción. |
| `v-staging-sync`     | Re-sincroniza producción → staging (ficheros y/o BBDD). |
| `v-staging-list`     | Lista los entornos de staging registrados. |
| `v-staging-info`     | Detalle completo de un entorno. |
| `v-staging-push`     | **PUSH-TO-LIVE**: promociona staging a producción (destructivo, protegido). |
| `v-staging-rollback` | Revierte un push-to-live dejando producción como estaba. |
| `v-staging-delete`   | Elimina **únicamente** el entorno de staging (web + BBDD). Nunca toca el origen. |
| `v-staging-debug`    | Diagnóstico: entorno, dependencias y estado. |

### Flujo de trabajo

```bash
# 1) Crear un staging de un dominio existente (modo subdominio)
v-staging-create admin midominio.com --mode subdomain
v-staging-list
v-staging-info staging.midominio.com

# 2) Re-sincronizar cuando producción avance
v-staging-sync staging.midominio.com

# 3) Publicar a producción (requiere backup + kill switch desactivado)
v-staging-config-set STG_PUSH_KILL_SWITCH 'false'
v-staging-push staging.midominio.com
# Si algo sale mal:
v-staging-rollback midominio.com
```

### Configuración (`conf/staging.conf`)

- **Seguridad**: `STG_PUSH_KILL_SWITCH`, `STG_BACKUP_TTL` (backup válido máx. 24 h
  antes de autorizar push).
- **Nomenclatura**: `STG_NAME_PATTERN` (`staging.{domain}`), `STG_DEFAULT_MODE`,
  prefijos de BBDD `STG_DB_PREFIX` / `STG_DBUSER_PREFIX`.
- **Protección**: `STG_NOINDEX`, `STG_BASIC_AUTH`, `STG_DISABLE_EMAILS`,
  `STG_DISABLE_PAYMENTS`.
- **CMS**: plantillas de reescritura para WordPress / PrestaShop / Laravel /
  Joomla y exclusiones de rsync (`STG_RSYNC_EXCLUDES`, `STG_UPLOADS_EXCLUDE`).

---

## Interfaz web del panel

Los instaladores publican los accesos y la integran en la UI de HestiaCP:

- Menú superior: **STAGING** (todos los usuarios) / **WATCHDOG** (solo `admin`).
- *Server Settings → Configure*: sección **Watchdog & Staging** con botones de acceso.
- URLs directas (sesión iniciada en el panel):
  - `https://TU_SERVIDOR:8083/pluginwatchdog/`
  - `https://TU_SERVIDOR:8083/pluginstaging/`

La integración se **re-aplica en cada instalación** (las actualizaciones del
panel sobrescriben los ficheros core) y siempre con backup `*.ecombak` y
validación `php -l`: si el resultado no valida, se conserva el original.

---

## Actualización y desinstalación

```bash
# Actualizar: subir la nueva versión y re-ejecutar el instalador (idempotente)
cd /usr/local/hestia/plugins/watchdog && bash install.sh
#  -> conf/*.conf y state/ NO se sobrescriben

# Desinstalar
cd /usr/local/hestia/plugins/watchdog && bash uninstall.sh
cd /usr/local/hestia/plugins/staging  && bash uninstall.sh
rm -f /usr/local/hestia/web/pluginwatchdog /usr/local/hestia/web/pluginstaging
```

`uninstall.sh` elimina los comandos de `bin/`, quita el cron y (preguntando)
borra `state/` y `logs/`. **No** toca dominios, BBDD ni datos de producción.

---

## Solución de problemas

| Síntoma | Causa probable | Solución |
|---|---|---|
| `Argument list too long` al subir | (corregido en `deploy.ps1`) payload incrustado en el comando | El despliegue ya usa **stdin**; actualiza a la versión actual del script. |
| `v-watchdog-run: command not found` | symlink no creado / PATH no refrescado | Re-ejecutar `install.sh`; `hash -r`. |
| `bad interpreter: ^M` | finales de línea CRLF | `dos2unix` sobre los `.sh`. |
| No llegan alertas | kill switch activo | `v-watchdog-config-set WD_KILL_SWITCH 'false'`. |
| Push-to-live "bloqueado" | kill switch de staging activo | Backup + `STG_PUSH_KILL_SWITCH 'false'`. |
| Staging WordPress con URLs rotas | reemplazo no serialize-safe | Instalar **WP-CLI**. |
| UI da 403 / redirige al login | sesión no iniciada o no eres `admin` | Inicia sesión como `admin` en `:8083`. |

Depuración detallada (no expone tokens):

```bash
v-watchdog-debug on   # o  v-staging-debug on
tail -f /usr/local/hestia/plugins/watchdog/logs/watchdog.log
v-watchdog-debug off
```

---

## Seguridad

- **Kill switches activados por defecto**: nada sale al exterior ni sobrescribe
  producción sin confirmación explícita.
- **Backup obligatorio antes de push-to-live**: se exige un backup verificado
  (TTL configurable) y confirmación del dominio.
- **Origen intocable**: las operaciones de staging (create/sync/delete) nunca
  modifican el dominio de producción de origen.
- **Secretos protegidos**: tokens y contraseñas en `conf/*.conf` con permisos
  `640`, nunca en los logs.
- **No subas credenciales reales**: `deploy.ps1` incluye `$Server`/`$Pass` de
  ejemplo. Rellénalos en tu copia local y mantenlos fuera del control de versiones.

---

## Licencia

**AFL-3.0** · © 2026 Ecom Experts · `ecomyseo@gmail.com`
