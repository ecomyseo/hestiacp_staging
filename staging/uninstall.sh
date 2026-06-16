#!/bin/bash
# uninstall.sh - Desinstalador idempotente del plugin Staging para HestiaCP.
# Elimina unicamente los enlaces de comandos v-staging-* registrados en el bin
# de HestiaCP. NO borra estado, logs ni entornos de staging existentes salvo que
# se pase --purge explicitamente (con confirmacion). Nunca toca produccion.
set -euo pipefail

STG_ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
export STG_ROOT
# shellcheck source=/dev/null
. "$STG_ROOT/lib/common.sh"

HESTIA="${HESTIA:-/usr/local/hestia}"
VBIN="$HESTIA/bin"
PURGE='no'
[ "${1:-}" = "--purge" ] && PURGE='yes'

echo "== Desinstalacion del plugin Staging =="

# --- Eliminar enlaces de comandos ------------------------------------------
unregister_cmd() {
    local name="$1"
    local dst="$VBIN/$name"
    local src="$STG_ROOT/bin/$name"
    [ -e "$dst" ] || [ -L "$dst" ] || return 0
    # Elimina si es un symlink que apunta a nuestro bin O un wrapper que ejecuta
    # nuestro script (no toca comandos ajenos).
    if { [ -L "$dst" ] && [ "$(readlink -f "$dst" 2>/dev/null)" = "$(readlink -f "$src" 2>/dev/null)" ]; } \
        || grep -qF "$src" "$dst" 2>/dev/null; then
        rm -f "$dst" && echo "Eliminado: $name"
    fi
}

for c in v-staging-create v-staging-sync v-staging-push v-staging-rollback \
         v-staging-list v-staging-info v-staging-delete v-staging-debug; do
    unregister_cmd "$c"
done

# --- Quitar la entrada "STAGING" del menu del panel ------------------------
remove_panel_menu() {
    local panel="$HESTIA/web/templates/includes/panel.php"
    [ -f "$panel" ] || return 0
    grep -q "ECOM_STAGING_MENU" "$panel" || return 0
    command -v php >/dev/null 2>&1 || return 0
    sed '/ECOM_STAGING_MENU inicio/,/ECOM_STAGING_MENU fin/d' "$panel" > "$panel.new"
    if php -l "$panel.new" >/dev/null 2>&1; then
        mv -f "$panel.new" "$panel"
        echo "Entrada Staging eliminada del menu del panel."
    else
        mv -f "$panel.new" "$STG_ROOT/state/panel_invalid.new" 2>/dev/null || true
        echo "AVISO: no se pudo limpiar el menu del panel de forma segura; revisalo manualmente." >&2
    fi
}
remove_panel_menu

# --- Purga opcional de estado/logs -----------------------------------------
if [ "$PURGE" = "yes" ]; then
    if [ "${STG_CONFIRM:-}" != "PURGE" ]; then
        stg_die "Para purgar estado y logs exporta STG_CONFIRM='PURGE'. (No se ha borrado nada del estado.)"
    fi
    echo "Purgando estado y logs (los entornos staging ya creados NO se eliminan; usa v-staging-delete)."
    rm -rf "$STG_ROOT/state/envs" 2>/dev/null || true
    rm -f "$STG_ROOT"/logs/*.log "$STG_ROOT"/logs/*.log.* 2>/dev/null || true
    stg_log "INFO" "Estado y logs purgados durante la desinstalacion."
else
    echo "Estado, logs y entornos staging conservados. Usa --purge (con STG_CONFIRM='PURGE') para borrarlos."
fi

stg_log "INFO" "Plugin Staging desinstalado (purge=$PURGE)."
echo "== Desinstalacion completada =="
