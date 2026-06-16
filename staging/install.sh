#!/bin/bash
# install.sh - Instalador idempotente del plugin Staging para HestiaCP.
# Comprueba dependencias (rsync, clientes mysql/pg, wp-cli opcional), prepara
# directorios y registra los comandos v-staging-* enlazandolos en el bin de
# HestiaCP. Reejecutable sin efectos secundarios.
set -euo pipefail

# Raiz del plugin (directorio de este script).
STG_ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
export STG_ROOT
# shellcheck source=/dev/null
. "$STG_ROOT/lib/common.sh"

HESTIA="${HESTIA:-/usr/local/hestia}"
VBIN="$HESTIA/bin"

echo "== Instalacion del plugin Staging =="

# --- Comprobacion de privilegios ------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
    echo "AVISO: se recomienda ejecutar como root para registrar los comandos en $VBIN." >&2
fi

# --- Dependencias obligatorias ---------------------------------------------
missing=0
if ! command -v rsync >/dev/null 2>&1; then
    echo "FALTA: rsync (obligatorio para el clonado de ficheros)." >&2
    missing=1
fi
if ! command -v mysql >/dev/null 2>&1 && ! command -v mariadb >/dev/null 2>&1; then
    echo "AVISO: cliente mysql/mariadb no encontrado (necesario para BBDD MySQL)." >&2
fi
if ! command -v psql >/dev/null 2>&1; then
    echo "AVISO: cliente psql no encontrado (solo necesario para BBDD PostgreSQL)." >&2
fi
if [ "$missing" -ne 0 ]; then
    stg_die "Faltan dependencias obligatorias. Instala rsync y reintenta."
fi

# --- Dependencias opcionales -----------------------------------------------
if command -v wp >/dev/null 2>&1; then
    echo "OK: wp-cli detectado en $(command -v wp) (search-replace serialize-safe disponible)."
else
    echo "AVISO: wp-cli no encontrado. Se usara el reemplazo serialize-safe propio para WordPress."
fi

# --- Directorios de trabajo ------------------------------------------------
for d in "$STG_ROOT/state" "$STG_ROOT/state/envs" "$STG_ROOT/logs"; do
    [ -d "$d" ] || mkdir -p "$d"
done
chmod 700 "$STG_ROOT/state" "$STG_ROOT/state/envs" 2>/dev/null || true
chmod 750 "$STG_ROOT/logs" 2>/dev/null || true

# --- Configuracion inicial idempotente -------------------------------------
[ -f "$STG_CONF" ] || stg_die "No se encuentra conf/staging.conf"
chmod 600 "$STG_CONF" 2>/dev/null || true
# Garantiza el kill switch activado tras una instalacion limpia.
if [ -z "$(stg_conf_get STG_PUSH_KILL_SWITCH '')" ]; then
    stg_conf_set STG_PUSH_KILL_SWITCH true
fi
echo "Kill switch push-to-live: $(stg_conf_get STG_PUSH_KILL_SWITCH true) (true = bloqueado)."

# --- Permisos de ejecucion de los scripts ----------------------------------
chmod +x "$STG_ROOT"/lib/*.sh 2>/dev/null || true
if [ -d "$STG_ROOT/bin" ]; then
    chmod +x "$STG_ROOT"/bin/* 2>/dev/null || true
fi

# --- Registro de comandos v-staging-* --------------------------------------
# Enlaza simbolicamente cada binario del plugin en el bin de HestiaCP, de forma
# idempotente (solo crea/actualiza si apunta a otro sitio).
register_cmd() {
    local name="$1"
    local src="$STG_ROOT/bin/$name"
    local dst="$VBIN/$name"
    [ -f "$src" ] || return 0
    if [ ! -d "$VBIN" ]; then
        echo "AVISO: $VBIN no existe; omito registro de $name." >&2
        return 0
    fi
    if [ -L "$dst" ] || [ -e "$dst" ]; then
        rm -f "$dst" 2>/dev/null || true
    fi
    # Wrapper que ejecuta el script real por su ruta absoluta (resuelve bien
    # ${BASH_SOURCE[0]} y por tanto STG_ROOT, a diferencia de un symlink).
    if printf '#!/bin/bash\nexec "%s" "$@"\n' "$src" > "$dst" 2>/dev/null; then
        chmod 755 "$dst" 2>/dev/null || true
        echo "Registrado: $name"
    else
        echo "AVISO: no se pudo registrar $name en $VBIN (privilegios?)." >&2
    fi
}

for c in v-staging-create v-staging-sync v-staging-push v-staging-rollback \
         v-staging-list v-staging-info v-staging-delete v-staging-debug; do
    register_cmd "$c"
done

# --- Integracion en el menu del panel (idempotente) ------------------------
# Anade una entrada "STAGING" en el menu superior de HestiaCP que enlaza a la UI
# del plugin (/pluginstaging/). Hace backup, valida con php -l y SOLO aplica si
# el resultado es sintacticamente correcto. Se re-aplica en cada instalacion
# porque las actualizaciones de HestiaCP sobreescriben panel.php.
register_panel_menu() {
    local panel="$HESTIA/web/templates/includes/panel.php"
    [ -f "$panel" ] || { echo "AVISO: no se encontro panel.php; omito el menu del panel."; return 0; }
    if grep -q "ECOM_STAGING_MENU" "$panel"; then
        echo "Menu Staging ya presente en el panel."
        return 0
    fi
    command -v php >/dev/null 2>&1 || { echo "AVISO: php no disponible; omito el menu del panel."; return 0; }
    [ -f "$panel.ecombak" ] || cp -a "$panel" "$panel.ecombak"
    local blk="$STG_ROOT/state/.stg_menu.html"
    cat > "$blk" <<'BLOCK'
				<!-- ECOM_STAGING_MENU inicio (plugin Staging - Ecom Experts) -->
				<?php if (!empty($_SESSION["user"])) { ?>
					<li class="main-menu-item">
						<a class="main-menu-item-link <?php if ($TAB == "STAGING") { echo "active"; } ?>" href="/pluginstaging/" title="Staging / Clonado de dominios y BBDD">
							<p class="main-menu-item-label">STAGING<i class="fas fa-clone"></i></p>
						</a>
					</li>
				<?php } ?>
				<!-- ECOM_STAGING_MENU fin -->
BLOCK
    awk -v b="$blk" 'BEGIN{ins=0} /<!-- Web tab -->/ && ins==0 { while((getline line < b) > 0) print line; ins=1 } { print }' "$panel" > "$panel.new"
    if php -l "$panel.new" >/dev/null 2>&1; then
        mv -f "$panel.new" "$panel"
        echo "Menu Staging anadido al panel (enlace a /pluginstaging/)."
    else
        echo "AVISO: el panel.php modificado no valida; se conserva el original." >&2
        mv -f "$panel.new" "$STG_ROOT/state/panel_invalid.new" 2>/dev/null || true
    fi
}
register_panel_menu

stg_log "INFO" "Plugin Staging instalado/actualizado correctamente."
echo "== Instalacion completada =="
echo "Recuerda: el push-to-live esta BLOQUEADO por kill switch hasta que lo desactives en conf/staging.conf."
