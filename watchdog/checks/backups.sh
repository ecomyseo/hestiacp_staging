#!/bin/bash
# Watchdog check: antiguedad del ultimo backup por usuario de HestiaCP.
# Lee v-list-user-backups; si el ultimo backup supera el umbral de horas, alerta.
# SOLO lee estado; NUNCA dispara v-backup-user (eso seria una accion masiva).
set -euo pipefail

WD_CHECK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "${WD_CHECK_DIR}/../lib/common.sh"

CHECK_NAME="backups"

# Edad maxima aceptable del ultimo backup (horas).
AGE_WARN_H="$(wd_conf_get BACKUP_AGE_WARN_H '36')"
AGE_CRIT_H="$(wd_conf_get BACKUP_AGE_CRIT_H '72')"
EXCLUDE="$(wd_conf_get BACKUP_EXCLUDE '')"      # usuarios excluidos
# Directorio de backups de HestiaCP (fallback si el CLI no da fecha util).
BACKUP_DIR="$(wd_conf_get BACKUP_DIR '/backup')"

wd_list_users() {
    command -v v-list-users >/dev/null 2>&1 || return 0
    v-list-users shell 2>/dev/null | sed -n "s/^USER='\([^']*\)'.*/\1/p"
}

wd_excluded() {
    local u="$1"
    [ -z "${EXCLUDE}" ] && return 1
    case " $(echo "${EXCLUDE}" | tr ',' ' ') " in *" ${u} "*) return 0;; *) return 1;; esac
}

# Detecta una sola vez que dialecto de 'date' esta disponible (GNU o BSD/macOS).
# Se calcula en el ambito del script (no en subshell) para que WD_DATE_FLAVOR
# sea visible por wd_check_one al decidir entre CRITICAL real y fallo de check.
wd_detect_date_flavor() {
    if [ -n "${WD_DATE_FLAVOR:-}" ]; then return 0; fi
    if date -d '2000-01-01 00:00:00' +%s >/dev/null 2>&1; then
        WD_DATE_FLAVOR="gnu"
    elif date -j -f '%Y-%m-%d %H:%M:%S' '2000-01-01 00:00:00' +%s >/dev/null 2>&1; then
        WD_DATE_FLAVOR="bsd"
    else
        WD_DATE_FLAVOR="none"
    fi
}

# Convierte 'AAAA-MM-DD HH:MM:SS' a epoch de forma portable (GNU date o BSD/macOS).
# Vacio si ninguna implementacion de date pudo parsear la fecha.
wd_date_to_epoch() {
    local d="$1" t="$2"
    wd_detect_date_flavor
    case "${WD_DATE_FLAVOR}" in
        gnu) date -d "${d} ${t}" +%s 2>/dev/null ;;
        bsd) date -j -f '%Y-%m-%d %H:%M:%S' "${d} ${t}" +%s 2>/dev/null ;;
        *)   return 1 ;;
    esac
}

# Epoch del backup mas reciente del usuario. Vacio si no hay backups.
wd_last_backup_epoch() {
    local user="$1" line ts latest=""
    if command -v v-list-user-backups >/dev/null 2>&1; then
        # Formato shell: BACKUP='user.AAAA-MM-DD_HH-MM-SS.tar' DATE='...' TIME='...'
        while IFS= read -r line; do
            # Extrae fecha del nombre: AAAA-MM-DD_HH-MM-SS
            ts="$(echo "${line}" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}' | head -n1)"
            [ -z "${ts}" ] && continue
            # Convierte a formato que date entiende (portable GNU/BSD).
            local d="${ts%_*}" t="${ts#*_}"
            t="${t//-/:}"
            local e; e="$(wd_date_to_epoch "${d}" "${t}")" || continue
            [ -z "${e}" ] && continue
            if [ -z "${latest}" ] || [ "${e}" -gt "${latest}" ]; then latest="${e}"; fi
        done < <(v-list-user-backups "${user}" shell 2>/dev/null | sed -n "s/^BACKUP='\([^']*\)'.*/\1/p")
    fi
    # Fallback: mtime del fichero mas reciente en BACKUP_DIR.
    if [ -z "${latest}" ] && [ -d "${BACKUP_DIR}" ]; then
        local f
        f="$(ls -1t "${BACKUP_DIR}/${user}".*.tar 2>/dev/null | head -n1)"
        [ -n "${f}" ] && latest="$(stat -c %Y "${f}" 2>/dev/null || echo '')"
    fi
    echo "${latest}"
}

wd_check_one() {
    local user="$1" last now age_h
    last="$(wd_last_backup_epoch "${user}")"
    if [ -z "${last}" ]; then
        # Si 'date' no puede parsear fechas en este sistema (ni GNU ni BSD),
        # NO afirmamos "sin backup" (seria un falso CRITICAL): avisamos del fallo
        # de la comprobacion para que el operador lo sepa, sin enmascararlo como OK.
        if [ "${WD_DATE_FLAVOR:-}" = "none" ]; then
            wd_emit "${CHECK_NAME}" "WARNING" "backup.check_error{user=${user}}=1" "No se pudo verificar el backup de ${user}: 'date' sin soporte GNU ni BSD"
            return 0
        fi
        wd_emit "${CHECK_NAME}" "CRITICAL" "backup.exists{user=${user}}=0" "Usuario ${user} sin ningun backup"
        return 0
    fi
    now="$(date +%s)"
    age_h=$(( (now - last) / 3600 ))
    local sev
    if [ "${age_h}" -ge "${AGE_CRIT_H}" ]; then sev="CRITICAL"
    elif [ "${age_h}" -ge "${AGE_WARN_H}" ]; then sev="WARNING"
    else sev="INFO"; fi
    wd_emit "${CHECK_NAME}" "${sev}" "backup.age_h{user=${user}}=${age_h}" "Ultimo backup de ${user} hace ${age_h}h"
}

wd_check_backups() {
    local user
    # Resuelve el dialecto de 'date' en el ambito del padre (no en subshell),
    # para que WD_DATE_FLAVOR sea visible en wd_check_one.
    wd_detect_date_flavor
    while IFS= read -r user; do
        [ -z "${user}" ] && continue
        wd_excluded "${user}" && continue
        wd_check_one "${user}"
    done < <(wd_list_users)
}

wd_check_backups
