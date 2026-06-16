#!/bin/bash
# alerts.sh - Motor de alertas del plugin Watchdog para HestiaCP.
# Consume los resultados de los checks (lineas JSON-ish de wd_emit), aplica la
# ventana anti-duplicado (wd_should_notify), rate-limit global por hora,
# escalado WARNING->CRITICAL si la condicion persiste, agrupacion en digest y
# mensaje RESUELTO al volver a OK. RESPETA WD_KILL_SWITCH: si esta activo no
# despacha NADA hacia los notificadores.
#
# Uso tipico (los checks escriben en stdout, se canalizan aqui):
#   ./checks/services.sh | ./lib/alerts.sh
# O sobre un fichero:
#   ./lib/alerts.sh < resultados.ndjson
#
# Cada linea de entrada debe tener forma:
#   {"ts":"...","check":"NAME","severity":"INFO|WARNING|CRITICAL","metric":"...","msg":"..."}

set -euo pipefail

# Localiza la libreria comun relativa a este script.
WD_ALERTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
. "${WD_ALERTS_DIR}/common.sh"

WD_NOTIFIERS_DIR="${WD_ROOT}/notifiers"

# ---------------------------------------------------------------------------
# Parametros configurables (con valores por defecto sensatos).
# ---------------------------------------------------------------------------
# Maximo de notificaciones globales por hora (proteccion anti-inundacion).
WD_RATE_MAX_HOUR="$(wd_conf_get WD_RATE_MAX_HOUR 20)"
# Lecturas WARNING consecutivas de la misma metrica antes de escalar a CRITICAL.
WD_ESCALATE_AFTER="$(wd_conf_get WD_ESCALATE_AFTER 3)"
# 'true' agrupa todas las alertas de la ejecucion en un unico mensaje digest.
WD_DIGEST="$(wd_conf_get WD_DIGEST true)"

# Sanea enteros.
case "${WD_RATE_MAX_HOUR}" in ''|*[!0-9]*) WD_RATE_MAX_HOUR=20 ;; esac
case "${WD_ESCALATE_AFTER}" in ''|*[!0-9]*) WD_ESCALATE_AFTER=3 ;; esac

# ---------------------------------------------------------------------------
# Extrae el valor de un campo string del JSON-ish de wd_emit. Parser ligero
# (no usa jq): busca "campo":"valor" respetando escapes basicos \" y \\.
# ---------------------------------------------------------------------------
_wd_json_field() {
    local line="$1" field="$2"
    printf '%s' "$line" | sed -n "s/.*\"${field}\":\"\\(\\([^\"\\\\]\\|\\\\.\\)*\\)\".*/\\1/p" | head -n 1
}

# Des-escapa \" y \\ que introdujo wd_emit.
_wd_json_unescape() {
    printf '%s' "$1" | sed 's/\\"/"/g; s/\\\\/\\/g'
}

# ---------------------------------------------------------------------------
# Rate-limit global por ventana de 1 hora. Devuelve 0 si hay cupo (y consume
# una unidad), 1 si se ha agotado. Estado fiable: SELECT contador+marca, luego
# INSERT (set) inmediato para cerrar la carrera dentro de la misma ejecucion.
# ---------------------------------------------------------------------------
_wd_rate_allow() {
    local now win_start count
    now="$(date +%s)"
    win_start="$(wd_state_get rate_window_start 0)"
    count="$(wd_state_get rate_window_count 0)"
    case "$win_start" in ''|*[!0-9]*) win_start=0 ;; esac
    case "$count" in ''|*[!0-9]*) count=0 ;; esac

    # Si la ventana de una hora ha expirado, reinicia el contador.
    if [ $(( now - win_start )) -ge 3600 ]; then
        win_start="$now"
        count=0
        wd_state_set rate_window_start "$win_start"
    fi

    if [ "$count" -ge "$WD_RATE_MAX_HOUR" ]; then
        wd_log "WARN" "Rate-limit global alcanzado (${count}/${WD_RATE_MAX_HOUR} por hora); se silencian envios."
        return 1
    fi

    count=$(( count + 1 ))
    wd_state_set rate_window_count "$count"
    return 0
}

# ---------------------------------------------------------------------------
# Escalado WARNING -> CRITICAL. Recibe metric y severidad entrante. Lleva un
# contador por metrica en state/. Devuelve por stdout la severidad efectiva.
# Limpia el contador cuando la severidad baja a INFO (recuperacion).
# ---------------------------------------------------------------------------
_wd_escalate() {
    local metric="$1" severity="$2"
    local key="escalate_${metric}" cnt
    cnt="$(wd_state_get "$key" 0)"
    case "$cnt" in ''|*[!0-9]*) cnt=0 ;; esac

    case "$severity" in
        WARNING)
            cnt=$(( cnt + 1 ))
            wd_state_set "$key" "$cnt"
            if [ "$cnt" -ge "$WD_ESCALATE_AFTER" ]; then
                printf 'CRITICAL'
            else
                printf 'WARNING'
            fi
            ;;
        CRITICAL)
            wd_state_set "$key" "$WD_ESCALATE_AFTER"
            printf 'CRITICAL'
            ;;
        *)
            # INFO/OK: resetea el contador de persistencia.
            [ "$cnt" -ne 0 ] && wd_state_set "$key" "0"
            printf '%s' "$severity"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Despacha una alerta a TODOS los canales activos. RESPETA el kill switch.
