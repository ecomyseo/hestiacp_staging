#!/bin/bash
# Watchdog check: disponibilidad HTTP/HTTPS de dominios alojados.
# Recorre los dominios ACTUALES de v-list-web-domains de cada usuario de
# v-list-users. NO barre historico. curl con timeout; valida codigo y latencia.
set -euo pipefail

WD_CHECK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "${WD_CHECK_DIR}/../lib/common.sh"

CHECK_NAME="http"

TIMEOUT="$(wd_conf_get HTTP_TIMEOUT '10')"          # segundos por peticion
EXPECT_CODES="$(wd_conf_get HTTP_EXPECT_CODES '200,301,302,401,403')"
LAT_WARN="$(wd_conf_get HTTP_LATENCY_WARN '2.0')"   # segundos
LAT_CRIT="$(wd_conf_get HTTP_LATENCY_CRIT '5.0')"   # segundos
EXCLUDE="$(wd_conf_get HTTP_EXCLUDE '')"            # dominios excluidos (coma/espacio)
HYST="$(wd_conf_get HTTP_HYSTERESIS '2')"
MAX_DOMAINS="$(wd_conf_get HTTP_MAX_DOMAINS '500')" # cortafuegos: limite por ciclo

# Valida que un valor sea un numero (entero o decimal) no negativo.
wd_is_float() {
    case "$1" in
        ''|*[!0-9.]*) return 1;;
        *.*.*) return 1;;
        *) return 0;;
    esac
}

wd_ge_float() {
    # Sin numeros validos no podemos comparar: NO enmascarar como "todo OK".
    wd_is_float "$1" || return 2
    wd_is_float "$2" || return 2
    awk -v a="$1" -v b="$2" 'BEGIN{exit !(a>=b)}'
}

# ¿Codigo HTTP dentro de los esperados?
wd_code_ok() {
    local code="$1"
    case ",${EXPECT_CODES//[[:space:]]/}," in
        *",${code},"*) return 0;;
        *) return 1;;
    esac
}

# ¿Dominio excluido?
wd_excluded() {
    local d="$1"
    [ -z "${EXCLUDE}" ] && return 1
    case " $(echo "${EXCLUDE}" | tr ',' ' ') " in
        *" ${d} "*) return 0;;
        *) return 1;;
    esac
}

# Lista usuarios desde HestiaCP (uno por linea).
wd_list_users() {
    if command -v v-list-users >/dev/null 2>&1; then
        v-list-users shell 2>/dev/null | sed -n "s/^USER='\([^']*\)'.*/\1/p"
    fi
}

# Lista dominios web de un usuario (uno por linea).
wd_list_domains() {
    local user="$1"
    if command -v v-list-web-domains >/dev/null 2>&1; then
        v-list-web-domains "${user}" shell 2>/dev/null | sed -n "s/^DOMAIN='\([^']*\)'.*/\1/p"
    fi
}

# Comprueba un unico dominio.
wd_probe_domain() {
    local domain="$1" scheme="https" url out code time line
    url="${scheme}://${domain}/"
    # -k: no fallar por cert (SSL se vigila en ssl.sh). -L: sigue redirecciones controladas? No, queremos el primer codigo.
    # Separador etiquetado + parseo linea a linea: robusto frente a espacios/saltos extra.
    out="$(curl -sS -o /dev/null -m "${TIMEOUT}" \
        -w 'CODE:%{http_code}\nTIME:%{time_total}\n' \
        -A 'HestiaCP-Watchdog/1.0' -k "${url}" 2>/dev/null || true)"
    code=""
    time=""
    while IFS= read -r line; do
        case "${line}" in
            CODE:*) code="${line#CODE:}";;
            TIME:*) time="${line#TIME:}";;
        esac
    done <<EOF
