#!/bin/bash
# Watchdog check: recursos del sistema.
# CPU (/proc/stat), RAM/swap (free), load (uptime), disco (df), inodos (df -i).
# Umbrales WARNING/CRITICAL configurables; histeresis para CPU/load (volatiles).
set -euo pipefail

WD_CHECK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "${WD_CHECK_DIR}/../lib/common.sh"

CHECK_NAME="resources"

# Umbrales (porcentaje salvo load, que es ratio respecto a nucleos).
CPU_WARN="$(wd_conf_get RES_CPU_WARN '85')"
CPU_CRIT="$(wd_conf_get RES_CPU_CRIT '95')"
MEM_WARN="$(wd_conf_get RES_MEM_WARN '85')"
MEM_CRIT="$(wd_conf_get RES_MEM_CRIT '95')"
SWAP_WARN="$(wd_conf_get RES_SWAP_WARN '50')"
SWAP_CRIT="$(wd_conf_get RES_SWAP_CRIT '90')"
LOAD_WARN="$(wd_conf_get RES_LOAD_WARN '1.5')"   # x nucleos
LOAD_CRIT="$(wd_conf_get RES_LOAD_CRIT '3.0')"   # x nucleos
DISK_WARN="$(wd_conf_get RES_DISK_WARN '85')"
DISK_CRIT="$(wd_conf_get RES_DISK_CRIT '95')"
INODE_WARN="$(wd_conf_get RES_INODE_WARN '85')"
INODE_CRIT="$(wd_conf_get RES_INODE_CRIT '95')"
HYST="$(wd_conf_get RES_HYSTERESIS '2')"

# Severidad segun valor entero y dos umbrales.
wd_sev_int() {
    local val="$1" warn="$2" crit="$3"
    if [ "${val}" -ge "${crit}" ]; then echo "CRITICAL"
    elif [ "${val}" -ge "${warn}" ]; then echo "WARNING"
    else echo "INFO"; fi
}

# Valida que un argumento sea un numero (entero o decimal) con signo opcional.
# Acepta: 12, 12.5, .5, +3, -0.7. Rechaza vacios, texto, multiples puntos, etc.
# Devuelve 0 si es numerico valido, 1 en caso contrario.
_wd_is_number() {
    local v="$1"
    [ -n "$v" ] || return 1
    # Rechaza cualquier caracter fuera de digitos, punto o signo inicial.
    case "$v" in
        *[!0-9.+-]*) return 1 ;;
    esac
    # Estructura: signo opcional, digitos y como mucho un punto, con al menos
    # un digito. awk valida la forma final sin coercion silenciosa.
    awk -v x="$v" 'BEGIN{exit (x ~ /^[+-]?([0-9]+(\.[0-9]*)?|\.[0-9]+)$/) ? 0 : 1}'
}

# Comparacion de floats con awk (devuelve 0 si a>=b).
# Valida ambos operandos antes de comparar: awk coercionaria silenciosamente
# cualquier valor no numerico a 0, lo que desactivaria comprobaciones CRITICAL
# (regla anti-catastrofe: nunca enmascarar un fallo de comprobacion como "OK").
# Si algun operando no es numerico se registra un WARN y se devuelve 2 (error,
# tratado como "falso" por los llamadores), sin falsear el resultado.
wd_ge_float() {
    local a="$1" b="$2"
    if ! _wd_is_number "$a" || ! _wd_is_number "$b"; then
        wd_log WARN "wd_ge_float: operando no numerico (a='${a}' b='${b}'); comprobacion no fiable"
        return 2
    fi
    awk -v a="$a" -v b="$b" 'BEGIN{exit !(a>=b)}'
}

# Histeresis sobre una metrica que solo escala si severidad != INFO N veces.
# Args: metric_key severidad. Devuelve severidad efectiva por stdout.
wd_apply_hyst() {
    local key="$1" sev="$2" cnt
    if [ "${sev}" = "INFO" ]; then
        wd_state_set "res_hyst_${key}" "0"
        echo "INFO"; return 0
    fi
    cnt="$(wd_state_get "res_hyst_${key}" '0')"
    cnt=$((cnt + 1))
    wd_state_set "res_hyst_${key}" "${cnt}"
    if [ "${cnt}" -ge "${HYST}" ]; then
        echo "${sev}"
    else
        echo "INFO"   # aun no confirmado: no se notifica
    fi
}

