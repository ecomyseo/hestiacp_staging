#!/bin/bash
# uninstall.sh - Desinstalador del plugin Watchdog para HestiaCP.
# Elimina el cron, el enlace del comando en el panel y, opcionalmente, los
# datos de estado y logs. No borra conf/watchdog.conf por seguridad.
# Uso: ./uninstall.sh [--purge]   (--purge elimina tambien state/ y logs/)
set -euo pipefail

WD_ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
export WD_ROOT
# shellcheck source=lib/common.sh
. "$WD_ROOT/lib/common.sh"

HESTIA="${HESTIA:-/usr/local/hestia}"
HESTIA_BIN="$HESTIA/bin"
# Autodetecta el usuario admin del panel (ROLE='admin'); fallback al primero.
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

PURGE="false"
[ "${1:-}" = "--purge" ] && PURGE="true"

echo "== Watchdog :: desinstalacion =="

# ---------------------------------------------------------------------------
# 1) Elimina el/los cron job(s) que apunten al watchdog.
# ---------------------------------------------------------------------------
if [ -x "$HESTIA_BIN/v-list-cron-jobs" ] && [ -x "$HESTIA_BIN/v-delete-cron-job" ]; then
    # Recorre los jobs y borra los que referencian v-watchdog-run.
    while read -r job_id; do
        [ -z "$job_id" ] && continue
        if "$HESTIA_BIN/v-delete-cron-job" "$CRON_USER" "$job_id"; then
            echo "Cron eliminado (id $job_id) de $CRON_USER."
        fi
    done < <("$HESTIA_BIN/v-list-cron-jobs" "$CRON_USER" plain 2>/dev/null \
                | awk '/v-watchdog-run/ {print $1}')
else
    echo "AVISO: comandos de cron no disponibles; elimina el cron manualmente." >&2
fi

# ---------------------------------------------------------------------------
# 2) Elimina TODOS los comandos del plugin en el PATH del panel (symlink o
#    wrapper que ejecuta nuestro bin). No toca comandos ajenos.
# ---------------------------------------------------------------------------
for src in "$WD_ROOT"/bin/v-watchdog-*; do
    [ -e "$src" ] || continue
    dst="$HESTIA_BIN/$(basename "$src")"
    [ -e "$dst" ] || [ -L "$dst" ] || continue
    if { [ -L "$dst" ] && [ "$(readlink -f "$dst" 2>/dev/null)" = "$(readlink -f "$src" 2>/dev/null)" ]; } \
        || grep -qF "$src" "$dst" 2>/dev/null; then
        rm -f "$dst" && echo "Comando eliminado: $(basename "$src")"
    fi
done

# ---------------------------------------------------------------------------
# 2b) Retira la integracion en la UI del panel: entrada de menu WATCHDOG y los
#     botones de Server Settings. Valida con php -l antes de aplicar.
# ---------------------------------------------------------------------------
remove_ui_integration() {
    command -v php >/dev/null 2>&1 || return 0
    local f
    for f in "$HESTIA/web/templates/includes/panel.php" "$HESTIA/web/templates/pages/edit_server.php"; do
        [ -f "$f" ] || continue
        grep -q "ECOM_WATCHDOG_MENU\|ECOM_PLUGINS_BTNS" "$f" || continue
        awk '/ECOM_WATCHDOG_MENU inicio/{s=1} /ECOM_PLUGINS_BTNS inicio/{s=1} !s{print} /ECOM_WATCHDOG_MENU fin/{s=0} /ECOM_PLUGINS_BTNS fin/{s=0}' "$f" > "$f.new"
        if php -l "$f.new" >/dev/null 2>&1; then
            mv -f "$f.new" "$f"
            echo "Integracion UI retirada de $(basename "$f")."
        else
            mv -f "$f.new" "/tmp/$(basename "$f").invalid" 2>/dev/null || true
            echo "AVISO: no se pudo limpiar $(basename "$f") de forma segura." >&2
        fi
    done
}
remove_ui_integration

# ---------------------------------------------------------------------------
# 3) Purga opcional de estado y logs.
# ---------------------------------------------------------------------------
if [ "$PURGE" = "true" ]; then
    rm -rf "$WD_STATE_DIR" "$WD_LOG_DIR"
    echo "Estado y logs eliminados (--purge)."
else
    echo "Conservados state/ y logs/ (usa --purge para borrarlos)."
fi

echo "conf/watchdog.conf NO se elimina (conserva tu configuracion)."
echo "== Desinstalacion completada =="
