#!/bin/bash
# install.sh - Instalador idempotente del plugin Watchdog para HestiaCP.
# Verifica la version del panel, prepara directorios de estado y logs, enlaza
# el comando de control en el PATH del panel y registra el cron de ejecucion
# mediante v-add-cron-job. Reejecutar es seguro (no duplica nada).
set -euo pipefail

# Raiz del plugin = directorio de este script.
WD_ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
export WD_ROOT

# Carga la libreria nucleo para reutilizar logging y conf.
# shellcheck source=lib/common.sh
. "$WD_ROOT/lib/common.sh"

# Localizacion estandar de HestiaCP.
HESTIA="${HESTIA:-/usr/local/hestia}"
HESTIA_BIN="$HESTIA/bin"

echo "== Watchdog :: instalacion =="

# ---------------------------------------------------------------------------
# 1) Verificacion de entorno HestiaCP.
# ---------------------------------------------------------------------------
if [ ! -d "$HESTIA" ] || [ ! -x "$HESTIA_BIN/v-list-sys-info" ] && [ ! -x "$HESTIA_BIN/v-list-users" ]; then
    echo "ERROR: no se detecta HestiaCP en $HESTIA (faltan comandos v-*)." >&2
    echo "       Exporta HESTIA=/ruta/al/panel si esta en otra ubicacion." >&2
    exit 1
fi

# Comprueba version (informativo; minimo recomendado 1.6).
HESTIA_VER=""
if [ -f "$HESTIA/conf/hestia.conf" ]; then
    HESTIA_VER="$(grep -E '^VERSION=' "$HESTIA/conf/hestia.conf" 2>/dev/null | head -n1 | cut -d"'" -f2)"
fi
[ -n "$HESTIA_VER" ] && echo "HestiaCP detectado: version $HESTIA_VER"
if [ -n "$HESTIA_VER" ]; then
    major="${HESTIA_VER%%.*}"
    rest="${HESTIA_VER#*.}"; minor="${rest%%.*}"
    case "$major" in ''|*[!0-9]*) major=0 ;; esac
    case "$minor" in ''|*[!0-9]*) minor=0 ;; esac
    if [ "$major" -lt 1 ] || { [ "$major" -eq 1 ] && [ "$minor" -lt 6 ]; }; then
        echo "AVISO: version $HESTIA_VER por debajo de la recomendada (1.6+). Continuo." >&2
    fi
fi

# ---------------------------------------------------------------------------
# 2) Directorios de trabajo (state/ y logs/). Idempotente.
# ---------------------------------------------------------------------------
mkdir -p "$WD_STATE_DIR" "$WD_LOG_DIR"
chmod 700 "$WD_STATE_DIR" 2>/dev/null || true
chmod 750 "$WD_LOG_DIR" 2>/dev/null || true
echo "Directorios listos: state/ y logs/"

# Asegura conf con permisos restrictivos (contiene posibles tokens).
[ -f "$WD_CONF" ] && chmod 600 "$WD_CONF" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 3) Enlace de TODOS los comandos del plugin en el PATH del panel.
#    Idempotente: re-crea los enlaces. v-watchdog-run se usa ademas en el cron.
# ---------------------------------------------------------------------------
WD_CMD_SRC="$WD_ROOT/bin/v-watchdog-run"
WD_CMD_DST="$HESTIA_BIN/v-watchdog-run"
wd_linked=0
for src in "$WD_ROOT"/bin/v-watchdog-*; do
    [ -f "$src" ] || continue
    chmod 755 "$src" 2>/dev/null || true
    dst="$HESTIA_BIN/$(basename "$src")"
    if [ -L "$dst" ] || [ -e "$dst" ]; then
        rm -f "$dst"
    fi
    # Wrapper que ejecuta el script real por su ruta absoluta (resuelve bien
    # ${BASH_SOURCE[0]} y por tanto WD_ROOT, a diferencia de un symlink).
    printf '#!/bin/bash\nexec "%s" "$@"\n' "$src" > "$dst"
    chmod 755 "$dst"
    echo "Registrado: $(basename "$src")"
    wd_linked=$((wd_linked + 1))
