#!/bin/bash
# Watchdog check: seguridad basica.
# - fail2ban: jails activas y nº de IPs baneadas.
# - logins SSH fallidos en ventana reciente (anti-fuerza bruta).
# - integridad: hashes de ficheros criticos vs baseline guardado en state.
# La integridad SOLO compara el estado actual con el baseline previo; el primer
# arranque establece baseline sin alertar (evita falso positivo inicial).
set -euo pipefail

WD_CHECK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "${WD_CHECK_DIR}/../lib/common.sh"

CHECK_NAME="security"

SSH_WARN="$(wd_conf_get SEC_SSH_FAIL_WARN '20')"    # fallos en ventana
SSH_CRIT="$(wd_conf_get SEC_SSH_FAIL_CRIT '100')"
SSH_WINDOW_MIN="$(wd_conf_get SEC_SSH_WINDOW_MIN '60')"
# Nº de IPs baneadas por fail2ban: es un valor ACUMULATIVO/normal (señal de que
# fail2ban funciona), no un incidente. Por defecto es INFORMATIVO (umbral 0 =
# desactivado). Pon SEC_BAN_CRIT > 0 si quieres alertar por exceso de baneos.
BAN_WARN="$(wd_conf_get SEC_BAN_WARN '0')"
BAN_CRIT="$(wd_conf_get SEC_BAN_CRIT '0')"
# Ficheros criticos cuyo hash se vigila (separados por coma o espacio).
CRIT_FILES="$(wd_conf_get SEC_CRIT_FILES '/etc/passwd,/etc/shadow,/etc/ssh/sshd_config,/usr/local/hestia/conf/hestia.conf')"

wd_sev_int() {
    local v="$1" w="$2" c="$3"
    if [ "${v}" -ge "${c}" ]; then echo "CRITICAL"
    elif [ "${v}" -ge "${w}" ]; then echo "WARNING"
    else echo "INFO"; fi
}

# --- fail2ban ---
wd_check_fail2ban() {
    command -v fail2ban-client >/dev/null 2>&1 || { wd_log "DEBUG" "fail2ban no instalado"; return 0; }
    if ! fail2ban-client ping >/dev/null 2>&1; then
        wd_emit "${CHECK_NAME}" "WARNING" "fail2ban.up=0" "fail2ban instalado pero no responde"
        return 0
    fi
    local jails total=0 jail banned
    jails="$(fail2ban-client status 2>/dev/null | sed -n 's/.*Jail list:[[:space:]]*//p' | tr ',' ' ')"
    for jail in ${jails}; do
        jail="$(echo "${jail}" | tr -d ' ')"
        [ -z "${jail}" ] && continue
        banned="$(fail2ban-client status "${jail}" 2>/dev/null | sed -n 's/.*Currently banned:[[:space:]]*\([0-9]*\).*/\1/p')"
        case "${banned}" in ''|*[!0-9]*) banned=0;; esac
        total=$((total + banned))
    done
    # Umbral 0 = informativo (no alerta); fail2ban con muchos baneos es lo normal.
    local sev="INFO"
    if [ "${BAN_CRIT}" -gt 0 ] 2>/dev/null; then
        sev="$(wd_sev_int "${total}" "${BAN_WARN}" "${BAN_CRIT}")"
    fi
    wd_emit "${CHECK_NAME}" "${sev}" "fail2ban.banned=${total}" "fail2ban: ${total} IPs baneadas"
}

# --- Logins SSH fallidos recientes ---
# Cuenta lineas "Failed password" en un fichero de log SIN enmascarar fallos.
# grep devuelve: 0 = coincidencias, 1 = sin coincidencias, >=2 = error de
# lectura/acceso. Solo 0 y 1 son resultados validos; cualquier otro codigo
# significa que el log es inaccesible y NO debe reportarse como "0 ataques".
# Salida: imprime el recuento por stdout y devuelve 0 si la lectura fue fiable,
# o devuelve 2 (log inaccesible) sin imprimir recuento.
_wd_ssh_count_file() {
    local logf="$1" out rc
    # Captura recuento y codigo de salida sin que 'set -e' aborte cuando grep
    # devuelve 1 (sin coincidencias). El '|| rc=$?' neutraliza errexit y
    # preserva el codigo real para distinguir "sin coincidencias" de "error".
    rc=0
    out="$(grep -c -i 'failed password' "${logf}")" || rc=$?
    if [ "${rc}" -ge 2 ]; then
        return 2
    fi
    case "${out}" in
        ''|*[!0-9]*) out=0 ;;
    esac
    printf '%s' "${out}"
    return 0
}

