#!/bin/bash
# sync.sh - Re-sincronizacion produccion -> staging (HestiaCP).
# Vuelve a traer ficheros (rsync incremental) y/o BBDD desde produccion hacia el
# entorno staging existente. SIEMPRE hace un backup del staging ANTES de
# sobreescribirlo (rollback local del propio staging) y re-aplica la reescritura
# de URLs/credenciales serialize-safe tras importar. Registra la fecha del sync.
#
# IMPORTANTE: este flujo escribe SOLO sobre el staging, nunca sobre produccion.
# El sentido produccion->staging es seguro; el inverso (push-to-live) vive en
# push_live.sh con kill switch + backup + confirmacion.
#
# Uso:
#   sync.sh <source_domain> [--files-only|--db-only] [--exclude-uploads]
# Sourceable: stg_sync <source_domain> [opciones]

if [ -z "${STG_ROOT:-}" ] || ! declare -F stg_log >/dev/null 2>&1; then
    _sy_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
    # shellcheck source=/dev/null
    . "$_sy_dir/common.sh"
fi
# Reescritura serialize-safe (Fase 8). Se carga si existe.
if ! declare -F stg_rewrite_env >/dev/null 2>&1; then
    _sy_dir="${_sy_dir:-$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)}"
    if [ -f "$_sy_dir/rewrite.sh" ]; then
        # shellcheck source=/dev/null
        . "$_sy_dir/rewrite.sh"
    fi
fi

# ---------------------------------------------------------------------------
# _stg_rsync_excludes_args -> imprime los --exclude derivados de conf.
# include_uploads=0 -> anade tambien STG_UPLOADS_EXCLUDE.
# ---------------------------------------------------------------------------
_stg_rsync_excludes_args() {
    local include_uploads="$1"
    local raw extra pat
    raw="$(stg_conf_get STG_RSYNC_EXCLUDES '')"
    if [ "$include_uploads" = "0" ]; then
        extra="$(stg_conf_get STG_UPLOADS_EXCLUDE '')"
        [ -n "$extra" ] && raw="${raw}|${extra}"
    fi
    IFS='|' read -ra _pats <<< "$raw"
    for pat in "${_pats[@]}"; do
        pat="$(printf '%s' "$pat" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        [ -n "$pat" ] && printf -- '--exclude=%s\n' "$pat"
    done
}

# ---------------------------------------------------------------------------
# stg_backup_staging SOURCE_DOMAIN STG_USER -> backup del propio staging antes
# de sobreescribir. Usa v-backup-user si el staging vive en su propio usuario;
# en caso de mismo usuario, hace un tar del docroot + dumps. Registra ruta/fecha
# como STG_SELF_BACKUP_* en los metadatos.
# ---------------------------------------------------------------------------
stg_backup_staging() {
    local source_domain="$1"; local stg_user="$2"; local stg_docroot="$3"
    local bdir="$STG_STATE_DIR/backups"
    mkdir -p "$bdir" 2>/dev/null || true
    local ts stamp tarball
    ts="$(date +%s)"
    stamp="$(date '+%Y%m%d-%H%M%S')"
    tarball="$bdir/staging-$(printf '%s' "$source_domain" | tr -c 'A-Za-z0-9._-' '_')-$stamp.tar.gz"
    stg_log "INFO" "Backup del staging antes de sincronizar -> $tarball"
    if [ -d "$stg_docroot" ]; then
        if tar -czf "$tarball" -C "$stg_docroot" . 2>/dev/null; then
            stg_register_env "$source_domain" STG_SELF_BACKUP_PATH "$tarball"
            stg_register_env "$source_domain" STG_SELF_BACKUP_AT "$ts"
            stg_log "INFO" "Backup del staging completado."
        else
            stg_log "WARN" "No se pudo crear el tarball del staging (continuo bajo riesgo)."
        fi
    else
        stg_log "WARN" "Docroot del staging inexistente ($stg_docroot); sin backup previo."
    fi
    return 0
}

# ---------------------------------------------------------------------------
# _stg_min_src_files -> numero minimo de ficheros que el docroot origen debe
# contener para considerarlo valido antes de un rsync --delete. Configurable via
# STG_SYNC_MIN_SRC_FILES (default 5). Salvaguarda anti-catastrofe: evita que un
# origen vacio/mal configurado borre TODO el staging.
# ---------------------------------------------------------------------------
_stg_min_src_files() {
    local n
    n="$(stg_conf_get STG_SYNC_MIN_SRC_FILES '5')"
    case "$n" in
        ''|*[!0-9]*) n=5 ;;
    esac
    printf '%s' "$n"
}

