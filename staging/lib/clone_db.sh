#!/bin/bash
# clone_db.sh - Clonado de bases de datos origen -> staging para el plugin Staging.
# Por cada BBDD del dominio indicado: dump (v-dump-database o mysqldump/pg_dump) ->
# crea BBDD destino con prefijo propio (respetando el limite de longitud de
# HestiaCP) -> importa (v-import-database o cliente nativo). Soporta BBDD grandes
# (compresion gzip y carga por lotes) y verifica integridad por conteo de tablas.
#
# REGLA CRITICA: opera EXCLUSIVAMENTE sobre las BBDD del dominio recibido (lista
# explicita). NUNCA hace un barrido de todas las BBDD del servidor.
#
# Uso:    clone_db.sh <dest_user> <dbspec> [<dbspec> ...]
#   dbspec = engine|dbname|dbuser|dbhost  (formato emitido por detect_source.sh)
# Tambien sourceable: stg_clone_db DEST_USER "engine|db|user|host" ...

if [ -z "${STG_ROOT:-}" ] || ! declare -F stg_log >/dev/null 2>&1; then
    _cd_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
    # shellcheck source=/dev/null
    . "$_cd_dir/common.sh"
fi

# Limite de longitud de identificadores en HestiaCP/MySQL. HestiaCP antepone
# '<usuario>_' al nombre que se pasa a v-add-database, y MySQL limita a 64 chars.
# Se reserva margen para el prefijo del panel + el prefijo de staging.
STG_DB_NAME_MAXLEN="${STG_DB_NAME_MAXLEN:-32}"

# Umbral (bytes) a partir del cual se considera "grande" y se activa compresion.
STG_DB_LARGE_BYTES="${STG_DB_LARGE_BYTES:-104857600}"  # 100 MB

