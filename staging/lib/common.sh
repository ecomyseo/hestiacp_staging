#!/bin/bash
# common.sh - Libreria nucleo del plugin Staging para HestiaCP.
# Implementa el contrato compartido por todos los bloques: variables STG_*,
# logging con rotacion, lectura/escritura de configuracion (KEY='VALUE'),
# registro de metadatos por entorno staging, salvaguardas de backup/confirmacion
# y kill switch del push-to-live activado por defecto (regla anti-catastrofe).

# ---------------------------------------------------------------------------
# Resolucion de rutas. STG_ROOT apunta a la raiz del plugin (un nivel sobre lib/).
# Resuelve symlinks para localizar la raiz real aunque se invoque desde /usr/bin.
# ---------------------------------------------------------------------------
if [ -z "${STG_ROOT:-}" ]; then
    _stg_src="${BASH_SOURCE[0]}"
    while [ -h "$_stg_src" ]; do
        _stg_dir="$(cd -P "$(dirname "$_stg_src")" >/dev/null 2>&1 && pwd)"
        _stg_src="$(readlink "$_stg_src")"
        [[ "$_stg_src" != /* ]] && _stg_src="$_stg_dir/$_stg_src"
    done
    _stg_lib_dir="$(cd -P "$(dirname "$_stg_src")" >/dev/null 2>&1 && pwd)"
    STG_ROOT="$(cd -P "$_stg_lib_dir/.." >/dev/null 2>&1 && pwd)"
fi

# Rutas base del contrato.
STG_CONF="${STG_CONF:-$STG_ROOT/conf/staging.conf}"
STG_STATE_DIR="${STG_STATE_DIR:-$STG_ROOT/state}"
STG_LOG_DIR="${STG_LOG_DIR:-$STG_ROOT/logs}"
STG_LOG_FILE="$STG_LOG_DIR/staging.log"
# Log de auditoria separado para operaciones sensibles (push, delete, rollback).
STG_AUDIT_FILE="$STG_LOG_DIR/audit.log"
# Subdirectorio donde se guardan los metadatos de cada entorno staging.
STG_ENVS_DIR="$STG_STATE_DIR/envs"

# Rotacion de log: tamano maximo (bytes) y numero de ficheros a conservar.
STG_LOG_MAX_BYTES="${STG_LOG_MAX_BYTES:-2097152}"
STG_LOG_KEEP="${STG_LOG_KEEP:-5}"

# Ruta de los binarios de HestiaCP (para invocar comandos v-*).
HESTIA="${HESTIA:-/usr/local/hestia}"
STG_VBIN="${STG_VBIN:-$HESTIA/bin}"

# Asegura la existencia de los directorios de trabajo.
[ -d "$STG_STATE_DIR" ] || mkdir -p "$STG_STATE_DIR" 2>/dev/null || true
[ -d "$STG_ENVS_DIR" ] || mkdir -p "$STG_ENVS_DIR" 2>/dev/null || true
[ -d "$STG_LOG_DIR" ] || mkdir -p "$STG_LOG_DIR" 2>/dev/null || true

# ---------------------------------------------------------------------------
# stg_conf_get KEY [default]
# Lee KEY del fichero de configuracion (formato KEY='VALUE'). Ignora comentarios.
# Devuelve el valor por defecto si no existe la clave.
# ---------------------------------------------------------------------------
stg_conf_get() {
    local key="$1"
    local def="${2:-}"
    if [ ! -f "$STG_CONF" ]; then
        printf '%s' "$def"
        return 0
    fi
    local line
    line="$(grep -E "^[[:space:]]*${key}=" "$STG_CONF" 2>/dev/null | grep -v '^[[:space:]]*#' | tail -n 1)"
    if [ -z "$line" ]; then
        printf '%s' "$def"
        return 0
    fi
    local val="${line#*=}"
    # Elimina comillas simples o dobles envolventes.
    val="${val%\'}"; val="${val#\'}"
    val="${val%\"}"; val="${val#\"}"
    printf '%s' "$val"
}

# ---------------------------------------------------------------------------
# stg_conf_set KEY VALUE
# Escribe/actualiza KEY en la configuracion (formato KEY='VALUE'). Atomico.
# ---------------------------------------------------------------------------
stg_conf_set() {
    local key="$1"
    local value="$2"
    local tmp
    [ -d "$(dirname "$STG_CONF")" ] || mkdir -p "$(dirname "$STG_CONF")"
    [ -f "$STG_CONF" ] || : > "$STG_CONF"
    tmp="$(mktemp "${STG_CONF}.XXXXXX")"
    if grep -qE "^[[:space:]]*${key}=" "$STG_CONF" 2>/dev/null; then
        # Reemplaza la primera linea no comentada que define la clave.
        awk -v k="$key" -v v="$value" '
            BEGIN { done=0 }
            {
                if (!done && $0 ~ "^[[:space:]]*" k "=" && $0 !~ "^[[:space:]]*#") {
                    print k "=\x27" v "\x27"
                    done=1
                } else {
                    print $0
                }
            }
        ' "$STG_CONF" > "$tmp"
    else
        cp "$STG_CONF" "$tmp"
        printf "%s='%s'\n" "$key" "$value" >> "$tmp"
    fi
    mv -f "$tmp" "$STG_CONF"
    chmod 600 "$STG_CONF" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Rotacion de log por tamano. Interno. Acepta como argumento el fichero a rotar.
# ---------------------------------------------------------------------------
_stg_log_rotate() {
    local f="${1:-$STG_LOG_FILE}"
    [ -f "$f" ] || return 0
    local size
    size="$(wc -c < "$f" 2>/dev/null || echo 0)"
    [ "$size" -lt "$STG_LOG_MAX_BYTES" ] && return 0
    local i
    for ((i=STG_LOG_KEEP-1; i>=1; i--)); do
        if [ -f "$f.$i" ]; then
            mv -f "$f.$i" "$f.$((i+1))" 2>/dev/null || true
        fi
    done
    mv -f "$f" "$f.1" 2>/dev/null || true
    : > "$f"
    chmod 640 "$f" 2>/dev/null || true
    if [ -f "$f.$((STG_LOG_KEEP+1))" ]; then
        rm -f "$f.$((STG_LOG_KEEP+1))" 2>/dev/null || true
    fi
}

# ---------------------------------------------------------------------------
# stg_log LEVEL MSG
# Escribe una linea con timestamp en logs/staging.log. DEBUG solo si DEBUG='true'
# en conf. Niveles: DEBUG, INFO, WARN, ERROR.
# ---------------------------------------------------------------------------
stg_log() {
    local level="$1"; shift
    local msg="$*"
    if [ "$level" = "DEBUG" ]; then
        local dbg
        dbg="$(stg_conf_get DEBUG false)"
        [ "$dbg" = "true" ] || return 0
    fi
    [ -d "$STG_LOG_DIR" ] || mkdir -p "$STG_LOG_DIR" 2>/dev/null || true
    _stg_log_rotate "$STG_LOG_FILE"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    printf '%s [%s] %s\n' "$ts" "$level" "$msg" >> "$STG_LOG_FILE"
}

# ---------------------------------------------------------------------------
# stg_audit DOMAIN ACTION RESULT MSG
# Registro de auditoria para operaciones sensibles. Siempre se escribe.
# ---------------------------------------------------------------------------
stg_audit() {
    local domain="$1"; local action="$2"; local result="$3"; shift 3
    local msg="$*"
    [ -d "$STG_LOG_DIR" ] || mkdir -p "$STG_LOG_DIR" 2>/dev/null || true
    _stg_log_rotate "$STG_AUDIT_FILE"
    local ts user
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    user="${SUDO_USER:-${USER:-unknown}}"
    printf '%s [%s] domain=%s action=%s result=%s :: %s\n' \
        "$ts" "$user" "$domain" "$action" "$result" "$msg" >> "$STG_AUDIT_FILE"
    chmod 640 "$STG_AUDIT_FILE" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# stg_die MSG
# Registra ERROR y termina con codigo 1.
# ---------------------------------------------------------------------------
stg_die() {
    local msg="$*"
    stg_log "ERROR" "$msg"
    printf 'ERROR: %s\n' "$msg" >&2
    exit 1
}

# ---------------------------------------------------------------------------
# Helper: nombre de fichero seguro a partir de un dominio.
# ---------------------------------------------------------------------------
_stg_safe_name() {
    printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'
}

# ---------------------------------------------------------------------------
# stg_register_env DOMAIN KEY VALUE
# Guarda un metadato del entorno staging en state/envs/<DOMAIN>.conf.
# Usa el mismo formato KEY='VALUE'. Crea el fichero si no existe.
# ---------------------------------------------------------------------------
stg_register_env() {
    local domain="$1"; local key="$2"; local value="$3"
    [ -n "$domain" ] || { stg_log "ERROR" "stg_register_env: dominio vacio"; return 1; }
    [ -n "$key" ] || { stg_log "ERROR" "stg_register_env: clave vacia"; return 1; }
    local f tmp safe
    safe="$(_stg_safe_name "$domain")"
    f="$STG_ENVS_DIR/$safe.conf"
    [ -d "$STG_ENVS_DIR" ] || mkdir -p "$STG_ENVS_DIR"
    [ -f "$f" ] || : > "$f"
    tmp="$(mktemp "${f}.XXXXXX")"
    if grep -qE "^[[:space:]]*${key}=" "$f" 2>/dev/null; then
        awk -v k="$key" -v v="$value" '
            BEGIN { done=0 }
            {
                if (!done && $0 ~ "^[[:space:]]*" k "=" && $0 !~ "^[[:space:]]*#") {
                    print k "=\x27" v "\x27"
                    done=1
                } else {
                    print $0
                }
            }
        ' "$f" > "$tmp"
    else
        cp "$f" "$tmp"
        printf "%s='%s'\n" "$key" "$value" >> "$tmp"
    fi
    mv -f "$tmp" "$f"
    chmod 600 "$f" 2>/dev/null || true
    stg_log "DEBUG" "stg_register_env($domain): $key set"
}

# ---------------------------------------------------------------------------
# stg_get_env DOMAIN KEY [default]
# Lee un metadato del entorno staging. Devuelve default si no existe.
# ---------------------------------------------------------------------------
stg_get_env() {
    local domain="$1"; local key="$2"; local def="${3:-}"
    local f safe
    safe="$(_stg_safe_name "$domain")"
    f="$STG_ENVS_DIR/$safe.conf"
    if [ ! -f "$f" ]; then
        printf '%s' "$def"
        return 0
    fi
    local line
    line="$(grep -E "^[[:space:]]*${key}=" "$f" 2>/dev/null | grep -v '^[[:space:]]*#' | tail -n 1)"
    if [ -z "$line" ]; then
        printf '%s' "$def"
        return 0
    fi
    local val="${line#*=}"
    val="${val%\'}"; val="${val#\'}"
    val="${val%\"}"; val="${val#\"}"
    printf '%s' "$val"
}

# ---------------------------------------------------------------------------
# stg_require_backup_done DOMAIN
# Falla si no hay un backup live previo registrado para el dominio. La fecha
# del backup se guarda como metadato LIVE_BACKUP_AT (epoch). Se exige que sea
# reciente (< STG_BACKUP_TTL segundos, 24h por defecto) para que un backup
# antiguo no autorice una sobreescritura nueva.
# ---------------------------------------------------------------------------
stg_require_backup_done() {
    local domain="$1"
    [ -n "$domain" ] || stg_die "stg_require_backup_done: dominio vacio"
    local at path now ttl delta
    at="$(stg_get_env "$domain" LIVE_BACKUP_AT 0)"
    path="$(stg_get_env "$domain" LIVE_BACKUP_PATH '')"
    case "$at" in
        ''|*[!0-9]*) at=0 ;;
    esac
    if [ "$at" -le 0 ]; then
        stg_die "No hay backup live registrado para '$domain'. Ejecuta el backup antes de cualquier escritura sobre produccion."
    fi
    # El fichero de backup debe existir todavia.
    if [ -n "$path" ] && [ ! -e "$path" ]; then
        stg_die "El backup live registrado para '$domain' no se encuentra en disco ($path). Regeneralo."
    fi
    ttl="$(stg_conf_get STG_BACKUP_TTL 86400)"
    case "$ttl" in
        ''|*[!0-9]*) ttl=86400 ;;
    esac
    now="$(date +%s)"
    delta=$(( now - at ))
    if [ "$delta" -ge "$ttl" ]; then
        stg_die "El backup live de '$domain' tiene ${delta}s (>${ttl}s). Es demasiado antiguo: regenera el backup antes de continuar."
    fi
    stg_log "INFO" "Backup live verificado para '$domain' (edad ${delta}s, path=${path:-n/d})."
    return 0
}

# ---------------------------------------------------------------------------
# stg_confirm DOMAIN
# Exige confirmacion explicita para operaciones destructivas. El operador debe
# exportar STG_CONFIRM=<domain> con el nombre EXACTO del dominio. Evita el uso
# de prompts interactivos (compatible con ejecucion desde cron/UI/sudo).
# ---------------------------------------------------------------------------
stg_confirm() {
    local domain="$1"
    [ -n "$domain" ] || stg_die "stg_confirm: dominio vacio"
    if [ "${STG_CONFIRM:-}" != "$domain" ]; then
        stg_die "Confirmacion requerida. Exporta STG_CONFIRM='$domain' para autorizar la operacion sobre '$domain'."
    fi
    stg_log "INFO" "Confirmacion aceptada para '$domain'."
    return 0
}

# ---------------------------------------------------------------------------
# KILL SWITCH del push-to-live. Activado ('true') por defecto: bloquea cualquier
# operacion que sobrescriba produccion hasta que el operador lo desactive.
# ---------------------------------------------------------------------------
STG_PUSH_KILL_SWITCH="$(stg_conf_get STG_PUSH_KILL_SWITCH true)"

# stg_push_blocked / stg_is_push_blocked
# Semantica explicita: DEVUELVE 0 (exito en shell) CUANDO EL PUSH ESTA BLOQUEADO
# por el kill switch (STG_PUSH_KILL_SWITCH='true'). Devuelve 1 cuando NO esta
# bloqueado. El nombre puede parecer invertido respecto a un predicado normal,
# de ahi este comentario y el alias stg_is_push_blocked (recomendado en codigo
# nuevo). Se conserva stg_push_blocked por compatibilidad con los llamadores.
stg_is_push_blocked() {
    [ "$STG_PUSH_KILL_SWITCH" = "true" ]
}

# Alias historico. Mantiene el contrato: 0 = bloqueado, 1 = no bloqueado.
stg_push_blocked() {
    stg_is_push_blocked
}

# ---------------------------------------------------------------------------
# stg_vcmd CMD [args...]
# Invoca un comando v-* de HestiaCP de forma robusta (ruta absoluta). Devuelve
# el codigo de salida del comando. Registra el comando en modo DEBUG.
# ---------------------------------------------------------------------------
stg_vcmd() {
    local cmd="$1"; shift
    local bin="$STG_VBIN/$cmd"
    if [ ! -x "$bin" ]; then
        # Reintenta resolviendo por PATH (instalaciones no estandar).
        bin="$(command -v "$cmd" 2>/dev/null || true)"
    fi
    [ -n "$bin" ] && [ -x "$bin" ] || { stg_log "ERROR" "Comando HestiaCP no encontrado: $cmd"; return 127; }
    stg_log "DEBUG" "exec: $cmd $*"
    "$bin" "$@"
}
