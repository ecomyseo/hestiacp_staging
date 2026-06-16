#!/bin/bash
# discord.sh - Notificador Discord del plugin Watchdog para HestiaCP.
# Interfaz comun: recibe SEVERIDAD TITULO CUERPO.
# Publica en un Webhook de Discord con curl (embeds). Reintentos con backoff.
# NUNCA loguea la URL del webhook (es secreta).

set -euo pipefail

WD_N_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "${WD_N_DIR}/../lib/common.sh"

SEVERITY="${1:-INFO}"
TITLE="${2:-Watchdog}"
BODY="${3:-}"

WD_DISCORD_WEBHOOK="$(wd_conf_get WD_DISCORD_WEBHOOK '')"
WD_RETRIES="$(wd_conf_get WD_NOTIFY_RETRIES 3)"
case "${WD_RETRIES}" in ''|*[!0-9]*) WD_RETRIES=3 ;; esac

if [ -z "${WD_DISCORD_WEBHOOK}" ]; then
    wd_log "WARN" "discord: WD_DISCORD_WEBHOOK vacia; no se envia."
    exit 0
fi

if ! command -v curl >/dev/null 2>&1; then
    wd_log "ERROR" "discord: curl no disponible."
    exit 127
fi

# Color decimal del embed segun severidad.
case "${SEVERITY}" in
    CRITICAL) COLOR="13631488" ;;  # rojo
    WARNING)  COLOR="14721536" ;;  # ambar
    RESUELTO) COLOR="3066993"  ;;  # verde
    *)        COLOR="4421080"  ;;  # azul
esac

_wd_json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | awk 'BEGIN{ORS="\\n"}{print}' | sed 's/\\n$//'
}

HOST="$(hostname 2>/dev/null || echo unknown)"
PAYLOAD="$(printf '{"embeds":[{"title":"[%s] %s","description":"%s","color":%s,"footer":{"text":"hestiacp-watchdog @ %s"}}]}' \
    "${SEVERITY}" \
    "$(_wd_json_escape "${TITLE}")" \
    "$(_wd_json_escape "${BODY}")" \
    "${COLOR}" \
    "$(_wd_json_escape "${HOST}")")"

_wd_discord_send_once() {
    curl -fsS --max-time 20 -o /dev/null \
        -X POST -H "Content-Type: application/json" \
        --data-binary "${PAYLOAD}" \
        "${WD_DISCORD_WEBHOOK}" >/dev/null 2>&1
    return $?
}

attempt=1
delay=2
while [ "${attempt}" -le "${WD_RETRIES}" ]; do
    if _wd_discord_send_once; then
        wd_log "INFO" "discord: mensaje entregado (intento ${attempt})."
        exit 0
    fi
    wd_log "WARN" "discord: fallo intento ${attempt}/${WD_RETRIES}; reintento en ${delay}s."
    sleep "${delay}"
    attempt=$(( attempt + 1 ))
    delay=$(( delay * 2 ))
done

wd_log "ERROR" "discord: agotados ${WD_RETRIES} intentos; no entregado."
exit 1
