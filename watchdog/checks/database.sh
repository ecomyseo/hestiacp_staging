#!/bin/bash
# Watchdog check: bases de datos (MariaDB/MySQL y PostgreSQL).
# Vigila: conectividad, numero de conexiones, consultas lentas (long-running) y
# tamano total. Usa credenciales root locales de HestiaCP cuando existen.
set -euo pipefail

WD_CHECK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "${WD_CHECK_DIR}/../lib/common.sh"

CHECK_NAME="database"

CONN_WARN="$(wd_conf_get DB_CONN_WARN '80')"        # % de max_connections
CONN_CRIT="$(wd_conf_get DB_CONN_CRIT '95')"
SLOW_SECS="$(wd_conf_get DB_SLOW_SECS '30')"        # query > N s = lenta
SLOW_WARN="$(wd_conf_get DB_SLOW_WARN '1')"         # nº de lentas para WARNING
SLOW_CRIT="$(wd_conf_get DB_SLOW_CRIT '5')"
SIZE_WARN_GB="$(wd_conf_get DB_SIZE_WARN_GB '0')"   # 0 = desactivado
HYST="$(wd_conf_get DB_HYSTERESIS '2')"

# Ruta de credenciales locales de HestiaCP (root sin password vía socket o .my.cnf).
MYSQL_DEFAULTS="$(wd_conf_get DB_MYSQL_DEFAULTS '/usr/local/hestia/conf/mysql.conf')"

wd_sev_int() {
    local v="$1" w="$2" c="$3"
    if [ "${v}" -ge "${c}" ]; then echo "CRITICAL"
    elif [ "${v}" -ge "${w}" ]; then echo "WARNING"
    else echo "INFO"; fi
}

# Cliente mysql disponible.
wd_mysql_bin() {
    command -v mysql >/dev/null 2>&1 && { echo mysql; return 0; }
    command -v mariadb >/dev/null 2>&1 && { echo mariadb; return 0; }
    return 1
}

# Ejecuta SQL en MySQL/MariaDB de forma silenciosa. Usa socket root local.
wd_mysql_q() {
    local bin; bin="$(wd_mysql_bin)" || return 1
    "${bin}" -N -B -e "$1" 2>/dev/null
}

wd_check_mysql() {
    wd_mysql_bin >/dev/null 2>&1 || { wd_log "DEBUG" "mysql/mariadb no instalado"; return 0; }
    # Conectividad.
    if ! wd_mysql_q "SELECT 1;" >/dev/null; then
        local k="db_mysql_down" cnt; cnt="$(wd_state_get "${k}" '0')"; cnt=$((cnt + 1))
        wd_state_set "${k}" "${cnt}"
        if [ "${cnt}" -ge "${HYST}" ]; then
            wd_emit "${CHECK_NAME}" "CRITICAL" "mysql.up=0" "MySQL/MariaDB no acepta conexiones (${cnt} lecturas)"
        else
            wd_emit "${CHECK_NAME}" "WARNING" "mysql.up=0" "MySQL/MariaDB sin respuesta (lectura ${cnt}/${HYST})"
        fi
        return 0
    fi
    wd_state_set "db_mysql_down" "0"

    # Conexiones actuales vs maximas.
    local used max pct
    used="$(wd_mysql_q "SHOW STATUS LIKE 'Threads_connected';" | awk '{print $2}')"
    max="$(wd_mysql_q "SHOW VARIABLES LIKE 'max_connections';" | awk '{print $2}')"
    if [ -n "${used}" ] && [ -n "${max}" ] && [ "${max}" -gt 0 ] 2>/dev/null; then
        pct=$(( (100 * used) / max ))
        local sev; sev="$(wd_sev_int "${pct}" "${CONN_WARN}" "${CONN_CRIT}")"
        wd_emit "${CHECK_NAME}" "${sev}" "mysql.conn_pct=${pct}" "MySQL conexiones ${used}/${max} (${pct}%)"
    fi

    # Consultas lentas en curso (excluye estado Sleep y al propio cliente).
    local slow
    slow="$(wd_mysql_q "SELECT COUNT(*) FROM information_schema.PROCESSLIST WHERE COMMAND<>'Sleep' AND TIME>=${SLOW_SECS} AND INFO IS NOT NULL;")"
    slow="${slow:-0}"
    if [ "${slow}" -ge "${SLOW_CRIT}" ] 2>/dev/null; then
        wd_emit "${CHECK_NAME}" "CRITICAL" "mysql.slow=${slow}" "MySQL ${slow} consultas >= ${SLOW_SECS}s"
    elif [ "${slow}" -ge "${SLOW_WARN}" ] 2>/dev/null; then
        wd_emit "${CHECK_NAME}" "WARNING" "mysql.slow=${slow}" "MySQL ${slow} consultas lentas (>= ${SLOW_SECS}s)"
    else
        wd_emit "${CHECK_NAME}" "INFO" "mysql.slow=0" "MySQL sin consultas lentas"
    fi

    # Tamano total de datos.
    local sizemb
    sizemb="$(wd_mysql_q "SELECT ROUND(SUM(data_length+index_length)/1024/1024) FROM information_schema.TABLES;")"
    sizemb="${sizemb:-0}"
    if [ "${SIZE_WARN_GB}" -gt 0 ] 2>/dev/null; then
        local warnmb=$((SIZE_WARN_GB * 1024))
        if [ "${sizemb}" -ge "${warnmb}" ] 2>/dev/null; then
            wd_emit "${CHECK_NAME}" "WARNING" "mysql.size_mb=${sizemb}" "MySQL tamano ${sizemb}MB supera ${SIZE_WARN_GB}GB"
        else
            wd_emit "${CHECK_NAME}" "INFO" "mysql.size_mb=${sizemb}" "MySQL tamano ${sizemb}MB"
        fi
    else
        wd_emit "${CHECK_NAME}" "INFO" "mysql.size_mb=${sizemb}" "MySQL tamano ${sizemb}MB"
    fi
}

