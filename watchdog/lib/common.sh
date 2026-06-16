#!/bin/bash
# common.sh - Libreria nucleo del plugin Watchdog para HestiaCP.
# Define variables y funciones del contrato usadas por todos los bloques.
# Implementacion real: parser KEY='VALUE', logging con rotacion, estado en
# ficheros y ventana anti-duplicado fiable (SELECT+INSERT sobre state/).

# ---------------------------------------------------------------------------
# Resolucion de rutas. WD_ROOT apunta a la raiz del plugin (un nivel sobre lib/).
# ---------------------------------------------------------------------------
if [ -z "${WD_ROOT:-}" ]; then
    _wd_src="${BASH_SOURCE[0]}"
    # Resuelve symlinks para localizar la raiz real del plugin.
    while [ -h "$_wd_src" ]; do
        _wd_dir="$(cd -P "$(dirname "$_wd_src")" >/dev/null 2>&1 && pwd)"
        _wd_src="$(readlink "$_wd_src")"
        [[ "$_wd_src" != /* ]] && _wd_src="$_wd_dir/$_wd_src"
    done
    _wd_lib_dir="$(cd -P "$(dirname "$_wd_src")" >/dev/null 2>&1 && pwd)"
    WD_ROOT="$(cd -P "$_wd_lib_dir/.." >/dev/null 2>&1 && pwd)"
fi

# Rutas base del contrato.
WD_CONF="${WD_CONF:-$WD_ROOT/conf/watchdog.conf}"
WD_STATE_DIR="${WD_STATE_DIR:-$WD_ROOT/state}"
WD_LOG_DIR="${WD_LOG_DIR:-$WD_ROOT/logs}"
WD_LOG_FILE="$WD_LOG_DIR/watchdog.log"

# Tamano maximo del log antes de rotar (bytes). 2 MB por defecto.
WD_LOG_MAX_BYTES="${WD_LOG_MAX_BYTES:-2097152}"
# Numero de ficheros rotados a conservar.
WD_LOG_KEEP="${WD_LOG_KEEP:-5}"

# Asegura la existencia de los directorios de trabajo.
[ -d "$WD_STATE_DIR" ] || mkdir -p "$WD_STATE_DIR" 2>/dev/null || true
[ -d "$WD_LOG_DIR" ] || mkdir -p "$WD_LOG_DIR" 2>/dev/null || true

# ---------------------------------------------------------------------------
# wd_conf_get KEY [default]
# Lee KEY del fichero de configuracion (formato KEY='VALUE'). Si no existe,
# devuelve el valor por defecto (cadena vacia si no se indica).
# ---------------------------------------------------------------------------
wd_conf_get() {
    local key="$1"
    local def="${2:-}"
    if [ ! -f "$WD_CONF" ]; then
        printf '%s' "$def"
        return 0
    fi
    local line
    # Ultima coincidencia gana; ignora comentarios y espacios iniciales.
    line="$(grep -E "^[[:space:]]*${key}=" "$WD_CONF" 2>/dev/null | grep -v '^[[:space:]]*#' | tail -n 1)"
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
# wd_conf_set KEY VALUE
# Escribe/actualiza KEY en el fichero de configuracion (formato KEY='VALUE').
# Escritura atomica via fichero temporal.
# ---------------------------------------------------------------------------
wd_conf_set() {
    local key="$1"
    local value="$2"
    local tmp
    [ -d "$(dirname "$WD_CONF")" ] || mkdir -p "$(dirname "$WD_CONF")"
    [ -f "$WD_CONF" ] || : > "$WD_CONF"
    tmp="$(mktemp "${WD_CONF}.XXXXXX")"

    # Sanea el valor: el formato es de una sola linea, por lo que cualquier
    # salto de linea (CR/LF) se sustituye por un espacio para no romper el
    # fichero. Las comillas simples se neutralizan reemplazandolas por su
    # equivalente seguro ('\'') de forma que el valor entrecomillado siga
    # siendo una unica linea valida KEY='VALUE'.
    local safe_value
    safe_value="$(printf '%s' "$value" | tr '\r\n' '  ')"
    safe_value="${safe_value//\'/\'\\\'\'}"

    # Construye la linea de salida una sola vez, sin interpolar el valor en
    # codigo awk/sed (evita corrupcion por metacaracteres o saltos de linea).
    local new_line="${key}='${safe_value}'"

    if grep -qE "^[[:space:]]*${key}=" "$WD_CONF" 2>/dev/null; then
        # Reemplaza la primera linea no comentada que define la clave. El
        # valor se pasa a awk como variable de DATOS (no de codigo) y se
        # imprime literalmente, evitando cualquier reinterpretacion.
        awk -v k="$key" -v repl="$new_line" '
            BEGIN { done=0 }
            {
                if (!done && $0 ~ "^[[:space:]]*" k "=" && $0 !~ "^[[:space:]]*#") {
                    print repl
                    done=1
                } else {
                    print $0
                }
            }
        ' "$WD_CONF" > "$tmp"
    else
        cp "$WD_CONF" "$tmp"
        printf '%s\n' "$new_line" >> "$tmp"
    fi
    mv -f "$tmp" "$WD_CONF"
    chmod 600 "$WD_CONF" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Rotacion de log por tamano. Interno.
# ---------------------------------------------------------------------------
_wd_log_rotate() {
    [ -f "$WD_LOG_FILE" ] || return 0
    local size
    size="$(wc -c < "$WD_LOG_FILE" 2>/dev/null || echo 0)"
    [ "$size" -lt "$WD_LOG_MAX_BYTES" ] && return 0
    # Desplaza los ficheros rotados existentes.
    local i
    for ((i=WD_LOG_KEEP-1; i>=1; i--)); do
        if [ -f "$WD_LOG_FILE.$i" ]; then
            mv -f "$WD_LOG_FILE.$i" "$WD_LOG_FILE.$((i+1))" 2>/dev/null || true
        fi
    done
    mv -f "$WD_LOG_FILE" "$WD_LOG_FILE.1" 2>/dev/null || true
    : > "$WD_LOG_FILE"
    chmod 640 "$WD_LOG_FILE" 2>/dev/null || true
    # Elimina rotados sobrantes.
    if [ -f "$WD_LOG_FILE.$((WD_LOG_KEEP+1))" ]; then
        rm -f "$WD_LOG_FILE.$((WD_LOG_KEEP+1))" 2>/dev/null || true
    fi
}

# ---------------------------------------------------------------------------
# wd_log LEVEL MSG
# Escribe una linea con timestamp en logs/watchdog.log. DEBUG solo se registra
# si DEBUG='true' en conf. Niveles: DEBUG, INFO, WARN, ERROR.
# ---------------------------------------------------------------------------
wd_log() {
    local level="$1"; shift
    local msg="$*"
    # Filtra DEBUG si la depuracion esta desactivada.
    if [ "$level" = "DEBUG" ]; then
        local dbg
        dbg="$(wd_conf_get DEBUG false)"
        [ "$dbg" = "true" ] || return 0
    fi
    [ -d "$WD_LOG_DIR" ] || mkdir -p "$WD_LOG_DIR" 2>/dev/null || true
    _wd_log_rotate
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    printf '%s [%s] %s\n' "$ts" "$level" "$msg" >> "$WD_LOG_FILE"
}

# ---------------------------------------------------------------------------
# Helper: convierte una KEY en nombre de fichero de estado seguro.
# ---------------------------------------------------------------------------
_wd_state_file() {
    local key="$1"
    # Sustituye caracteres no alfanumericos por guion bajo.
    local safe
    safe="$(printf '%s' "$key" | tr -c 'A-Za-z0-9._-' '_')"
    printf '%s/%s' "$WD_STATE_DIR" "$safe"
}

# ---------------------------------------------------------------------------
# wd_state_get KEY [default]
# Lee el valor almacenado en state/<KEY>. Devuelve default si no existe.
# ---------------------------------------------------------------------------
wd_state_get() {
    local key="$1"
    local def="${2:-}"
    local f
    f="$(_wd_state_file "$key")"
    if [ -f "$f" ]; then
        cat "$f"
    else
        printf '%s' "$def"
    fi
}

# ---------------------------------------------------------------------------
# wd_state_set KEY VALUE
# Escribe VALUE en state/<KEY> de forma atomica.
# ---------------------------------------------------------------------------
wd_state_set() {
    local key="$1"
    local value="$2"
    local f tmp
    f="$(_wd_state_file "$key")"
    [ -d "$WD_STATE_DIR" ] || mkdir -p "$WD_STATE_DIR"
    tmp="$(mktemp "${f}.XXXXXX")"
    printf '%s' "$value" > "$tmp"
    mv -f "$tmp" "$f"
}

# ---------------------------------------------------------------------------
# wd_emit CHECK SEVERITY METRIC MSG
# Un check reporta un resultado. Imprime una linea JSON-ish a stdout y deja
# constancia en el log. SEVERITY: INFO, WARNING, CRITICAL.
# ---------------------------------------------------------------------------
wd_emit() {
    local check="$1"
    local severity="$2"
    local metric="$3"
    shift 3
    local msg="$*"
    local ts
    ts="$(date '+%Y-%m-%dT%H:%M:%S%z')"
    # Escapa comillas dobles y barras invertidas en TODOS los campos de texto
    # que se insertan en el JSON. Aunque check/severity suelen ser constantes,
    # se sanitizan igual para garantizar JSON valido si alguna vez reciben
    # valores dinamicos (sanitizacion consistente).
    local e_msg e_metric e_check e_severity
    e_msg="$(printf '%s' "$msg" | sed 's/\\/\\\\/g; s/"/\\"/g')"
    e_metric="$(printf '%s' "$metric" | sed 's/\\/\\\\/g; s/"/\\"/g')"
    e_check="$(printf '%s' "$check" | sed 's/\\/\\\\/g; s/"/\\"/g')"
    e_severity="$(printf '%s' "$severity" | sed 's/\\/\\\\/g; s/"/\\"/g')"
    printf '{"ts":"%s","check":"%s","severity":"%s","metric":"%s","msg":"%s"}\n' \
        "$ts" "$e_check" "$e_severity" "$e_metric" "$e_msg"
    wd_log "$severity" "[$check] $metric :: $msg"
}

# ---------------------------------------------------------------------------
# wd_should_notify KEY SEVERITY
# Ventana anti-duplicado fiable. Devuelve 0 (notificar) o 1 (silenciar).
# Patron SELECT+INSERT: lee el timestamp del ultimo aviso en state/notify_<KEY>
# y solo autoriza si han pasado >= WD_NOTIFY_WINDOW minutos. Al autorizar,
# actualiza el timestamp inmediatamente para evitar carreras dentro de la
# misma ejecucion. Severidad CRITICAL nunca se silencia mas alla de la ventana.
# ---------------------------------------------------------------------------
wd_should_notify() {
    local key="$1"
    local severity="${2:-INFO}"
    local window_min
    window_min="$(wd_conf_get WD_NOTIFY_WINDOW 30)"
    # Sanea a entero; valor 0 desactiva la ventana (siempre notifica).
    case "$window_min" in
        ''|*[!0-9]*) window_min=30 ;;
    esac
    local state_key="notify_${key}"
    local now last delta window_sec
    now="$(date +%s)"
    window_sec=$(( window_min * 60 ))

    # SELECT: lee el ultimo aviso registrado.
    last="$(wd_state_get "$state_key" 0)"
    case "$last" in
        ''|*[!0-9]*) last=0 ;;
    esac

    if [ "$window_sec" -le 0 ]; then
        # Ventana desactivada: notificar siempre y registrar.
        wd_state_set "$state_key" "$now"
        wd_log "DEBUG" "wd_should_notify($key,$severity): ventana=0, notificar"
        return 0
    fi

    delta=$(( now - last ))
    if [ "$delta" -ge "$window_sec" ]; then
        # INSERT: registra el aviso de inmediato (cierra la ventana).
        wd_state_set "$state_key" "$now"
        wd_log "DEBUG" "wd_should_notify($key,$severity): delta=${delta}s >= ${window_sec}s, notificar"
        return 0
    fi

    wd_log "DEBUG" "wd_should_notify($key,$severity): delta=${delta}s < ${window_sec}s, silenciar"
    return 1
}

# ---------------------------------------------------------------------------
# KILL SWITCH global. Se carga desde conf. Por defecto activado ('true') segun
# regla anti-catastrofe: ninguna accion hacia terceros se ejecuta hasta que el
# operador lo desactive conscientemente.
# ---------------------------------------------------------------------------
WD_KILL_SWITCH="$(wd_conf_get WD_KILL_SWITCH true)"

# Funcion de conveniencia: 0 si el kill switch esta activo (cortar envios).
wd_kill_switch_active() {
    [ "$WD_KILL_SWITCH" = "true" ]
}
