#!/bin/bash
# email.sh - Notificador por email del plugin Watchdog para HestiaCP.
# Interfaz comun: recibe SEVERIDAD TITULO CUERPO.
# Usa el comando nativo de HestiaCP v-send-mail si esta disponible; si no,
# recurre a 'mail'/'sendmail'. Destinatario en WD_EMAIL_TO. Reintentos con
# backoff exponencial. NUNCA registra contenido sensible de credenciales.

set -euo pipefail

WD_N_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "${WD_N_DIR}/../lib/common.sh"

SEVERITY="${1:-INFO}"
TITLE="${2:-Watchdog}"
BODY="${3:-}"

WD_EMAIL_TO="$(wd_conf_get WD_EMAIL_TO '')"
WD_EMAIL_FROM="$(wd_conf_get WD_EMAIL_FROM 'watchdog@localhost')"
WD_RETRIES="$(wd_conf_get WD_NOTIFY_RETRIES 3)"
case "${WD_RETRIES}" in ''|*[!0-9]*) WD_RETRIES=3 ;; esac

if [ -z "${WD_EMAIL_TO}" ]; then
    wd_log "WARN" "email: WD_EMAIL_TO vacio; no se envia."
    exit 0
fi

SUBJECT="[Watchdog ${SEVERITY}] ${TITLE}"

# Intenta un envio. Devuelve 0 si exito.
_wd_email_send_once() {
    if command -v v-send-mail >/dev/null 2>&1; then
        # v-send-mail USER EMAIL SUBJECT [MESSAGE_FILE]
        local tmp
        tmp="$(mktemp)"
        printf '%s\n' "${BODY}" > "${tmp}"
        local admin
        admin="$(wd_conf_get WD_HESTIA_USER admin)"
        v-send-mail "${admin}" "${WD_EMAIL_TO}" "${SUBJECT}" "${tmp}" >/dev/null 2>&1
        local rc=$?
        rm -f "${tmp}" 2>/dev/null || true
        return ${rc}
    fi
    if command -v mail >/dev/null 2>&1; then
        printf '%s\n' "${BODY}" | mail -s "${SUBJECT}" "${WD_EMAIL_TO}" >/dev/null 2>&1
        return $?
    fi
    if command -v sendmail >/dev/null 2>&1; then
        {
            printf 'To: %s\n' "${WD_EMAIL_TO}"
            printf 'From: %s\n' "${WD_EMAIL_FROM}"
            printf 'Subject: %s\n\n' "${SUBJECT}"
            printf '%s\n' "${BODY}"
        } | sendmail -t >/dev/null 2>&1
        return $?
    fi
    wd_log "ERROR" "email: no hay v-send-mail/mail/sendmail disponible."
    return 127
}

# Bucle de reintentos con backoff exponencial (2,4,8...s).
attempt=1
delay=2
while [ "${attempt}" -le "${WD_RETRIES}" ]; do
    if _wd_email_send_once; then
        wd_log "INFO" "email: enviado a destinatario (intento ${attempt})."
        exit 0
    fi
    wd_log "WARN" "email: fallo intento ${attempt}/${WD_RETRIES}; reintento en ${delay}s."
    sleep "${delay}"
    attempt=$(( attempt + 1 ))
    delay=$(( delay * 2 ))
done

wd_log "ERROR" "email: agotados ${WD_RETRIES} intentos; no entregado."
exit 1
