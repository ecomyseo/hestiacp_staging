#!/bin/bash
# Watchdog check: servicios del sistema.
# Detecta servicios HestiaCP/sistema caidos via v-list-sys-services o systemctl.
# Aplica histeresis: N lecturas consecutivas en fallo antes de marcar CRITICAL.
set -euo pipefail

# Localiza la libreria comun relativa a este script.
WD_CHECK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "${WD_CHECK_DIR}/../lib/common.sh"

CHECK_NAME="services"

# Lista de servicios a vigilar. Si esta vacia en conf, se autodetectan desde HestiaCP.
SERVICES_LIST="$(wd_conf_get SERVICES_WATCH '')"
# Numero de lecturas consecutivas en fallo antes de escalar a CRITICAL (histeresis).
HYST="$(wd_conf_get SERVICES_HYSTERESIS '2')"

# Devuelve la lista de servicios a comprobar (uno por linea).
wd_services_discover() {
    if [ -n "${SERVICES_LIST}" ]; then
        # Permite separar por espacios o comas.
        echo "${SERVICES_LIST}" | tr ',' ' ' | tr ' ' '\n' | sed '/^$/d'
        return 0
    fi
    # Autodescubrimiento desde HestiaCP (formato shell: NAME='svc'...).
    if command -v v-list-sys-services >/dev/null 2>&1; then
        v-list-sys-services shell 2>/dev/null | sed -n "s/^NAME='\([^']*\)'.*/\1/p"
        return 0
    fi
    # Conjunto minimo razonable como ultimo recurso.
    printf '%s\n' nginx mariadb exim4 dovecot named fail2ban hestia
}

# Comprueba un servicio. Devuelve 0 si activo, 1 si caido.
wd_service_active() {
    local svc="$1"
    if command -v systemctl >/dev/null 2>&1; then
        systemctl is-active --quiet "${svc}" 2>/dev/null && return 0 || return 1
    fi
    if command -v service >/dev/null 2>&1; then
        service "${svc}" status >/dev/null 2>&1 && return 0 || return 1
    fi
    # Sin gestor conocido: no se puede afirmar fallo.
    return 0
}

wd_check_services() {
    local svc fails="0" total="0"
    while IFS= read -r svc; do
        [ -z "${svc}" ] && continue
        total=$((total + 1))
        local state_key="services_fail_${svc}"
        if wd_service_active "${svc}"; then
            # Recuperado: si venia fallando, lo reporta resuelto y limpia contador.
            local prev
            prev="$(wd_state_get "${state_key}" '0')"
            if [ "${prev}" -gt 0 ] 2>/dev/null; then
                wd_state_set "${state_key}" "0"
                wd_emit "${CHECK_NAME}" "INFO" "service.${svc}=up" "Servicio ${svc} recuperado"
            fi
        else
            fails=$((fails + 1))
            local cnt
            cnt="$(wd_state_get "${state_key}" '0')"
            cnt=$((cnt + 1))
            wd_state_set "${state_key}" "${cnt}"
            wd_log "WARN" "Servicio ${svc} caido (lectura ${cnt}/${HYST})"
            if [ "${cnt}" -ge "${HYST}" ]; then
                wd_emit "${CHECK_NAME}" "CRITICAL" "service.${svc}=down" "Servicio ${svc} caido (${cnt} lecturas consecutivas)"
            else
                wd_emit "${CHECK_NAME}" "WARNING" "service.${svc}=down" "Servicio ${svc} no responde (lectura ${cnt}/${HYST})"
            fi
        fi
    done < <(wd_services_discover)

    if [ "${fails}" -eq 0 ]; then
        wd_emit "${CHECK_NAME}" "INFO" "services.down=0" "Todos los servicios vigilados (${total}) estan activos"
    fi
}

wd_check_services
