#!/bin/bash
# slack.sh - Notificador Slack del plugin Watchdog para HestiaCP.
# Interfaz comun: recibe SEVERIDAD TITULO CUERPO.
# Publica en un Incoming Webhook de Slack con curl. Reintentos con backoff.
# NUNCA loguea la URL del webhook (es secreta).

set -euo pipefail

WD_N_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "${WD_N_DIR}/../lib/common.sh"

SEVERITY="${1:-INFO}"
TITLE="${2:-Watchdog}"
BODY="${3:-}"

WD_SLACK_WEBHOOK="$(wd_conf_get WD_SLACK_WEBHOOK '')"
WD_RETRIES="$(wd_conf_get WD_NOTIFY_RETRIES 3)"
case "${WD_RETRIES}" in ''|*[!0-9]*) WD_RETRIES=3 ;; esac

if [ -z "${WD_SLACK_WEBHOOK}" ]; then
    wd_log "WARN" "slack: WD_SLACK_WEBHOOK vacia; no se envia."
    exit 0
fi

if ! command -v curl >/dev/null 2>&1; then
    wd_log "ERROR" "slack: curl no disponible."
    exit 127
fi

# Color de la barra lateral del attachment segun severidad.
case "${SEVERITY}" in
    CRITICAL) COLOR="#d00000"; ICON=":rotating_light:" ;;
    WARNING)  COLOR="#e0a000"; ICON=":warning:" ;;
    RESUELTO) COLOR="#2eb886"; ICON=":white_check_mark:" ;;
    *)        COLOR="#439fe0"; ICON=":information_source:" ;;
esac

_wd_json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | awk 'BEGIN{ORS="\\n"}{print}' | sed 's/\\n$//'
}

HOST="$(hostname 2>/dev/null || echo unknown)"
PAYLOAD="$(printf '{"attachments":[{"color":"%s","title":"%s %s","text":"%s","footer":"hestiacp-watchdog @ %s"}]}' \
    "${COLOR}" \
    "${ICON}" \
    "$(_wd_json_escape "${TITLE}")" \
    "$(_wd_json_escape "${BODY}")" \
    "$(_wd_json_escape "${HOST}")")"

_wd_slack_send_once() {
    curl -fsS --max-time 20 -o /dev/null \
        -X POST -H "Content-Type: application/json" \
        --data-binary "${PAYLOAD}" \
        "${WD_SLACK_WEBHOOK}" >/dev/null 2>&1
    return $?
}

attempt=1
delay=2
while [ "${attempt}" -le "${WD_RETRIES}" ]; do
    if _wd_slack_send_once; then
        wd_log "INFO" "slack: mensaje entregado (intento ${attempt})."
        exit 0
    fi
    wd_log "WARN" "slack: fallo intento ${attempt}/${WD_RETRIES}; reintento en ${delay}s."
    sleep "${delay}"
    attempt=$(( attempt + 1 ))
    delay=$(( delay * 2 ))
done

wd_log "ERROR" "slack: agotados ${WD_RETRIES} intentos; no entregado."
exit 1
