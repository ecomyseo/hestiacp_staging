#!/bin/bash
# Watchdog check: caducidad de certificados SSL por dominio.
# Recorre dominios ACTUALES con SSL de v-list-web-domains de cada usuario.
# Avisos escalonados: 30 (INFO), 14 (WARNING), 7 (WARNING), 1 (CRITICAL) dias.
# NO barre historico.
set -euo pipefail

WD_CHECK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "${WD_CHECK_DIR}/../lib/common.sh"

CHECK_NAME="ssl"

WARN_30="$(wd_conf_get SSL_WARN_30 '30')"
WARN_14="$(wd_conf_get SSL_WARN_14 '14')"
WARN_7="$(wd_conf_get SSL_WARN_7 '7')"
CRIT_1="$(wd_conf_get SSL_CRIT_1 '1')"
PORT="$(wd_conf_get SSL_PORT '443')"
TIMEOUT="$(wd_conf_get SSL_TIMEOUT '10')"
EXCLUDE="$(wd_conf_get SSL_EXCLUDE '')"
# Directorio de certs en disco de HestiaCP (preferente a la conexion de red).
CERT_BASE="$(wd_conf_get SSL_CERT_BASE '/usr/local/hestia/data/users')"

wd_list_users() {
    command -v v-list-users >/dev/null 2>&1 || return 0
    v-list-users shell 2>/dev/null | sed -n "s/^USER='\([^']*\)'.*/\1/p"
}

# Devuelve "DOMAIN SSL" por linea, solo dominios con SSL='yes'.
wd_list_ssl_domains() {
    local user="$1"
    command -v v-list-web-domains >/dev/null 2>&1 || return 0
    # Salida JSON parseada de forma simple: buscamos bloques con SSL 'yes'.
    v-list-web-domains "${user}" json 2>/dev/null | \
        grep -oE '"[^"]+":[[:space:]]*\{[^}]*"SSL":[[:space:]]*"yes"' | \
        sed -E 's/^"([^"]+)".*/\1/'
}

wd_excluded() {
    local d="$1"
    [ -z "${EXCLUDE}" ] && return 1
    case " $(echo "${EXCLUDE}" | tr ',' ' ') " in *" ${d} "*) return 0;; *) return 1;; esac
}

# Epoch de caducidad leyendo el cert en disco de HestiaCP; fallback a red.
wd_cert_expiry_epoch() {
    local domain="$1" user="$2" file enddate cert rc
    enddate=""
    file="${CERT_BASE}/${user}/conf/web/ssl.${domain}.crt"
    if [ -r "${file}" ] && command -v openssl >/dev/null 2>&1; then
        enddate="$(openssl x509 -enddate -noout -in "${file}" 2>/dev/null | cut -d= -f2)"
    fi
    if [ -z "${enddate:-}" ] && command -v openssl >/dev/null 2>&1; then
        # Fallback: conexion de red con SNI.
        # Separamos comandos para no enmascarar el codigo de salida del timeout
        # detras del exito del openssl x509 (un timeout no debe leerse como OK).
        cert=""
        rc=0
        cert="$(echo | timeout "${TIMEOUT}" openssl s_client -servername "${domain}" \
            -connect "${domain}:${PORT}" 2>/dev/null)" || rc=$?
        if [ "${rc}" -ne 0 ] || [ -z "${cert}" ]; then
            # Timeout (124) o fallo de conexion: no enmascarar como "cert ilegible".
            wd_log "WARN" "ssl ${domain}: conexion fallida o timeout (rc=${rc}); cert no verificado"
            return 1
        fi
        enddate="$(printf '%s\n' "${cert}" | openssl x509 -enddate -noout 2>/dev/null | cut -d= -f2)"
    fi
    [ -z "${enddate:-}" ] && return 1
    date -d "${enddate}" +%s 2>/dev/null
}

wd_check_one() {
    local domain="$1" user="$2" exp now days
    exp="$(wd_cert_expiry_epoch "${domain}" "${user}")" || {
        wd_emit "${CHECK_NAME}" "WARNING" "ssl.days{domain=${domain}}=?" "No se pudo leer cert SSL de ${domain}"
        return 0
    }
    now="$(date +%s)"
    days=$(( (exp - now) / 86400 ))

    local sev
    if [ "${days}" -le "${CRIT_1}" ]; then sev="CRITICAL"
    elif [ "${days}" -le "${WARN_7}" ]; then sev="WARNING"
    elif [ "${days}" -le "${WARN_14}" ]; then sev="WARNING"
    elif [ "${days}" -le "${WARN_30}" ]; then sev="INFO"
    else sev="INFO"; fi

    wd_emit "${CHECK_NAME}" "${sev}" "ssl.days{domain=${domain}}=${days}" "Cert SSL ${domain} caduca en ${days} dias"
}

wd_check_ssl() {
    command -v openssl >/dev/null 2>&1 || { wd_log "WARN" "openssl no disponible; check ssl omitido"; return 0; }
    local user domain
    while IFS= read -r user; do
        [ -z "${user}" ] && continue
        while IFS= read -r domain; do
            [ -z "${domain}" ] && continue
            wd_excluded "${domain}" && continue
            wd_check_one "${domain}" "${user}"
        done < <(wd_list_ssl_domains "${user}")
    done < <(wd_list_users)
}

wd_check_ssl
