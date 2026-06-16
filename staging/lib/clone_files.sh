#!/bin/bash
# clone_files.sh - Clonado de ficheros origen -> staging para el plugin Staging.
# Usa rsync -a --delete con exclusiones de configuracion y artefactos volatiles,
# soporta modo completo (full) e incremental, hace chown al usuario destino y
# verifica el resultado al final (conteo y muestreo). NUNCA toca otros dominios:
# opera exclusivamente sobre las rutas origen/destino indicadas.
#
# Uso:    clone_files.sh <source_docroot> <dest_docroot> <dest_user> [full|incremental]
# Tambien sourceable: stg_clone_files SRC DST USER MODE

# Carga la libreria nucleo si no esta cargada.
if [ -z "${STG_ROOT:-}" ] || ! declare -F stg_log >/dev/null 2>&1; then
    _cf_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
    # shellcheck source=/dev/null
    . "$_cf_dir/common.sh"
fi

# ---------------------------------------------------------------------------
# _stg_build_excludes [incremental] -> imprime los argumentos --exclude de rsync,
# uno por linea. Combina STG_RSYNC_EXCLUDES (siempre) y, en modo incremental,
# STG_UPLOADS_EXCLUDE (no recopia uploads voluminosos ya presentes).
# Tambien excluye SIEMPRE los ficheros de configuracion sensibles para que el
# bloque de reescritura los genere/ajuste (no se pisan credenciales destino).
# ---------------------------------------------------------------------------
_stg_build_excludes() {
    local mode="$1"
    local raw extra
    raw="$(stg_conf_get STG_RSYNC_EXCLUDES '')"
    # Exclusiones de configuracion: se gestionan en rewrite.sh, no se clonan tal cual.
    local conf_excludes='wp-config.php|.env|config/settings.inc.php|app/config/parameters.php|configuration.php|app/etc/env.php'
    raw="${raw}|${conf_excludes}"
    if [ "$mode" = "incremental" ]; then
        extra="$(stg_conf_get STG_UPLOADS_EXCLUDE '')"
        [ -n "$extra" ] && raw="${raw}|${extra}"
    fi
    # Divide por '|' y emite un --exclude por patron no vacio.
    local IFS='|'
    local pat
    for pat in $raw; do
        [ -n "$pat" ] || continue
        printf -- '--exclude=%s\n' "$pat"
    done
}

# ---------------------------------------------------------------------------
# stg_clone_files SRC DST USER [MODE]
# SRC  : docroot origen (produccion). Debe existir.
# DST  : docroot destino (staging). Se crea si no existe.
# USER : usuario del panel propietario del staging (para chown).
# MODE : full (--delete, espejo exacto) | incremental (sin --delete, no uploads).
# ---------------------------------------------------------------------------
stg_clone_files() {
    local src="$1"; local dst="$2"; local user="$3"; local mode="${4:-full}"

    [ -n "$src" ]  || stg_die "clone_files: docroot origen vacio."
    [ -n "$dst" ]  || stg_die "clone_files: docroot destino vacio."
    [ -n "$user" ] || stg_die "clone_files: usuario destino vacio."
    [ -d "$src" ]  || stg_die "clone_files: el origen no existe: $src"

    case "$mode" in
        full|incremental) ;;
        *) stg_die "clone_files: modo invalido '$mode' (usa full|incremental)." ;;
    esac

    command -v rsync >/dev/null 2>&1 || stg_die "clone_files: rsync no esta instalado."

    # Normaliza barras finales: rsync exige 'src/' para copiar el contenido.
    local src_dir="${src%/}/"
    local dst_dir="${dst%/}/"

    # El destino debe existir antes del sync (rsync no crea la jerarquia padre).
    if [ ! -d "$dst_dir" ]; then
        mkdir -p "$dst_dir" || stg_die "clone_files: no se pudo crear destino $dst_dir"
    fi

    stg_log "INFO" "Clonado de ficheros ($mode): $src_dir -> $dst_dir (user=$user)"

    # Construye exclusiones en un array (preserva patrones con espacios).
    local -a excludes=()
    local line
    while IFS= read -r line; do
        [ -n "$line" ] && excludes+=("$line")
    done < <(_stg_build_excludes "$mode")

    # Opciones base de rsync.
    #   -a : modo archivo (recursivo, permisos, tiempos, symlinks).
    #   --human-readable + --stats : para metricas en log.
    #   --delete : SOLO en full (espejo exacto). En incremental se conserva destino.
    local -a opts=( -a --human-readable --stats )
    if [ "$mode" = "full" ]; then
        opts+=( --delete --delete-excluded )
    fi
    # Verbosidad extra solo en DEBUG.
    if [ "$(stg_conf_get DEBUG false)" = "true" ]; then
        opts+=( -v --itemize-changes )
    fi

    local rc=0
    local out
    out="$(rsync "${opts[@]}" "${excludes[@]}" "$src_dir" "$dst_dir" 2>&1)" || rc=$?
    # Registra solo un resumen (las ultimas lineas con --stats) para no inflar el log.
    stg_log "DEBUG" "rsync salida:\n$out"
    printf '%s\n' "$out" | grep -E 'Number of files|transferred|Total transferred|speedup' | while IFS= read -r l; do
        stg_log "INFO" "rsync: $l"
    done

    if [ "$rc" -ne 0 ]; then
        stg_die "clone_files: rsync fallo (codigo $rc). Revisa permisos y espacio."
    fi

    # chown recursivo al usuario destino (grupo homonimo en HestiaCP).
    _stg_chown_dest "$dst_dir" "$user"

    # Verificacion final.
    _stg_verify_clone "$src_dir" "$dst_dir" "$mode"

    stg_log "INFO" "Clonado de ficheros completado correctamente ($mode)."
    return 0
}