# --- PostgreSQL ---
wd_psql_q() {
    # Ejecuta como usuario postgres si somos root; si no, directo.
    if [ "$(id -u)" = "0" ] && command -v sudo >/dev/null 2>&1; then
        sudo -u postgres psql -tAq -c "$1" 2>/dev/null
    else
        psql -tAq -c "$1" 2>/dev/null
    fi
}

wd_check_postgres() {
    command -v psql >/dev/null 2>&1 || { wd_log "DEBUG" "psql no instalado"; return 0; }
    # ¿Hay servidor corriendo? Conectividad.
    if ! wd_psql_q "SELECT 1;" >/dev/null; then
        # Solo alertar si postgres parece instalado como servicio.
        if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files 2>/dev/null | grep -q '^postgresql'; then
            local k="db_pg_down" cnt; cnt="$(wd_state_get "${k}" '0')"; cnt=$((cnt + 1))
            wd_state_set "${k}" "${cnt}"
            if [ "${cnt}" -ge "${HYST}" ]; then
                wd_emit "${CHECK_NAME}" "CRITICAL" "pg.up=0" "PostgreSQL no acepta conexiones (${cnt} lecturas)"
            else
                wd_emit "${CHECK_NAME}" "WARNING" "pg.up=0" "PostgreSQL sin respuesta (lectura ${cnt}/${HYST})"
            fi
        fi
        return 0
    fi
    wd_state_set "db_pg_down" "0"

    local used max pct
    used="$(wd_psql_q "SELECT count(*) FROM pg_stat_activity;")"
    max="$(wd_psql_q "SHOW max_connections;")"
    if [ -n "${used}" ] && [ -n "${max}" ] && [ "${max}" -gt 0 ] 2>/dev/null; then
        pct=$(( (100 * used) / max ))
        local sev; sev="$(wd_sev_int "${pct}" "${CONN_WARN}" "${CONN_CRIT}")"
        wd_emit "${CHECK_NAME}" "${sev}" "pg.conn_pct=${pct}" "PostgreSQL conexiones ${used}/${max} (${pct}%)"
    fi

    local slow
    slow="$(wd_psql_q "SELECT count(*) FROM pg_stat_activity WHERE state='active' AND now()-query_start > interval '${SLOW_SECS} seconds';")"
    slow="${slow:-0}"
    if [ "${slow}" -ge "${SLOW_CRIT}" ] 2>/dev/null; then
        wd_emit "${CHECK_NAME}" "CRITICAL" "pg.slow=${slow}" "PostgreSQL ${slow} consultas >= ${SLOW_SECS}s"
    elif [ "${slow}" -ge "${SLOW_WARN}" ] 2>/dev/null; then
        wd_emit "${CHECK_NAME}" "WARNING" "pg.slow=${slow}" "PostgreSQL ${slow} consultas lentas"
    else
        wd_emit "${CHECK_NAME}" "INFO" "pg.slow=0" "PostgreSQL sin consultas lentas"
    fi
}

wd_check_mysql
wd_check_postgres