${out}
EOF
    # Saneo: quitar espacios sobrantes alrededor de los valores.
    code="${code//[[:space:]]/}"
    time="${time//[[:space:]]/}"
    # Si curl fallo (timeout/conexion) los campos quedan vacios o el codigo es 000.
    [ -z "${code}" ] && code="000"
    # Latencia no parseable -> 0 para que no dispare CRITICAL falso (el codigo manda).
    wd_is_float "${time}" || time="0"
    local state_key="http_fail_${domain}"

    if [ "${code}" = "000" ]; then
        local cnt; cnt="$(wd_state_get "${state_key}" '0')"; cnt=$((cnt + 1))
        wd_state_set "${state_key}" "${cnt}"
        if [ "${cnt}" -ge "${HYST}" ]; then
            wd_emit "${CHECK_NAME}" "CRITICAL" "http.code{domain=${domain}}=000" "Dominio ${domain} no responde (timeout/conexion, ${cnt} lecturas)"
        else
            wd_emit "${CHECK_NAME}" "WARNING" "http.code{domain=${domain}}=000" "Dominio ${domain} sin respuesta (lectura ${cnt}/${HYST})"
        fi
        return 0
    fi

    if wd_code_ok "${code}"; then
        # Recuperacion.
        local prev; prev="$(wd_state_get "${state_key}" '0')"
        if [ "${prev}" -gt 0 ] 2>/dev/null; then
            wd_state_set "${state_key}" "0"
            wd_emit "${CHECK_NAME}" "INFO" "http.code{domain=${domain}}=${code}" "Dominio ${domain} recuperado (${code})"
        fi
        # Latencia.
        if wd_ge_float "${time}" "${LAT_CRIT}"; then
            wd_emit "${CHECK_NAME}" "CRITICAL" "http.latency{domain=${domain}}=${time}" "Dominio ${domain} lento: ${time}s"
        elif wd_ge_float "${time}" "${LAT_WARN}"; then
            wd_emit "${CHECK_NAME}" "WARNING" "http.latency{domain=${domain}}=${time}" "Dominio ${domain} latencia ${time}s"
        else
            wd_emit "${CHECK_NAME}" "INFO" "http.code{domain=${domain}}=${code}" "Dominio ${domain} OK (${code}, ${time}s)"
        fi
    else
        local cnt; cnt="$(wd_state_get "${state_key}" '0')"; cnt=$((cnt + 1))
        wd_state_set "${state_key}" "${cnt}"
        if [ "${cnt}" -ge "${HYST}" ]; then
            wd_emit "${CHECK_NAME}" "CRITICAL" "http.code{domain=${domain}}=${code}" "Dominio ${domain} codigo inesperado ${code} (${cnt} lecturas)"
        else
            wd_emit "${CHECK_NAME}" "WARNING" "http.code{domain=${domain}}=${code}" "Dominio ${domain} codigo ${code} (lectura ${cnt}/${HYST})"
        fi
    fi
}

wd_check_http() {
    command -v curl >/dev/null 2>&1 || { wd_log "WARN" "curl no disponible; check http omitido"; return 0; }
    local count="0" user domain
    while IFS= read -r user; do
        [ -z "${user}" ] && continue
        while IFS= read -r domain; do
            [ -z "${domain}" ] && continue
            wd_excluded "${domain}" && continue
            count=$((count + 1))
            if [ "${count}" -gt "${MAX_DOMAINS}" ]; then
                wd_log "WARN" "Limite HTTP_MAX_DOMAINS=${MAX_DOMAINS} alcanzado; resto omitido este ciclo"
                wd_emit "${CHECK_NAME}" "WARNING" "http.checked=${MAX_DOMAINS}" "Limite de dominios por ciclo alcanzado (${MAX_DOMAINS})"
                return 0
            fi
            wd_probe_domain "${domain}"
        done < <(wd_list_domains "${user}")
    done < <(wd_list_users)
    wd_log "INFO" "Check http completado: ${count} dominios"
}

wd_check_http