# ---------------------------------------------------------------------------
# stg_sync_files SRC_DOCROOT DST_DOCROOT INCLUDE_UPLOADS
# rsync incremental con borrado de obsoletos (--delete) respetando exclusiones.
#
# SEGURIDAD: rsync -a --delete escribe sobre el staging (dst) y ELIMINA en dst
# todo lo que no exista en src. Si src estuviese vacio o mal apuntado, borraria
# el staging entero. Por eso, antes de aplicar --delete, validamos:
#   - src existe, es un directorio real y NO coincide con dst (mismo inode).
#   - src contiene un minimo de ficheros (anti origen vacio).
# Si alguna comprobacion falla, abortamos con stg_die SIN ejecutar el borrado.
# ---------------------------------------------------------------------------
stg_sync_files() {
    local src="$1"; local dst="$2"; local include_uploads="$3"
    command -v rsync >/dev/null 2>&1 || stg_die "rsync no disponible; no se pueden sincronizar ficheros."
    [ -n "$src" ] || stg_die "stg_sync_files: docroot origen vacio."
    [ -n "$dst" ] || stg_die "stg_sync_files: docroot destino vacio."
    [ -d "$src" ] || stg_die "Docroot origen inexistente: $src"

    # Salvaguarda: src y dst no pueden ser el mismo directorio (evita auto-borrado
    # y rsync sin sentido). Comparamos por ruta canonica.
    local src_real dst_real
    src_real="$(cd -P "$src" >/dev/null 2>&1 && pwd)" || src_real="$src"
    mkdir -p "$dst" 2>/dev/null || true
    dst_real="$(cd -P "$dst" >/dev/null 2>&1 && pwd)" || dst_real="$dst"
    if [ -n "$src_real" ] && [ "$src_real" = "$dst_real" ]; then
        stg_die "Origen y destino del rsync coinciden ($src_real); abortado para no borrar el staging."
    fi

    # Salvaguarda anti-catastrofe: el origen debe contener un minimo de ficheros.
    # Un origen vacio/mal apuntado con --delete arrasaria el staging completo.
    local min_files src_count
    min_files="$(_stg_min_src_files)"
    src_count="$(find "$src" -mindepth 1 \( -type f -o -type l \) -printf '.' 2>/dev/null | wc -c)"
    case "$src_count" in
        ''|*[!0-9]*) src_count=0 ;;
    esac
    if [ "$src_count" -lt "$min_files" ]; then
        stg_die "Docroot origen sospechosamente vacio ($src_count ficheros < minimo $min_files): $src. Abortado para no borrar el staging con --delete."
    fi

    local -a excludes
    mapfile -t excludes < <(_stg_rsync_excludes_args "$include_uploads")
    stg_log "INFO" "Sincronizando ficheros (rsync incremental) $src/ -> $dst/ (uploads=$include_uploads, src_files=$src_count)."
    if rsync -a --delete "${excludes[@]}" "$src"/ "$dst"/ >/dev/null 2>&1; then
        stg_log "INFO" "Sincronizacion de ficheros completada."
    else
        stg_die "Fallo rsync al sincronizar ficheros hacia el staging."
    fi
    return 0
}

# ---------------------------------------------------------------------------
# stg_sync_db SOURCE_DOMAIN -> re-importa las BBDD de produccion en las del
# staging. Dump del origen (v-dump-database) -> import en la BD staging.
# Las parejas src_db|stg_db se leen del metadato STG_DB_MAP (origen:destino;...).
# ---------------------------------------------------------------------------
stg_sync_db() {
    local source_domain="$1"
    local map src_user
    map="$(stg_get_env "$source_domain" STG_DB_MAP '')"
    src_user="$(stg_get_env "$source_domain" SOURCE_USER '')"
    if [ -z "$map" ]; then
        stg_log "WARN" "Sin mapa de BBDD (STG_DB_MAP) para '$source_domain'; omito sync de BBDD."
        return 0
    fi
    local stg_user
    stg_user="$(stg_get_env "$source_domain" STG_USER '')"
    local tmpdir
    tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/stg-dbsync.XXXXXX")"
    local pair src_db dst_db dump_file
    IFS=';' read -ra _pairs <<< "$map"
    for pair in "${_pairs[@]}"; do
        [ -n "$pair" ] || continue
        src_db="${pair%%:*}"
        dst_db="${pair##*:}"
        [ -n "$src_db" ] && [ -n "$dst_db" ] || continue
        dump_file="$tmpdir/$src_db.sql"
        stg_log "INFO" "Volcando BBDD produccion '$src_db' -> import en staging '$dst_db'."
        # v-dump-database <user> <database> [output] ; algunas versiones escriben
        # a stdout. Soportamos ambas formas.
        if stg_vcmd v-dump-database "$src_user" "$src_db" "$dump_file" >/dev/null 2>&1 && [ -s "$dump_file" ]; then
            :
        else
            stg_vcmd v-dump-database "$src_user" "$src_db" > "$dump_file" 2>/dev/null || true
        fi
        if [ ! -s "$dump_file" ]; then
            stg_log "WARN" "Dump vacio para '$src_db'; omito import de '$dst_db'."
            continue
        fi
        if stg_vcmd v-import-database "$stg_user" "$dst_db" "$dump_file" >/dev/null 2>&1; then
            stg_log "INFO" "BBDD '$dst_db' importada en staging."
        else
            stg_log "WARN" "v-import-database fallo para '$dst_db'; intento via mysql directo."
            mysql "$dst_db" < "$dump_file" >/dev/null 2>&1 || \
                stg_log "ERROR" "No se pudo importar '$dst_db'."
        fi
    done
    rm -rf "$tmpdir" 2>/dev/null || true
    return 0
}

