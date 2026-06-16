#!/bin/bash
# webhook.sh - Notificador webhook generico del plugin Watchdog para HestiaCP.
# Interfaz comun: recibe SEVERIDAD TITULO CUERPO.
# Hace POST de un cuerpo JSON a WD_WEBHOOK_URL con curl. Reintentos con backoff.
# NUNCA loguea la URL completa (puede contener tokens en la query/path).

set -euo pipefail

WD_N_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "${WD_N_DIR}/../lib/common.sh"

SEVERITY="${1:-INFO}"
TITLE="${2:-Watchdog}"
BODY="${3:-}"

WD_WEBHOOK_URL="$(wd_conf_get WD_WEBHOOK_URL '')"
WD_WEBHOOK_AUTH="$(wd_conf_get WD_WEBHOOK_AUTH '')"
WD_RETRIES="$(wd_conf_get WD_NOTIFY_RETRIES 3)"
case "${WD_RETRIES}" in ''|*[!0-9]*) WD_RETRIES=3 ;; esac

if [ -z "${WD_WEBHOOK_URL}" ]; then
    wd_log "WARN" "webhook: WD_WEBHOOK_URL vacia; no se envia."
    exit 0
fi

if ! command -v curl >/dev/null 2>&1; then
    wd_log "ERROR" "webhook: curl no disponible."
    exit 127
fi

# Escapa una cadena para incrustarla en JSON.
_wd_json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | awk 'BEGIN{ORS="\\n"}{print}' | sed 's/\\n$//'
}

HOST="$(hostname 2>/dev/null || echo unknown)"
TS="$(date '+%Y-%m-%dT%H:%M:%S%z')"
PAYLOAD="$(printf '{"severity":"%s","title":"%s","body":"%s","host":"%s","ts":"%s","source":"hestiacp-watchdog"}' \
    "$(_wd_json_escape "${SEVERITY}")" \
    "$(_wd_json_escape "${TITLE}")" \
    "$(_wd_json_escape "${BODY}")" \
    "$(_wd_json_escape "${HOST}")" \
    "${TS}")"

# Escapa una cadena para incrustarla como valor entre comillas en un
# fichero de configuracion de curl (-K). curl interpreta \" y \\ dentro
# de las comillas dobles, por lo que solo hay que escapar esos dos.
_wd_curl_cfg_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

_wd_wh_send_once() {
    # La URL y la cabecera Authorization pueden contener tokens secretos.
    # Para que NO aparezcan en la tabla de procesos (ps / /proc/<pid>/cmdline,
    # visible a otros usuarios del sistema) ni se filtren por trazado del
    # argv, se pasan a curl mediante un fichero de configuracion leido por
    # stdin (-K -) en lugar de como argumentos de linea de comandos.
    local rc=0
    local cfg
    cfg="url = \"$(_wd_curl_cfg_escape "${WD_WEBHOOK_URL}")\""$'\n'
    if [ -n "${WD_WEBHOOK_AUTH}" ]; then
        cfg="${cfg}header = \"Authorization: $(_wd_curl_cfg_escape "${WD_WEBHOOK_AUTH}")\""$'\n'
    fi
    # Opciones no sensibles van por argv; los secretos por -K - (stdin).
    # stderr se descarta para que un fallo verboso no exponga la URL.
    printf '%s' "${cfg}" | curl -fsS --max-time 20 -o /dev/null \
        -X POST \
        -H "Content-Type: application/json" \
        --data-binary "${PAYLOAD}" \
        -K - >/dev/null 2>&1 || rc=$?
    return "${rc}"
}

attempt=1
delay=2
while [ "${attempt}" -le "${WD_RETRIES}" ]; do
    if _wd_wh_send_once; then
        wd_log "INFO" "webhook: POST entregado (intento ${attempt})."
        exit 0
    fi
    wd_log "WARN" "webhook: fallo intento ${attempt}/${WD_RETRIES}; reintento en ${delay}s."
    sleep "${delay}"
    attempt=$(( attempt + 1 ))
    delay=$(( delay * 2 ))
done

wd_log "ERROR" "webhook: agotados ${WD_RETRIES} intentos; no entregado."
exit 1
