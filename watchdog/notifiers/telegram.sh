#!/bin/bash
# telegram.sh - Notificador por Telegram del plugin Watchdog para HestiaCP.
# Interfaz comun: recibe SEVERIDAD TITULO CUERPO.
# Envia via Bot API (sendMessage) con curl. Token y chat id desde conf.
# Reintentos con backoff exponencial. NUNCA loguea el token ni la URL completa.

set -euo pipefail

WD_N_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "${WD_N_DIR}/../lib/common.sh"

SEVERITY="${1:-INFO}"
TITLE="${2:-Watchdog}"
BODY="${3:-}"

WD_TELEGRAM_TOKEN="$(wd_conf_get WD_TELEGRAM_TOKEN '')"
WD_TELEGRAM_CHAT_ID="$(wd_conf_get WD_TELEGRAM_CHAT_ID '')"
WD_RETRIES="$(wd_conf_get WD_NOTIFY_RETRIES 3)"
case "${WD_RETRIES}" in ''|*[!0-9]*) WD_RETRIES=3 ;; esac

if [ -z "${WD_TELEGRAM_TOKEN}" ] || [ -z "${WD_TELEGRAM_CHAT_ID}" ]; then
    wd_log "WARN" "telegram: token o chat_id vacios; no se envia."
    exit 0
fi

if ! command -v curl >/dev/null 2>&1; then
    wd_log "ERROR" "telegram: curl no disponible."
    exit 127
fi

# Iconos por severidad para legibilidad.
case "${SEVERITY}" in
    CRITICAL) ICON="[CRITICO]" ;;
    WARNING)  ICON="[AVISO]" ;;
    RESUELTO) ICON="[OK]" ;;
    *)        ICON="[INFO]" ;;
esac

# Mensaje en texto plano (evita problemas de parseo Markdown/HTML).
TEXT="${ICON} ${TITLE}

${BODY}"

API_URL="https://api.telegram.org/bot${WD_TELEGRAM_TOKEN}/sendMessage"

_wd_tg_send_once() {
    # El token va dentro de API_URL. Para que NO aparezca en la linea de comandos
    # del proceso (visible en /proc/<pid>/cmdline a otros usuarios del sistema),
    # la URL se pasa a curl mediante un fichero de configuracion leido por stdin
    # (--config -). Asi el token no figura nunca en los argumentos del proceso.
    # --data-urlencode escapa el contenido; -o /dev/null evita volcar respuesta.
    printf 'url = "%s"\n' "${API_URL}" | curl -fsS --max-time 20 \
        -o /dev/null \
        --data-urlencode "chat_id=${WD_TELEGRAM_CHAT_ID}" \
        --data-urlencode "text=${TEXT}" \
        --data-urlencode "disable_web_page_preview=true" \
        --config - >/dev/null 2>&1
    return $?
}

attempt=1
delay=2
while [ "${attempt}" -le "${WD_RETRIES}" ]; do
    if _wd_tg_send_once; then
        wd_log "INFO" "telegram: mensaje entregado (intento ${attempt})."
        exit 0
    fi
    wd_log "WARN" "telegram: fallo intento ${attempt}/${WD_RETRIES}; reintento en ${delay}s."
    sleep "${delay}"
    attempt=$(( attempt + 1 ))
    delay=$(( delay * 2 ))
done

wd_log "ERROR" "telegram: agotados ${WD_RETRIES} intentos; no entregado."
exit 1
