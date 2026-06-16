#!/bin/bash
# Watchdog check: cola de correo de Exim.
# Vigila: tamano de cola (exim -bpc) y mensajes congelados (frozen).
# Histeresis sobre el tamano para evitar falsos positivos por picos puntuales.
set -euo pipefail

WD_CHECK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "${WD_CHECK_DIR}/../lib/common.sh"

CHECK_NAME="exim_queue"

QUEUE_WARN="$(wd_conf_get EXIM_QUEUE_WARN '500')"
QUEUE_CRIT="$(wd_conf_get EXIM_QUEUE_CRIT '2000')"
FROZEN_WARN="$(wd_conf_get EXIM_FROZEN_WARN '10')"
FROZEN_CRIT="$(wd_conf_get EXIM_FROZEN_CRIT '50')"
HYST="$(wd_conf_get EXIM_HYSTERESIS '2')"

# Localiza el binario exim (puede ser exim o exim4).
wd_exim_bin() {
    command -v exim >/dev/null 2>&1 && { echo exim; return 0; }
    command -v exim4 >/dev/null 2>&1 && { echo exim4; return 0; }
    return 1
}

wd_sev_int() {
    local v="$1" w="$2" c="$3"
    if [ "${v}" -ge "${c}" ]; then echo "CRITICAL"
    elif [ "${v}" -ge "${w}" ]; then echo "WARNING"
    else echo "INFO"; fi
}

wd_apply_hyst() {
    local key="$1" sev="$2" cnt
    if [ "${sev}" = "INFO" ]; then wd_state_set "exim_hyst_${key}" "0"; echo "INFO"; return 0; fi
    cnt="$(wd_state_get "exim_hyst_${key}" '0')"; cnt=$((cnt + 1))
    wd_state_set "exim_hyst_${key}" "${cnt}"
    [ "${cnt}" -ge "${HYST}" ] && echo "${sev}" || echo "INFO"
}

wd_check_exim() {
    local bin
    bin="$(wd_exim_bin)" || { wd_log "DEBUG" "exim no instalado; check omitido"; return 0; }

    # Tamano total de la cola.
    local qcount
    qcount="$("${bin}" -bpc 2>/dev/null || echo '')"
    case "${qcount}" in ''|*[!0-9]*) qcount=0;; esac
    local sev; sev="$(wd_sev_int "${qcount}" "${QUEUE_WARN}" "${QUEUE_CRIT}")"
    sev="$(wd_apply_hyst queue "${sev}")"
    wd_emit "${CHECK_NAME}" "${sev}" "exim.queue=${qcount}" "Cola Exim: ${qcount} mensajes"

    # Mensajes frozen (primer campo de exim -bp marcado con *** frozen ***).
    local frozen
    frozen="$("${bin}" -bp 2>/dev/null | grep -c 'frozen' || true)"
    case "${frozen}" in ''|*[!0-9]*) frozen=0;; esac
    local sevf; sevf="$(wd_sev_int "${frozen}" "${FROZEN_WARN}" "${FROZEN_CRIT}")"
    sevf="$(wd_apply_hyst frozen "${sevf}")"
    wd_emit "${CHECK_NAME}" "${sevf}" "exim.frozen=${frozen}" "Mensajes frozen en Exim: ${frozen}"
}

wd_check_exim