# Argumentos: SEVERIDAD TITULO CUERPO.
# ---------------------------------------------------------------------------
wd_dispatch() {
    local severity="$1" title="$2" body="$3"

    # KILL SWITCH: ningun envio sale del sistema.
    if wd_kill_switch_active; then
        wd_log "WARN" "KILL_SWITCH activo: alerta NO enviada -> [${severity}] ${title}"
        return 0
    fi

    # Rate-limit global.
    if ! _wd_rate_allow; then
        return 0
    fi

    local sent=0 ch enabled script
    for ch in email telegram webhook slack discord; do
        case "$ch" in
            email)    enabled="$(wd_conf_get WD_CHANNEL_EMAIL false)" ;;
            telegram) enabled="$(wd_conf_get WD_CHANNEL_TELEGRAM false)" ;;
            webhook)  enabled="$(wd_conf_get WD_CHANNEL_WEBHOOK false)" ;;
            slack)    enabled="$(wd_conf_get WD_CHANNEL_SLACK false)" ;;
            discord)  enabled="$(wd_conf_get WD_CHANNEL_DISCORD false)" ;;
        esac
        [ "$enabled" = "true" ] || continue
        script="${WD_NOTIFIERS_DIR}/${ch}.sh"
        if [ ! -f "$script" ]; then
            wd_log "ERROR" "Notificador no encontrado: ${script}"
            continue
        fi
        wd_log "INFO" "Enviando alerta por ${ch}: [${severity}] ${title}"
        # Aisla fallos de un canal para no romper el resto. set -e no aborta
        # porque el comando va dentro de un 'if'; capturamos el codigo real.
        local rc=0
        WD_ROOT="$WD_ROOT" WD_CONF="$WD_CONF" bash "$script" "$severity" "$title" "$body" || rc=$?
        if [ "$rc" -eq 0 ]; then
            sent=$(( sent + 1 ))
        else
            wd_log "ERROR" "Fallo el envio por ${ch} (codigo ${rc})"
        fi
    done

    if [ "$sent" -eq 0 ]; then
        wd_log "WARN" "Ningun canal activo entrego la alerta: [${severity}] ${title}"
    fi
}

# ---------------------------------------------------------------------------
# Procesa la entrada (NDJSON de wd_emit) y construye la lista de alertas a
# notificar tras aplicar escalado + ventana anti-duplicado + RESUELTO.
# Acumula en buffers para el digest.
# ---------------------------------------------------------------------------
DIGEST_BODY=""
DIGEST_COUNT=0
DIGEST_MAX_SEV="INFO"

# Orden de severidad para calcular el maximo del digest.
_wd_sev_rank() {
    case "$1" in
        CRITICAL) printf '3' ;;
        WARNING)  printf '2' ;;
        INFO)     printf '1' ;;
        *)        printf '0' ;;
    esac
}

# ---------------------------------------------------------------------------
# Seccion critica atomica para la ventana anti-duplicado.
# El contrato de wd_should_notify es READ-CHECK-WRITE (lee timestamp, evalua
# la ventana, escribe el nuevo timestamp). Esas tres operaciones NO son
# atomicas entre procesos: dos ciclos de cron concurrentes pueden leer ambos
# el timestamp viejo, pasar la comprobacion y notificar los dos, violando la
# ventana anti-duplicado. Para cerrar la carrera serializamos por clave la
# secuencia "marcar alerta abierta + wd_should_notify" mediante un lock por
# clave. Usa flock(1) si esta disponible; si no (Alpine/BSD/contenedores
# minimos), recurre a un lock por mkdir (operacion atomica POSIX).
#
# _wd_notify_atomic NOTIFY_KEY RESOLVED_KEY EFF_SEV
# Devuelve 0 si procede notificar (y deja registrada la marca/timestamp),
# 1 si se silencia por la ventana. NUNCA enmascara un fallo como "notificar":
# ante cualquier error del propio lock se opta por el lado seguro de no
# duplicar (se silencia) salvo que la ventana lo permita realmente.
# ---------------------------------------------------------------------------
_wd_notify_critical() {
    local notify_key="$1" resolved_key="$2" eff_sev="$3"
    # Marca la condicion como abierta y consulta la ventana de forma serializada.
    wd_state_set "$resolved_key" "1"
    if wd_should_notify "$notify_key" "$eff_sev"; then
        return 0
    fi
    return 1
}

