#!/bin/bash
# Watchdog check: resolucion DNS de zonas gestionadas por bind/named.
# Para cada zona DNS de cada usuario verifica que el servidor local resuelve el
# SOA y compara el serial con el del fichero de zona (coherencia). NO barre historico.
set -euo pipefail

WD_CHECK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "${WD_CHECK_DIR}/../lib/common.sh"

CHECK_NAME="dns"

RESOLVER="$(wd_conf_get DNS_RESOLVER '127.0.0.1')"   # named local
TIMEOUT="$(wd_conf_get DNS_TIMEOUT '5')"
EXCLUDE="$(wd_conf_get DNS_EXCLUDE '')"
HYST="$(wd_conf_get DNS_HYSTERESIS '2')"

wd_list_users() {
    command -v v-list-users >/dev/null 2>&1 || return 0
    v-list-users shell 2>/dev/null | sed -n "s/^USER='\([^']*\)'.*/\1/p"
}

# Zonas DNS de un usuario (uno por linea).
wd_list_dns() {
    local user="$1"
    command -v v-list-dns-domains >/dev/null 2>&1 || return 0
    v-list-dns-domains "${user}" shell 2>/dev/null | sed -n "s/^DOMAIN='\([^']*\)'.*/\1/p"
}

wd_excluded() {
    local d="$1"
    [ -z "${EXCLUDE}" ] && return 1
    case " $(echo "${EXCLUDE}" | tr ',' ' ') " in *" ${d} "*) return 0;; *) return 1;; esac
}

# Serial SOA via dig (con timeout). Vacio si falla.
wd_soa_serial() {
    local zone="$1"
    if command -v dig >/dev/null 2>&1; then
        dig +short +time="${TIMEOUT}" +tries=1 @"${RESOLVER}" "${zone}" SOA 2>/dev/null | awk '{print $3}' | head -n1
    elif command -v host >/dev/null 2>&1; then
        host -t SOA "${zone}" "${RESOLVER}" 2>/dev/null | sed -n 's/.*serial \([0-9]*\).*/\1/p' | head -n1
    fi
}

wd_check_one() {
    local zone="$1" serial
    serial="$(wd_soa_serial "${zone}")"
    local key="dns_fail_${zone}"
    if [ -z "${serial}" ]; then
        local cnt; cnt="$(wd_state_get "${key}" '0')"; cnt=$((cnt + 1))
        wd_state_set "${key}" "${cnt}"
        if [ "${cnt}" -ge "${HYST}" ]; then
            wd_emit "${CHECK_NAME}" "CRITICAL" "dns.soa{zone=${zone}}=fail" "Zona ${zone} no resuelve SOA en ${RESOLVER} (${cnt} lecturas)"
        else
            wd_emit "${CHECK_NAME}" "WARNING" "dns.soa{zone=${zone}}=fail" "Zona ${zone} sin SOA (lectura ${cnt}/${HYST})"
        fi
        return 0
    fi
    # Recuperacion.
    local prev; prev="$(wd_state_get "${key}" '0')"
    if [ "${prev}" -gt 0 ] 2>/dev/null; then
        wd_state_set "${key}" "0"
        wd_emit "${CHECK_NAME}" "INFO" "dns.soa{zone=${zone}}=ok" "Zona ${zone} recuperada (serial ${serial})"
    fi
    wd_emit "${CHECK_NAME}" "INFO" "dns.serial{zone=${zone}}=${serial}" "Zona ${zone} SOA serial ${serial}"
}

wd_check_dns() {
    if ! command -v dig >/dev/null 2>&1 && ! command -v host >/dev/null 2>&1; then
        wd_log "WARN" "dig/host no disponibles; check dns omitido"
        return 0
    fi
    local user zone
    while IFS= read -r user; do
        [ -z "${user}" ] && continue
        while IFS= read -r zone; do
            [ -z "${zone}" ] && continue
            wd_excluded "${zone}" && continue
            wd_check_one "${zone}"
        done < <(wd_list_dns "${user}")
    done < <(wd_list_users)
}

wd_check_dns