wd_check_ssh_fails() {
    local count out rc
    if command -v journalctl >/dev/null 2>&1; then
        # '|| rc=$?' evita que 'set -e'/'pipefail' aborten cuando grep no
        # encuentra coincidencias (rc=1) y preserva el codigo real de error.
        rc=0
        out="$(journalctl -u ssh -u sshd --since "${SSH_WINDOW_MIN} min ago" 2>/dev/null | grep -c -i 'failed password')" || rc=$?
        # grep rc 0/1 = ok (con/sin coincidencias); >=2 = error de lectura.
        if [ "${rc}" -ge 2 ]; then
            wd_emit "${CHECK_NAME}" "WARNING" "ssh.log_unreadable=1" "Fuente de logs SSH (journalctl) inaccesible; recuento no fiable"
            return 0
        fi
        case "${out}" in ''|*[!0-9]*) out=0 ;; esac
        count="${out}"
    elif [ -e /var/log/auth.log ]; then
        if [ ! -r /var/log/auth.log ]; then
            wd_emit "${CHECK_NAME}" "WARNING" "ssh.log_unreadable=1" "Log SSH /var/log/auth.log existe pero no es legible; posible intrusion oculta"
            return 0
        fi
        if ! count="$(_wd_ssh_count_file /var/log/auth.log)"; then
            wd_emit "${CHECK_NAME}" "WARNING" "ssh.log_unreadable=1" "Error leyendo /var/log/auth.log; recuento no fiable"
            return 0
        fi
    elif [ -e /var/log/secure ]; then
        if [ ! -r /var/log/secure ]; then
            wd_emit "${CHECK_NAME}" "WARNING" "ssh.log_unreadable=1" "Log SSH /var/log/secure existe pero no es legible; posible intrusion oculta"
            return 0
        fi
        if ! count="$(_wd_ssh_count_file /var/log/secure)"; then
            wd_emit "${CHECK_NAME}" "WARNING" "ssh.log_unreadable=1" "Error leyendo /var/log/secure; recuento no fiable"
            return 0
        fi
    else
        # Sin ninguna fuente de logs: NO es "0 ataques", es incapacidad de
        # monitorizar. Se reporta como WARNING para no enmascarar el punto ciego.
        wd_emit "${CHECK_NAME}" "WARNING" "ssh.log_unreadable=1" "Sin fuente de logs SSH disponible; brute-force no monitorizable"
        return 0
    fi
    case "${count}" in ''|*[!0-9]*) count=0;; esac
    local sev; sev="$(wd_sev_int "${count}" "${SSH_WARN}" "${SSH_CRIT}")"
    wd_emit "${CHECK_NAME}" "${sev}" "ssh.failed=${count}" "Logins SSH fallidos (~${SSH_WINDOW_MIN}min): ${count}"
}

# --- Integridad de ficheros criticos ---
wd_hash_file() {
    local f="$1"
    [ -r "${f}" ] || return 1
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "${f}" 2>/dev/null | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "${f}" 2>/dev/null | awk '{print $1}'
    else return 1; fi
}

wd_check_integrity() {
    local f cur prev key changed=0 first=0
    for f in $(echo "${CRIT_FILES}" | tr ',' ' '); do
        [ -z "${f}" ] && continue
        cur="$(wd_hash_file "${f}")" || continue
        key="sec_hash_$(echo "${f}" | tr -c 'a-zA-Z0-9' '_')"
        prev="$(wd_state_get "${key}" '')"
        if [ -z "${prev}" ]; then
            # Primer registro: baseline sin alertar.
            wd_state_set "${key}" "${cur}"
            first=1
            continue
        fi
        if [ "${cur}" != "${prev}" ]; then
            wd_state_set "${key}" "${cur}"
            changed=$((changed + 1))
            wd_emit "${CHECK_NAME}" "CRITICAL" "integrity.changed{file=${f}}=1" "Fichero critico modificado: ${f}"
        fi
    done
    if [ "${changed}" -eq 0 ]; then
        if [ "${first}" -eq 1 ]; then
            wd_emit "${CHECK_NAME}" "INFO" "integrity.baseline=1" "Baseline de integridad establecido"
        else
            wd_emit "${CHECK_NAME}" "INFO" "integrity.changed=0" "Ficheros criticos sin cambios"
        fi
    fi
}

wd_check_fail2ban
wd_check_ssh_fails
wd_check_integrity