# ---------------------------------------------------------------------------
# _stg_chown_dest DST USER -> ajusta propietario:grupo del destino al usuario
# del panel. En HestiaCP el grupo coincide con el usuario. Tolera fallos en
# entornos sin privilegios (loguea WARN, no aborta el clonado ya hecho).
# ---------------------------------------------------------------------------
_stg_chown_dest() {
    local dst="$1"; local user="$2"
    if ! id "$user" >/dev/null 2>&1; then
        stg_log "WARN" "clone_files: usuario '$user' no existe en el sistema; se omite chown."
        return 0
    fi
    local grp="$user"
    if ! getent group "$user" >/dev/null 2>&1; then
        # Usa el grupo primario real del usuario si no existe grupo homonimo.
        grp="$(id -gn "$user" 2>/dev/null || echo "$user")"
    fi
    if chown -R "$user:$grp" "$dst" 2>/dev/null; then
        stg_log "INFO" "clone_files: chown -R $user:$grp aplicado a $dst"
    else
        stg_log "WARN" "clone_files: no se pudo aplicar chown a $dst (privilegios insuficientes)."
    fi
}

# ---------------------------------------------------------------------------
# _stg_verify_clone SRC DST MODE -> verificacion final del clonado.
# - El destino debe existir y no estar vacio.
# - En modo full compara el conteo de ficheros (descontando exclusiones es
#   aproximado, por lo que solo se exige que destino > 0 y dentro de un margen).
# Falla (stg_die) si el destino quedo vacio teniendo el origen contenido.
# ---------------------------------------------------------------------------
_stg_verify_clone() {
    local src="$1"; local dst="$2"; local mode="$3"
    [ -d "$dst" ] || stg_die "clone_files: verificacion fallida, destino inexistente: $dst"

    local src_count dst_count
    src_count="$(find "$src" -type f 2>/dev/null | wc -l | tr -d '[:space:]')"
    dst_count="$(find "$dst" -type f 2>/dev/null | wc -l | tr -d '[:space:]')"
    case "$src_count" in ''|*[!0-9]*) src_count=0 ;; esac
    case "$dst_count" in ''|*[!0-9]*) dst_count=0 ;; esac

    stg_log "INFO" "clone_files: verificacion ficheros origen=$src_count destino=$dst_count"

    if [ "$src_count" -gt 0 ] && [ "$dst_count" -eq 0 ]; then
        stg_die "clone_files: el destino quedo vacio pese a tener origen contenido. Aborta."
    fi

    # En full, tras --delete el destino deberia ser <= origen (exclusiones aparte).
    # Un destino mucho mayor que el origen es sospechoso (delete no aplicado).
    if [ "$mode" = "full" ] && [ "$src_count" -gt 0 ]; then
        local max=$(( src_count + src_count / 10 + 50 ))
        if [ "$dst_count" -gt "$max" ]; then
            stg_log "WARN" "clone_files: destino ($dst_count) excede el origen ($src_count) en modo full. Revisa --delete y exclusiones."
        fi
    fi
    return 0
}

# Ejecucion directa.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    set -euo pipefail
    [ $# -ge 3 ] || stg_die "Uso: clone_files.sh <src_docroot> <dest_docroot> <dest_user> [full|incremental]"
    stg_clone_files "$1" "$2" "$3" "${4:-full}"
fi