done
if [ "$wd_linked" -eq 0 ]; then
    echo "AVISO: no se encontraron comandos en $WD_ROOT/bin (v-watchdog-*)."
fi

# ---------------------------------------------------------------------------
# 4) Cron de ejecucion via v-add-cron-job (cada 5 minutos).
#    Idempotente: si ya hay un job que apunta al watchdog, no se duplica.
# ---------------------------------------------------------------------------
# Autodetecta el usuario admin del panel (ROLE='admin'); fallback al primer usuario.
detect_admin_user() {
    local uc
    for uc in "$HESTIA"/data/users/*/user.conf; do
        [ -f "$uc" ] || continue
        if grep -q "ROLE='admin'" "$uc" 2>/dev/null; then
            basename "$(dirname "$uc")"
            return 0
        fi
    done
    "$HESTIA_BIN/v-list-users" plain 2>/dev/null | awk 'NR==1{print $1}'
}
CRON_USER="${WD_CRON_USER:-$(detect_admin_user)}"
[ -n "$CRON_USER" ] || CRON_USER="admin"
# Comando que ejecutara el cron: prioriza el enlace del panel, si no la ruta directa.
if [ -e "$WD_CMD_DST" ]; then
    CRON_CMD="$WD_CMD_DST run"
else
    CRON_CMD="$WD_CMD_SRC run"
fi

cron_already_present() {
    "$HESTIA_BIN/v-list-cron-jobs" "$CRON_USER" plain 2>/dev/null | grep -q 'v-watchdog-run'
}

if [ -x "$HESTIA_BIN/v-add-cron-job" ]; then
    if cron_already_present; then
        echo "Cron ya registrado para $CRON_USER (no se duplica)."
    else
        # v-add-cron-job USER MIN HOUR DAY MONTH WDAY COMMAND
        if "$HESTIA_BIN/v-add-cron-job" "$CRON_USER" '*/5' '*' '*' '*' '*' "$CRON_CMD"; then
            echo "Cron registrado: cada 5 min ($CRON_CMD) para $CRON_USER."
            wd_log INFO "Cron instalado para $CRON_USER: $CRON_CMD"
        else
            echo "AVISO: no se pudo registrar el cron via v-add-cron-job (revisar usuario $CRON_USER)." >&2
        fi
    fi
else
    echo "AVISO: v-add-cron-job no disponible; registra el cron manualmente: */5 * * * * $CRON_CMD" >&2
fi

# ---------------------------------------------------------------------------
# 5) Integracion en la UI del panel (idempotente; re-aplicada en cada install
#    porque las actualizaciones de HestiaCP sobreescriben los ficheros core).
#    a) Entrada "WATCHDOG" en el menu superior (solo admin).
#    b) Botones de acceso a Watchdog y Staging en Server Settings (Configure).
#    Ambas con backup + validacion php -l + marcador unico.
# ---------------------------------------------------------------------------
register_panel_menu_wd() {
    local panel="$HESTIA/web/templates/includes/panel.php"
    [ -f "$panel" ] || { echo "AVISO: no se encontro panel.php; omito el menu."; return 0; }
    if grep -q "ECOM_WATCHDOG_MENU" "$panel"; then
        echo "Menu Watchdog ya presente en el panel."
        return 0
    fi
    command -v php >/dev/null 2>&1 || return 0
    [ -f "$panel.ecombak" ] || cp -a "$panel" "$panel.ecombak"
    local blk="$WD_STATE_DIR/.wd_menu.html"
    cat > "$blk" <<'BLOCK'
				<!-- ECOM_WATCHDOG_MENU inicio (plugin Watchdog - Ecom Experts) -->
				<?php if (isset($_SESSION["userContext"]) && $_SESSION["userContext"] === "admin") { ?>
					<li class="main-menu-item">
						<a class="main-menu-item-link <?php if ($TAB == "WATCHDOG") { echo "active"; } ?>" href="/pluginwatchdog/" title="Watchdog / Monitorizacion del servidor">
							<p class="main-menu-item-label">WATCHDOG<i class="fas fa-heart-pulse"></i></p>
						</a>
					</li>
				<?php } ?>
				<!-- ECOM_WATCHDOG_MENU fin -->
BLOCK
    awk -v b="$blk" 'BEGIN{ins=0} /<!-- Web tab -->/ && ins==0 { while((getline line < b) > 0) print line; ins=1 } { print }' "$panel" > "$panel.new"
    if php -l "$panel.new" >/dev/null 2>&1; then
        mv -f "$panel.new" "$panel"
        echo "Menu Watchdog anadido al panel."
    else
        echo "AVISO: el panel.php modificado no valida; se conserva el original." >&2
        mv -f "$panel.new" "$WD_STATE_DIR/panel_invalid.new" 2>/dev/null || true
    fi
}

register_server_buttons() {
    local f="$HESTIA/web/templates/pages/edit_server.php"
    [ -f "$f" ] || { echo "AVISO: no se encontro edit_server.php; omito los botones."; return 0; }
    if grep -q "ECOM_PLUGINS_BTNS" "$f"; then
        echo "Botones en Server Settings ya presentes."
        return 0
    fi
    command -v php >/dev/null 2>&1 || return 0
    [ -f "$f.ecombak" ] || cp -a "$f" "$f.ecombak"
    local blk="$WD_STATE_DIR/.wd_srvbtn.html"
    cat > "$blk" <<'BLOCK'
			<!-- ECOM_PLUGINS_BTNS inicio (Ecom Experts) -->
			<details class="box-collapse u-mb10" open>
				<summary class="box-collapse-header">
					<i class="fas fa-puzzle-piece u-mr10"></i>Watchdog &amp; Staging
				</summary>
				<div class="box-collapse-content">
					<a href="/pluginwatchdog/" style="display:inline-block;padding:8px 14px;margin:4px 8px 4px 0;background:#1f6feb;color:#fff;border-radius:6px;text-decoration:none;">Abrir Watchdog</a>
					<a href="/pluginstaging/" style="display:inline-block;padding:8px 14px;margin:4px 0;background:#238636;color:#fff;border-radius:6px;text-decoration:none;">Abrir Staging</a>
					<p style="font-size:12px;color:#888;margin:8px 0 0;">Monitorizacion del servidor y clonado de dominios/BBDD. La configuracion completa esta dentro de cada panel.</p>
				</div>
			</details>
			<!-- ECOM_PLUGINS_BTNS fin -->
BLOCK
    awk -v b="$blk" 'BEGIN{ins=0} /<!-- Plugins section -->/ && ins==0 { while((getline line < b) > 0) print line; ins=1 } { print }' "$f" > "$f.new"
    if php -l "$f.new" >/dev/null 2>&1; then
        mv -f "$f.new" "$f"
        echo "Botones anadidos a Server Settings (Configure)."
    else
        echo "AVISO: edit_server.php modificado no valida; se conserva el original." >&2
        mv -f "$f.new" "$WD_STATE_DIR/edit_server_invalid.new" 2>/dev/null || true
    fi
}
register_panel_menu_wd
register_server_buttons

# Registra la instalacion en el estado.
wd_state_set "installed_at" "$(date +%s)"
wd_log INFO "Watchdog instalado (HestiaCP ${HESTIA_VER:-desconocida})."
echo "== Instalacion completada =="
echo "Recuerda: WD_KILL_SWITCH='true' por defecto. Edita conf/watchdog.conf y ponlo a 'false' cuando valides canales."