# ---------------------------------------------------------------------------
# stg_sync SOURCE_DOMAIN [--files-only|--db-only] [--exclude-uploads]
# Orquesta el re-sync. Backup del staging -> ficheros y/o BBDD -> reescritura
# serialize-safe -> registro de fecha.
# ---------------------------------------------------------------------------
stg_sync() {
    local source_domain="$1"; shift || true
    [ -n "$source_domain" ] || stg_die "stg_sync: dominio origen vacio"

    local do_files=1 do_db=1 include_uploads=1
    while [ $# -gt 0 ]; do
        case "$1" in
            --files-only) do_db=0; shift ;;
            --db-only) do_files=0; shift ;;
            --exclude-uploads) include_uploads=0; shift ;;
            *) stg_log "WARN" "Argumento desconocido en sync: $1"; shift ;;
        esac
    done

    # Metadatos del entorno staging y del origen.
    local stg_domain stg_user stg_docroot src_docroot
    stg_domain="$(stg_get_env "$source_domain" STG_DOMAIN '')"
    stg_user="$(stg_get_env "$source_domain" STG_USER '')"
    stg_docroot="$(stg_get_env "$source_domain" STG_DOCROOT '')"
    src_docroot="$(stg_get_env "$source_domain" SOURCE_DOCROOT '')"
    [ -n "$stg_domain" ] || stg_die "No hay entorno staging para '$source_domain'. Crealo antes (v-staging-create)."
    [ -n "$stg_user" ] || stg_die "Falta STG_USER en metadatos de '$source_domain'."
    [ -n "$stg_docroot" ] || stg_docroot="/home/$stg_user/web/$stg_domain/public_html"
    if [ -z "$src_docroot" ]; then
        local src_user
        src_user="$(stg_get_env "$source_domain" SOURCE_USER '')"
        [ -n "$src_user" ] && src_docroot="/home/$src_user/web/$source_domain/public_html"
    fi

    stg_log "INFO" "Re-sync staging '$stg_domain' <- produccion '$source_domain' (files=$do_files db=$do_db uploads=$include_uploads)."

    # 1) Backup del staging antes de sobreescribir (rollback local).
    stg_backup_staging "$source_domain" "$stg_user" "$stg_docroot"

    # 2) Ficheros.
    if [ "$do_files" -eq 1 ]; then
        [ -n "$src_docroot" ] || stg_die "No se conoce el docroot de produccion para '$source_domain'."
        stg_sync_files "$src_docroot" "$stg_docroot" "$include_uploads"
    fi

    # 3) BBDD.
    if [ "$do_db" -eq 1 ]; then
        stg_sync_db "$source_domain"
    fi

    # 4) Reescritura serialize-safe (URLs/credenciales produccion -> staging).
    if declare -F stg_rewrite_env >/dev/null 2>&1; then
        stg_log "INFO" "Re-aplicando reescritura serialize-safe en el staging."
        stg_rewrite_env "$source_domain" 'to-staging' || stg_log "WARN" "La reescritura devolvio error; revisa el log."
    else
        stg_log "WARN" "Modulo de reescritura (rewrite.sh) no disponible; omito reescritura. Revisa URLs/credenciales del staging manualmente."
    fi

    # 5) Registro de fecha.
    stg_register_env "$source_domain" STG_LAST_SYNC_AT "$(date +%s)"
    stg_log "INFO" "Re-sync completado para staging '$stg_domain'."
    return 0
}

# Ejecucion directa.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    set -euo pipefail
    [ $# -ge 1 ] || stg_die "Uso: sync.sh <source_domain> [--files-only|--db-only] [--exclude-uploads]"
    stg_sync "$@"
fi