# ---------------------------------------------------------------------------
# _stg_stg_dbname SRC_DBNAME -> nombre de la BBDD de staging (con prefijo,
# truncado al limite). Determinista para una misma entrada.
# ---------------------------------------------------------------------------
_stg_stg_dbname() {
    local src="$1"
    local prefix
    prefix="$(stg_conf_get STG_DB_PREFIX 'stg_')"
    local name="${prefix}${src}"
    # Trunca preservando los ultimos caracteres (mas distintivos) si excede.
    if [ "${#name}" -gt "$STG_DB_NAME_MAXLEN" ]; then
        local keep=$(( STG_DB_NAME_MAXLEN - ${#prefix} ))
        [ "$keep" -lt 1 ] && keep=1
        # Conserva una porcion del nombre + hash corto para evitar colisiones.
        local hash
        hash="$(printf '%s' "$src" | cksum | awk '{print $1}' | tail -c 5)"
        local trunc="${src:0:$(( keep - 5 ))}"
        name="${prefix}${trunc}${hash}"
        name="${name:0:$STG_DB_NAME_MAXLEN}"
    fi
    printf '%s' "$name"
}

# ---------------------------------------------------------------------------
# _stg_stg_dbuser SRC_DBUSER -> usuario de BBDD de staging (con prefijo, truncado).
# ---------------------------------------------------------------------------
_stg_stg_dbuser() {
    local src="$1"
    local prefix
    prefix="$(stg_conf_get STG_DBUSER_PREFIX 'stg_')"
    local name="${prefix}${src}"
    if [ "${#name}" -gt "$STG_DB_NAME_MAXLEN" ]; then
        name="${name:0:$STG_DB_NAME_MAXLEN}"
    fi
    printf '%s' "$name"
}

# ---------------------------------------------------------------------------
# _stg_gen_password -> genera una contrasena aleatoria robusta para la BBDD stg.
# ---------------------------------------------------------------------------
_stg_gen_password() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 20
    else
        head -c 64 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 20
    fi
}

# ---------------------------------------------------------------------------
# _stg_dump_mysql DBNAME DBUSER DBHOST OUTFILE [gzip]
# Dump de una BBDD MySQL. Prefiere v-dump-database; si no existe usa mysqldump
# con las credenciales del panel (~/.my.cnf de root) o socket por defecto.
# ---------------------------------------------------------------------------
_stg_dump_mysql() {
    local db="$1"; local user="$2"; local host="$3"; local out="$4"; local compress="${5:-}"
    local rc=0

    # Opcion 1: v-dump-database <user_panel> <database>. Algunas versiones aceptan
    # solo el nombre completo de BBDD. Se intenta de forma tolerante.
    if [ -x "$STG_VBIN/v-dump-database" ]; then
        if "$STG_VBIN/v-dump-database" "$db" > "$out".tmp 2>/dev/null && [ -s "$out".tmp ]; then
            mv -f "$out".tmp "$out"
        else
            rm -f "$out".tmp 2>/dev/null || true
            rc=1
        fi
    else
        rc=1
    fi

    # Opcion 2: mysqldump nativo (fallback robusto). --single-transaction para
    # consistencia sin bloquear, --routines/--triggers para esquema completo.
    if [ "$rc" -ne 0 ] || [ ! -s "$out" ]; then
        command -v mysqldump >/dev/null 2>&1 || { stg_log "ERROR" "clone_db: mysqldump no disponible para '$db'."; return 1; }
        local -a my=( --single-transaction --quick --routines --triggers --events --default-character-set=utf8mb4 )
        [ -n "$host" ] && [ "$host" != "localhost" ] && my+=( -h "$host" )
        if mysqldump "${my[@]}" "$db" > "$out" 2>/dev/null && [ -s "$out" ]; then
            rc=0
        else
            stg_log "ERROR" "clone_db: mysqldump fallo para '$db'."
            return 1
        fi
    fi

    if [ "$compress" = "gzip" ]; then
        gzip -f "$out" && stg_log "DEBUG" "clone_db: dump comprimido $out.gz"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# _stg_dump_pgsql DBNAME DBUSER DBHOST OUTFILE [gzip]
# Dump de una BBDD PostgreSQL con pg_dump (formato plano para importar via psql).
# ---------------------------------------------------------------------------
_stg_dump_pgsql() {
    local db="$1"; local user="$2"; local host="$3"; local out="$4"; local compress="${5:-}"
    command -v pg_dump >/dev/null 2>&1 || { stg_log "ERROR" "clone_db: pg_dump no disponible para '$db'."; return 1; }
    local -a pg=( --no-owner --no-privileges --clean --if-exists )
    [ -n "$host" ] && pg+=( -h "$host" )
    [ -n "$user" ] && pg+=( -U "$user" )
    if PGPASSWORD="${PGPASSWORD:-}" pg_dump "${pg[@]}" "$db" > "$out" 2>/dev/null && [ -s "$out" ]; then
        [ "$compress" = "gzip" ] && gzip -f "$out"
        return 0
    fi
    stg_log "ERROR" "clone_db: pg_dump fallo para '$db'."
    return 1
}

# ---------------------------------------------------------------------------
# _stg_import_mysql STG_DB DUMPFILE -> importa el dump en la BBDD de staging.
# Soporta .sql y .sql.gz. Prefiere v-import-database; fallback a mysql nativo.
# ---------------------------------------------------------------------------
_stg_import_mysql() {
    local user_panel="$1"; local stg_db="$2"; local dump="$3"
    local rc=0

    # v-import-database <user_panel> <database> <dumpfile>. No soporta gz: si
    # esta comprimido se descomprime a un temporal previo.
    local feed="$dump"
    local tmp_unz=""
    if [ "${dump##*.}" = "gz" ]; then
        tmp_unz="${dump%.gz}.import.$$"
        gunzip -c "$dump" > "$tmp_unz" || { stg_log "ERROR" "clone_db: no se pudo descomprimir $dump"; return 1; }
        feed="$tmp_unz"
    fi

    if [ -x "$STG_VBIN/v-import-database" ]; then
        if "$STG_VBIN/v-import-database" "$user_panel" "$stg_db" "$feed" >/dev/null 2>&1; then
            [ -n "$tmp_unz" ] && rm -f "$tmp_unz" 2>/dev/null || true
            return 0
        fi
        stg_log "WARN" "clone_db: v-import-database fallo para '$stg_db', se intenta cliente nativo."
    fi

    # Fallback: mysql nativo. El nombre real en HestiaCP es '<panel>_<stg_db>'.
    command -v mysql >/dev/null 2>&1 || { stg_log "ERROR" "clone_db: mysql no disponible."; [ -n "$tmp_unz" ] && rm -f "$tmp_unz"; return 1; }
    local real_db="${user_panel}_${stg_db}"
    if mysql --default-character-set=utf8mb4 "$real_db" < "$feed" 2>/dev/null; then
        rc=0
    else
        stg_log "ERROR" "clone_db: importacion nativa fallo en '$real_db'."
        rc=1
    fi
    [ -n "$tmp_unz" ] && rm -f "$tmp_unz" 2>/dev/null || true
    return $rc
}

# ---------------------------------------------------------------------------
# _stg_mysql_lit_esc VALUE -> escapa un valor para usarlo DENTRO de comillas
# simples en una sentencia MySQL. Escapa la barra invertida y la comilla simple
# (en ese orden) para impedir inyeccion al interpolar el valor en un literal.
# ---------------------------------------------------------------------------
_stg_mysql_lit_esc() {
    local v="$1"
    v="${v//\\/\\\\}"   # \  -> \\  (primero)
    v="${v//\'/\\\'}"   # '  -> \'
    printf '%s' "$v"
}

# ---------------------------------------------------------------------------
# _stg_table_count_mysql REAL_DB -> numero de tablas (verificacion integridad).
# ---------------------------------------------------------------------------
_stg_table_count_mysql() {
    local db="$1"
    command -v mysql >/dev/null 2>&1 || { printf '0'; return 0; }
    local esc
    esc="$(_stg_mysql_lit_esc "$db")"
    mysql -N -B -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${esc}'" 2>/dev/null | head -n 1 | tr -d '[:space:]'
}

# ---------------------------------------------------------------------------
# _stg_dump_table_count FILE -> cuenta sentencias CREATE TABLE en el dump
# (sirve para comparar origen vs destino sin acceso directo al motor origen).
# ---------------------------------------------------------------------------
_stg_dump_table_count() {
    local f="$1"
    [ -f "$f" ] || { printf '0'; return 0; }
    if [ "${f##*.}" = "gz" ]; then
        gunzip -c "$f" 2>/dev/null | grep -ciE '^[[:space:]]*CREATE TABLE'
    else
        grep -ciE '^[[:space:]]*CREATE TABLE' "$f"
    fi
}

# ---------------------------------------------------------------------------
# stg_clone_db DEST_USER DBSPEC [DBSPEC ...]
# Clona cada BBDD listada. Devuelve por stdout, una por linea, el mapeo:
#   engine|src_db|stg_db_short|real_stg_db|stg_dbuser|stg_dbpass
# para que rewrite.sh pueda reescribir credenciales. NO loguea contrasenas.
# ---------------------------------------------------------------------------
stg_clone_db() {
    local user_panel="$1"; shift
    [ -n "$user_panel" ] || stg_die "clone_db: usuario destino vacio."
    [ $# -ge 1 ] || { stg_log "INFO" "clone_db: no hay BBDD que clonar para '$user_panel'."; return 0; }

    local work_dir="$STG_STATE_DIR/dumps/$user_panel"
    mkdir -p "$work_dir" || stg_die "clone_db: no se pudo crear $work_dir"
    chmod 700 "$work_dir" 2>/dev/null || true

    local spec engine src_db src_user src_host
    local errors=0
    for spec in "$@"; do
        [ -n "$spec" ] || continue
        IFS='|' read -r engine src_db src_user src_host <<< "$spec"
        engine="${engine:-mysql}"
        [ -n "$src_db" ] || { stg_log "WARN" "clone_db: spec sin nombre de BBDD ('$spec'), se omite."; continue; }
        src_host="${src_host:-localhost}"

        stg_log "INFO" "clone_db: procesando origen '$src_db' (engine=$engine)."

        # Decide compresion segun tamano estimado del dump (dump en seco no es
        # posible, asi que se basa en el tamano de los datos del motor si MySQL).
        local compress=""
        local est_bytes=0
        if [ "$engine" = "mysql" ] && command -v mysql >/dev/null 2>&1; then
            local _src_db_esc
            _src_db_esc="$(_stg_mysql_lit_esc "$src_db")"
            est_bytes="$(mysql -N -B -e "SELECT COALESCE(SUM(data_length+index_length),0) FROM information_schema.tables WHERE table_schema='${_src_db_esc}'" 2>/dev/null | head -n 1 | tr -d '[:space:]')"
            case "$est_bytes" in ''|*[!0-9]*) est_bytes=0 ;; esac
        fi
        if [ "$est_bytes" -ge "$STG_DB_LARGE_BYTES" ]; then
            compress="gzip"
            stg_log "INFO" "clone_db: '$src_db' es grande (~$(numfmt --to=iec "$est_bytes" 2>/dev/null || echo "$est_bytes")), se comprime el dump."
        fi

        local dump="$work_dir/${src_db}.sql"
        local ok=0
        case "$engine" in
            mysql)
                _stg_dump_mysql "$src_db" "$src_user" "$src_host" "$dump" "$compress" && ok=1 ;;
            pgsql)
                _stg_dump_pgsql "$src_db" "$src_user" "$src_host" "$dump" "$compress" && ok=1 ;;
            *)
                stg_log "WARN" "clone_db: engine no soportado '$engine' para '$src_db', se omite." ;;
        esac
        if [ "$ok" -ne 1 ]; then
            errors=$(( errors + 1 ))
            continue
        fi
        [ "$compress" = "gzip" ] && dump="${dump}.gz"

        # Anti-catastrofe: un dump "exitoso" pero vacio o sin tablas dejaria un
        # staging silenciosamente vacio. Se valida ANTES de crear/importar la
        # BBDD destino. Si el origen reporto datos (est_bytes>0) pero el dump no
        # contiene tablas, es un fallo real (no se enmascara como OK).
        if [ ! -s "$dump" ]; then
            stg_log "ERROR" "clone_db: dump vacio para '$src_db' ($dump); se omite."
            errors=$(( errors + 1 ))
            continue
        fi
        local want
        want="$(_stg_dump_table_count "$dump")"
        case "$want" in ''|*[!0-9]*) want=0 ;; esac
        if [ "$want" -lt 1 ]; then
            if [ "$est_bytes" -gt 0 ]; then
                stg_log "ERROR" "clone_db: dump de '$src_db' sin tablas (CREATE TABLE=0) pese a tener datos (~$est_bytes bytes); posible dump corrupto. Se omite."
                errors=$(( errors + 1 ))
                continue
            fi
            stg_log "WARN" "clone_db: dump de '$src_db' no contiene tablas; se continua (origen aparentemente sin datos)."
        fi

        # Nombres y credenciales del staging.
        local stg_db stg_dbuser stg_dbpass
        stg_db="$(_stg_stg_dbname "$src_db")"
        stg_dbuser="$(_stg_stg_dbuser "${src_user:-$src_db}")"
        stg_dbpass="$(_stg_gen_password)"

        # Crea la BBDD destino via HestiaCP (gestiona prefijo de panel y grants).
        # v-add-database USER DATABASE DBUSER DBPASS [TYPE] [CHARSET] [HOST]
        if [ -x "$STG_VBIN/v-add-database" ]; then
            local hestia_type='mysql'
            [ "$engine" = "pgsql" ] && hestia_type='pgsql'
            if ! "$STG_VBIN/v-add-database" "$user_panel" "$stg_db" "$stg_dbuser" "$stg_dbpass" "$hestia_type" 2>/dev/null; then
                stg_log "WARN" "clone_db: v-add-database pudo fallar para '$stg_db' (quiza ya exista). Se continua con la importacion."
            fi
        else
            stg_log "WARN" "clone_db: v-add-database no disponible; se asume BBDD '${user_panel}_${stg_db}' pre-creada."
        fi

        # Importa.
        local imported=0
        case "$engine" in
            mysql) _stg_import_mysql "$user_panel" "$stg_db" "$dump" && imported=1 ;;
            pgsql) stg_log "WARN" "clone_db: importacion pgsql nativa no implementada en este bloque; usar v-import-database." ;;
        esac
        if [ "$imported" -ne 1 ]; then
            errors=$(( errors + 1 ))
            stg_log "ERROR" "clone_db: importacion fallida para '$src_db' -> '$stg_db'."
            continue
        fi

        # Verificacion de integridad: conteo de tablas dump vs BBDD destino.
        # ($want ya se calculo y valido antes de importar.)
        local real_db="${user_panel}_${stg_db}"
        local got
        got="$(_stg_table_count_mysql "$real_db")"
        case "$got" in ''|*[!0-9]*) got=0 ;; esac
        if [ "$want" -gt 0 ] && [ "$got" -lt "$want" ]; then
            stg_log "ERROR" "clone_db: integridad '$real_db' tablas esperadas=$want importadas=$got."
            errors=$(( errors + 1 ))
        else
            stg_log "INFO" "clone_db: integridad OK '$real_db' (tablas=$got, esperadas=$want)."
        fi

        # Registra el mapeo como metadato del entorno (sin contrasena en log).
        stg_register_env "$user_panel" "DB_MAP_${src_db}" "${engine}|${stg_db}|${real_db}|${stg_dbuser}"
        stg_log "DEBUG" "clone_db: '$src_db' -> '$real_db' (user=$stg_dbuser) listo."

        # Emite el mapeo por stdout para el consumidor (rewrite.sh).
        printf '%s|%s|%s|%s|%s|%s\n' "$engine" "$src_db" "$stg_db" "$real_db" "$stg_dbuser" "$stg_dbpass"
    done

    if [ "$errors" -gt 0 ]; then
        stg_die "clone_db: finalizado con $errors error(es). Revisa logs/staging.log."
    fi
    stg_log "INFO" "clone_db: clonado de BBDD completado para '$user_panel'."
    return 0
}

# Ejecucion directa.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    set -euo pipefail
    [ $# -ge 2 ] || stg_die "Uso: clone_db.sh <dest_user> <engine|db|user|host> [...]"
    stg_clone_db "$@"
fi