# --- CPU ---
wd_check_cpu() {
    [ -r /proc/stat ] || return 0
    local a b idle1 idle2 total1 total2
    a="$(grep '^cpu ' /proc/stat)"
    sleep 1
    b="$(grep '^cpu ' /proc/stat)"
    # Campos: user nice system idle iowait irq softirq steal
    read -r _ u1 n1 s1 id1 io1 ir1 so1 st1 _ <<<"${a}"
    read -r _ u2 n2 s2 id2 io2 ir2 so2 st2 _ <<<"${b}"
    idle1=$((id1 + io1)); idle2=$((id2 + io2))
    total1=$((u1 + n1 + s1 + id1 + io1 + ir1 + so1 + st1))
    total2=$((u2 + n2 + s2 + id2 + io2 + ir2 + so2 + st2))
    local dt=$((total2 - total1)) di=$((idle2 - idle1))
    [ "${dt}" -le 0 ] && return 0
    local usage=$(( (100 * (dt - di)) / dt ))
    local sev; sev="$(wd_sev_int "${usage}" "${CPU_WARN}" "${CPU_CRIT}")"
    sev="$(wd_apply_hyst cpu "${sev}")"
    wd_emit "${CHECK_NAME}" "${sev}" "cpu.usage=${usage}" "Uso de CPU ${usage}%"
}

# --- RAM / swap ---
wd_check_mem() {
    command -v free >/dev/null 2>&1 || return 0
    local mt ma st su
    mt="$(free -m | awk '/^Mem:/{print $2}')"
    ma="$(free -m | awk '/^Mem:/{print $7}')"   # available
    st="$(free -m | awk '/^Swap:/{print $2}')"
    su="$(free -m | awk '/^Swap:/{print $3}')"
    if [ -n "${mt}" ] && [ "${mt}" -gt 0 ]; then
        local used_pct=$(( (100 * (mt - ma)) / mt ))
        local sev; sev="$(wd_sev_int "${used_pct}" "${MEM_WARN}" "${MEM_CRIT}")"
        sev="$(wd_apply_hyst mem "${sev}")"
        wd_emit "${CHECK_NAME}" "${sev}" "mem.usage=${used_pct}" "Uso de RAM ${used_pct}% (${ma}MB libres de ${mt}MB)"
    fi
    if [ -n "${st}" ] && [ "${st}" -gt 0 ]; then
        local swap_pct=$(( (100 * su) / st ))
        local sev2; sev2="$(wd_sev_int "${swap_pct}" "${SWAP_WARN}" "${SWAP_CRIT}")"
        sev2="$(wd_apply_hyst swap "${sev2}")"
        wd_emit "${CHECK_NAME}" "${sev2}" "swap.usage=${swap_pct}" "Uso de swap ${swap_pct}%"
    fi
}

# --- Load average normalizada por nucleos ---
wd_check_load() {
    [ -r /proc/loadavg ] || return 0
    local l1 cores ratio sev
    l1="$(awk '{print $1}' /proc/loadavg)"
    cores="$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 1)"
    [ "${cores}" -lt 1 ] && cores=1
    ratio="$(awk -v l="${l1}" -v c="${cores}" 'BEGIN{printf "%.2f", l/c}')"
    if wd_ge_float "${ratio}" "${LOAD_CRIT}"; then sev="CRITICAL"
    elif wd_ge_float "${ratio}" "${LOAD_WARN}"; then sev="WARNING"
    else sev="INFO"; fi
    sev="$(wd_apply_hyst load "${sev}")"
    wd_emit "${CHECK_NAME}" "${sev}" "load.ratio=${ratio}" "Load 1m ${l1} (${ratio}x sobre ${cores} nucleos)"
}

# --- Disco e inodos por particion ---
wd_check_disk() {
    command -v df >/dev/null 2>&1 || return 0
    # Espacio: excluye pseudo-FS.
    df -P -x tmpfs -x devtmpfs -x squashfs -x overlay -x efivarfs -x ramfs -x debugfs -x configfs 2>/dev/null | tail -n +2 | while read -r fs blocks used avail pct mount; do
        local p="${pct%\%}"
        [ -z "${p}" ] && continue
        case "${p}" in *[!0-9]*) continue;; esac
        local sev; sev="$(wd_sev_int "${p}" "${DISK_WARN}" "${DISK_CRIT}")"
        # El disco no flapping: se notifica directo (sin histeresis).
        wd_emit "${CHECK_NAME}" "${sev}" "disk.pct{mount=${mount}}=${p}" "Disco ${mount} al ${p}% (${avail} libres)"
    done
    # Inodos.
    df -P -i -x tmpfs -x devtmpfs -x squashfs -x overlay -x efivarfs -x ramfs -x debugfs -x configfs 2>/dev/null | tail -n +2 | while read -r fs inodes iused ifree pct mount; do
        local p="${pct%\%}"
        [ -z "${p}" ] && continue
        case "${p}" in *[!0-9]*) continue;; esac
        local sev; sev="$(wd_sev_int "${p}" "${INODE_WARN}" "${INODE_CRIT}")"
        wd_emit "${CHECK_NAME}" "${sev}" "inode.pct{mount=${mount}}=${p}" "Inodos ${mount} al ${p}%"
    done
}

wd_check_cpu
wd_check_mem
wd_check_load
wd_check_disk