_wd_notify_atomic() {
    local notify_key="$1" resolved_key="$2" eff_sev="$3"
    local lock_file rc

    # Nombre de lock saneado y derivado de la clave (nunca interpolar la clave
    # cruda en rutas). Reutiliza el mismo saneo que el resto del estado.
    local lock_name
    lock_name="$(printf 'notify_%s.lock' "$notify_key" | tr -c 'A-Za-z0-9._-' '_')"
    lock_file="${WD_STATE_DIR}/${lock_name}"

    if command -v flock >/dev/null 2>&1; then
        # flock disponible: seccion critica con descriptor dedicado (fd 8).
        # El subshell garantiza que el fd se cierra (y el lock se libera) al
        # salir, incluso ante error. set -e no aborta porque el bloque va en
        # un 'if' que captura el codigo real.
        rc=0
        (
            flock 8 || exit 2
            if _wd_notify_critical "$notify_key" "$resolved_key" "$eff_sev"; then
                exit 0
            fi
            exit 1
        ) 8>"$lock_file" || rc=$?
        case "$rc" in
            0) return 0 ;;
            1) return 1 ;;
            *)
                wd_log "ERROR" "Fallo el lock flock de la ventana anti-duplicado (${notify_key}); se silencia por seguridad."
                return 1
                ;;
        esac
    fi

    # Fallback portatil sin flock: lock por mkdir (atomico). Si no se obtiene
    # el lock, otro ciclo concurrente ya esta gestionando esta clave: se
    # silencia para no duplicar (lado seguro de la ventana anti-duplicado).
    local lock_dir="${lock_file}.d"
    if ! mkdir "$lock_dir" 2>/dev/null; then
        wd_log "DEBUG" "Lock por mkdir ocupado (${notify_key}); se silencia para evitar duplicado."
        return 1
    fi
    # Asegura la liberacion del lock pase lo que pase dentro de la seccion.
    rc=0
    if _wd_notify_critical "$notify_key" "$resolved_key" "$eff_sev"; then
        rc=0
    else
        rc=1
    fi
    rmdir "$lock_dir" 2>/dev/null || true
    return "$rc"
}

_wd_buffer_or_send() {
    local severity="$1" title="$2" body="$3"
    if [ "$WD_DIGEST" = "true" ]; then
        DIGEST_BODY="${DIGEST_BODY}- [${severity}] ${title}
  ${body}
"
        DIGEST_COUNT=$(( DIGEST_COUNT + 1 ))
        if [ "$(_wd_sev_rank "$severity")" -gt "$(_wd_sev_rank "$DIGEST_MAX_SEV")" ]; then
            DIGEST_MAX_SEV="$severity"
        fi
    else
        wd_dispatch "$severity" "$title" "$body"
    fi
}

wd_alerts_process() {
    local line raw_sev metric msg check eff_sev notify_key resolved_key prev_open
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        # Solo procesa lineas que parezcan JSON-ish de wd_emit.
        case "$line" in *'"severity"'*) ;; *) continue ;; esac

        raw_sev="$(_wd_json_field "$line" severity)"
        metric="$(_wd_json_unescape "$(_wd_json_field "$line" metric)")"
        msg="$(_wd_json_unescape "$(_wd_json_field "$line" msg)")"
        check="$(_wd_json_field "$line" check)"
        [ -z "$metric" ] && metric="${check:-unknown}"

        # Escalado segun persistencia.
        eff_sev="$(_wd_escalate "$metric" "$raw_sev")"

        # Clave estable de la condicion (independiente del valor concreto).
        notify_key="$(printf '%s' "${check}_${metric%%=*}" | tr -c 'A-Za-z0-9._-' '_')"
        resolved_key="resolved_open_${notify_key}"

        if [ "$eff_sev" = "INFO" ]; then
            # Posible recuperacion: solo emite RESUELTO si habia una alerta abierta.
            prev_open="$(wd_state_get "$resolved_key" 0)"
            if [ "$prev_open" = "1" ]; then
                wd_state_set "$resolved_key" "0"
                # El RESUELTO no se silencia por ventana: el operador debe saberlo.
                wd_log "INFO" "Condicion resuelta: ${check} / ${metric}"
                _wd_buffer_or_send "RESUELTO" "${check}: condicion normalizada" "${msg}"
            else
                wd_log "DEBUG" "INFO sin alerta previa abierta (${check}/${metric}); ignorado."
            fi
            continue
        fi

        # WARNING / CRITICAL: marca alerta abierta y aplica la ventana
        # anti-duplicado de forma ATOMICA (lock por clave). Esto serializa el
        # read-check-write de wd_should_notify entre ciclos de cron concurrentes
        # y evita que dos procesos pasen ambos la comprobacion y dupliquen.
        if _wd_notify_atomic "$notify_key" "$resolved_key" "$eff_sev"; then
            _wd_buffer_or_send "$eff_sev" "${check}: ${metric}" "${msg}"
        else
            wd_log "DEBUG" "Silenciado por ventana anti-duplicado: ${notify_key} (${eff_sev})"
        fi
    done

    # Envia el digest agrupado si procede.
    if [ "$WD_DIGEST" = "true" ] && [ "$DIGEST_COUNT" -gt 0 ]; then
        local title="Watchdog: ${DIGEST_COUNT} alerta(s) en $(hostname 2>/dev/null || echo host)"
        wd_dispatch "$DIGEST_MAX_SEV" "$title" "$DIGEST_BODY"
    fi
}

# Si se ejecuta directamente (no se hace 'source'), procesa stdin.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    wd_alerts_process
fi
