#!/bin/bash
# push_live.sh - PUSH-TO-LIVE: promociona el staging a produccion (HestiaCP).
# OPERACION DESTRUCTIVA. Protegida por las tres salvaguardas obligatorias:
#   1) STG_PUSH_KILL_SWITCH: si 'true' (por defecto) aborta SIEMPRE.
#   2) stg_require_backup_done: exige backup live (v-backup-user) reciente ANTES
#      de escribir una sola linea en produccion.
#   3) stg_confirm: exige STG_CONFIRM=<source_domain> (doble verificacion).
#
# Estrategia:
#   - Ficheros: swap atomico. Se copia el docroot del staging a un directorio
#     paralelo en produccion (<docroot>.stgnew), se renombra el actual a
#     <docroot>.stgold y se mueve el nuevo a su sitio (rename = casi atomico).
#   - BBDD: import del dump del staging a una BD nueva en produccion y swap de
#     credenciales en el fichero de config del CMS (apuntar a la nueva BD).
#   - Reescritura inversa staging->produccion serialize-safe ANTES del swap de BD
#     (sobre el dump), de modo que la URL de produccion quede correcta.
#   - Si cualquier paso falla, rollback automatico (restaura .stgold y la BD).
#   - Auditoria completa en logs/audit.log.
#
# Uso:  STG_CONFIRM=<source_domain> push_live.sh <source_domain>
# Sourceable: stg_push_live <source_domain>

if [ -z "${STG_ROOT:-}" ] || ! declare -F stg_log >/dev/null 2>&1; then
    _pl_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
    # shellcheck source=/dev/null
    . "$_pl_dir/common.sh"
fi
_pl_dir="${_pl_dir:-$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)}"
# Reescritura inversa serialize-safe (Fase 8).
if ! declare -F stg_rewrite_dump >/dev/null 2>&1 && [ -f "$_pl_dir/rewrite.sh" ]; then
    # shellcheck source=/dev/null
    . "$_pl_dir/rewrite.sh"
fi
# rollback.sh aporta stg_rollback para el rollback automatico.
if ! declare -F stg_rollback >/dev/null 2>&1 && [ -f "$_pl_dir/rollback.sh" ]; then
    # shellcheck source=/dev/null
    . "$_pl_dir/rollback.sh"
fi

# Estado de progreso del push, para que el rollback sepa que deshacer.
STG_PUSH_FILES_SWAPPED=0
STG_PUSH_DOCROOT=''
STG_PUSH_OLDDIR=''
STG_PUSH_NEWDIR=''
STG_PUSH_DB_SWAPPED=0
STG_PUSH_DB_CFG=''
STG_PUSH_DB_CFG_BAK=''

# ---------------------------------------------------------------------------
# _stg_push_abort_rollback SOURCE_DOMAIN MSG
# Revierte lo aplicado en este push y termina con error. Deja produccion como
# estaba ANTES del push (no toca el backup live; ese es la red de seguridad ult.)
# ---------------------------------------------------------------------------
_stg_push_abort_rollback() {
    local source_domain="$1"; shift
    local msg="$*"
    stg_log "ERROR" "Push fallido: $msg. Iniciando rollback automatico."
    stg_audit "$source_domain" push fail "$msg :: rollback automatico"

    # Revertir swap de ficheros.
    if [ "$STG_PUSH_FILES_SWAPPED" -eq 1 ] && [ -n "$STG_PUSH_DOCROOT" ]; then
        if [ -d "$STG_PUSH_OLDDIR" ]; then
            rm -rf "$STG_PUSH_DOCROOT.stgfail" 2>/dev/null || true
            mv -f "$STG_PUSH_DOCROOT" "$STG_PUSH_DOCROOT.stgfail" 2>/dev/null || true
            if mv -f "$STG_PUSH_OLDDIR" "$STG_PUSH_DOCROOT" 2>/dev/null; then
                stg_log "INFO" "Ficheros restaurados desde $STG_PUSH_OLDDIR."
                rm -rf "$STG_PUSH_DOCROOT.stgfail" 2>/dev/null || true
            else
                stg_log "ERROR" "No se pudo restaurar ficheros automaticamente. Usa v-staging-rollback."
            fi
        fi
    fi

    # Revertir swap de credenciales de BD.
    if [ "$STG_PUSH_DB_SWAPPED" -eq 1 ] && [ -n "$STG_PUSH_DB_CFG" ] && [ -f "$STG_PUSH_DB_CFG_BAK" ]; then
        cp -f "$STG_PUSH_DB_CFG_BAK" "$STG_PUSH_DB_CFG" 2>/dev/null && \
            stg_log "INFO" "Credenciales de BD restauradas en $STG_PUSH_DB_CFG."
    fi

    # Como ultima red, intenta el rollback completo desde el backup live.
    if declare -F stg_rollback >/dev/null 2>&1; then
        stg_log "INFO" "Invocando rollback completo desde backup live por seguridad."
        STG_CONFIRM="$source_domain" stg_rollback "$source_domain" --auto || \
            stg_log "ERROR" "El rollback completo tambien fallo. Intervencion manual requerida."
    fi

    stg_die "Push abortado y revertido para '$source_domain'."
}

# ---------------------------------------------------------------------------
# stg_push_files SOURCE_DOMAIN -> swap atomico del docroot de produccion por el
# del staging. Guarda el docroot anterior como <docroot>.stgold (para rollback).
# ---------------------------------------------------------------------------
stg_push_files() {
    local source_domain="$1"
    local stg_user stg_domain stg_docroot src_user src_docroot
    stg_user="$(stg_get_env "$source_domain" STG_USER '')"
    stg_domain="$(stg_get_env "$source_domain" STG_DOMAIN '')"
    stg_docroot="$(stg_get_env "$source_domain" STG_DOCROOT '')"
    src_user="$(stg_get_env "$source_domain" SOURCE_USER '')"
    src_docroot="$(stg_get_env "$source_domain" SOURCE_DOCROOT '')"
    [ -n "$stg_docroot" ] || stg_docroot="/home/$stg_user/web/$stg_domain/public_html"
    [ -n "$src_docroot" ] || src_docroot="/home/$src_user/web/$source_domain/public_html"
    [ -d "$stg_docroot" ] || stg_die "Docroot del staging inexistente: $stg_docroot"
    [ -d "$src_docroot" ] || stg_die "Docroot de produccion inexistente: $src_docroot"

    command -v rsync >/dev/null 2>&1 || stg_die "rsync no disponible para preparar el swap."

    local newdir="$src_docroot.stgnew"
    local olddir="$src_docroot.stgold"
    rm -rf "$newdir" 2>/dev/null || true
    rm -rf "$olddir" 2>/dev/null || true

    stg_log "INFO" "Preparando copia del staging en produccion ($newdir)."
    # Copiamos el staging a un directorio paralelo SIN tocar todavia el live.
    if ! rsync -a --delete "$stg_docroot"/ "$newdir"/ >/dev/null 2>&1; then
        rm -rf "$newdir" 2>/dev/null || true
        stg_die "Fallo al copiar el staging al directorio de swap."
    fi

    # En produccion NO debe ir el robots.txt de bloqueo (noindex) del staging.
    if [ -f "$newdir/robots.txt" ] && grep -q 'Disallow: /' "$newdir/robots.txt" 2>/dev/null; then
        rm -f "$newdir/robots.txt" 2>/dev/null || true
    fi

    # Swap atomico: mueve el actual a .stgold y el nuevo a su sitio.
    STG_PUSH_DOCROOT="$src_docroot"
    STG_PUSH_OLDDIR="$olddir"
    STG_PUSH_NEWDIR="$newdir"
    stg_log "INFO" "Swap atomico de ficheros en produccion."
    if ! mv -f "$src_docroot" "$olddir" 2>/dev/null; then
        rm -rf "$newdir" 2>/dev/null || true
        stg_die "No se pudo apartar el docroot de produccion (permisos?)."
    fi
    if ! mv -f "$newdir" "$src_docroot" 2>/dev/null; then
        # Restaura inmediato.
        mv -f "$olddir" "$src_docroot" 2>/dev/null || true
        stg_die "No se pudo colocar el nuevo docroot; produccion restaurada."
    fi
    STG_PUSH_FILES_SWAPPED=1
    stg_register_env "$source_domain" PUSH_OLDDIR "$olddir"
    stg_log "INFO" "Swap de ficheros completado. Anterior conservado en $olddir."
    return 0
}

# ---------------------------------------------------------------------------
# stg_push_db SOURCE_DOMAIN -> dump del staging, reescritura inversa
# (staging->produccion) serialize-safe sobre el dump, import a una BD nueva en
# produccion y swap de credenciales en el fichero de config del CMS de prod.
# ---------------------------------------------------------------------------
stg_push_db() {
    local source_domain="$1"
    local map stg_user src_user src_docroot cms
    map="$(stg_get_env "$source_domain" STG_DB_MAP '')"
    stg_user="$(stg_get_env "$source_domain" STG_USER '')"
    src_user="$(stg_get_env "$source_domain" SOURCE_USER '')"
    src_docroot="$(stg_get_env "$source_domain" SOURCE_DOCROOT '')"
    cms="$(stg_get_env "$source_domain" SOURCE_CMS 'estatico')"
    if [ -z "$map" ] || [ "$cms" = "estatico" ]; then
        stg_log "INFO" "Sin BBDD que promover para '$source_domain' (cms=$cms)."
        return 0
    fi
    [ -n "$src_docroot" ] || src_docroot="/home/$src_user/web/$source_domain/public_html"

    local tmpdir
    tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/stg-push-db.XXXXXX")"

    # Procesamos la PRIMERA pareja del mapa como BD principal del CMS.
    local pair stg_db prod_db_old
    pair="${map%%;*}"
    # En el mapa origen:destino = produccion:staging. Para push: el staging es la
    # fuente; el destino es una BD NUEVA en produccion.
    prod_db_old="${pair%%:*}"
    stg_db="${pair##*:}"
    # Validacion del par 'produccion:staging': debe traer ':' y ambas partes.
    if [ "$pair" = "$prod_db_old" ] || [ -z "$prod_db_old" ] || [ -z "$stg_db" ]; then
        stg_log "WARN" "Mapa de BD invalido ('$pair'); omito BBDD."; rm -rf "$tmpdir"; return 0
    fi

    # Nombre de la BD nueva en produccion. Sufijo con timestamp + sufijo aleatorio
    # para evitar colisiones (dos pushes en el mismo segundo, o truncado a 60
    # chars que borre el timestamp). El aleatorio va PRIMERO tras recortar la base
    # para que nunca se pierda al truncar.
    local rnd_suffix
    rnd_suffix="$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom 2>/dev/null | head -c 8)"
    [ -n "$rnd_suffix" ] || rnd_suffix="$(printf '%s' "$$$(date +%s%N 2>/dev/null)" | sha256sum 2>/dev/null | LC_ALL=C tr -dc 'a-z0-9' | cut -c1-8)"
    # Base recortada para dejar sitio al sufijo "_live<rnd>" sin perderlo (60 max).
    local prod_db_base
    prod_db_base="$(printf '%s' "$prod_db_old" | cut -c1-45)"
    local prod_db_new="${prod_db_base}_live${rnd_suffix}"
    prod_db_new="$(printf '%s' "$prod_db_new" | cut -c1-60)"

    local dump="$tmpdir/push.sql"
    stg_log "INFO" "Volcando BBDD staging '$stg_db' para promover a produccion."
    if stg_vcmd v-dump-database "$stg_user" "$stg_db" "$dump" >/dev/null 2>&1 && [ -s "$dump" ]; then
        :
    else
        stg_vcmd v-dump-database "$stg_user" "$stg_db" > "$dump" 2>/dev/null || true
    fi
    [ -s "$dump" ] || { rm -rf "$tmpdir"; stg_die "Dump del staging vacio; no se promueve BBDD."; }

    # Reescritura inversa serialize-safe staging -> produccion sobre el dump.
    if declare -F stg_rewrite_dump >/dev/null 2>&1; then
        stg_log "INFO" "Reescritura inversa serialize-safe (staging -> produccion) sobre el dump."
        stg_rewrite_dump "$source_domain" "$dump" 'to-live' || \
            { rm -rf "$tmpdir"; stg_die "Fallo la reescritura inversa del dump; abortado antes de tocar produccion."; }
    else
        stg_log "WARN" "rewrite.sh no disponible: el dump conserva URLs de staging. Revisa tras el push."
    fi

    # Crea la BD nueva en produccion e importa.
    stg_log "INFO" "Creando BBDD nueva en produccion '$prod_db_new' e importando."
    local db_pass db_user
    db_user="$(stg_get_env "$source_domain" PROD_DB_USER "${src_user}_live")"
    # Generacion de password robusta: openssl -> /dev/urandom -> hash de entropia
    # del sistema. NUNCA un fallback predecible basado solo en timestamp.
    db_pass="$(openssl rand -base64 32 2>/dev/null | LC_ALL=C tr -dc 'A-Za-z0-9' | head -c 24)"
    if [ "${#db_pass}" -lt 20 ]; then
        db_pass="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 24)"
    fi
    if [ "${#db_pass}" -lt 20 ]; then
        # Ultimo recurso: hash de informacion del sistema (no reversible, no
        # adivinable solo con el timestamp). Garantiza >=20 caracteres alfanum.
        db_pass="$(printf '%s' "$(hostname 2>/dev/null)$(date +%s%N 2>/dev/null)$(whoami 2>/dev/null)$$" \
            | sha256sum 2>/dev/null | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-24)"
    fi
    [ "${#db_pass}" -ge 20 ] || { rm -rf "$tmpdir"; stg_die "No se pudo generar una password de BD segura (>=20 chars)."; }
    if ! stg_vcmd v-add-database "$src_user" "${prod_db_new}" "$db_user" "$db_pass" 'mysql' >/dev/null 2>&1; then
        # v-add-database antepone el usuario al nombre; reintenta sin sufijo manual.
        stg_log "WARN" "v-add-database con nombre completo fallo; reintento con nombre corto."
        prod_db_new="live${rnd_suffix}"
        stg_vcmd v-add-database "$src_user" "$prod_db_new" "$db_user" "$db_pass" 'mysql' >/dev/null 2>&1 || \
            { rm -rf "$tmpdir"; stg_die "No se pudo crear la BBDD nueva en produccion."; }
    fi
    # Nombre real (HestiaCP prefija con el usuario del panel).
    local real_db="${src_user}_${prod_db_new}"

    # Verifica que la BD existe REALMENTE antes de importar. Si v-add-database
    # devolvio 0 por error transitorio pero no creo la BD (cuota/permisos), no
    # debemos importar a ciegas: abortamos sin tocar produccion.
    if ! mysql -N -e "USE \`${real_db}\`;" >/dev/null 2>&1; then
        if ! stg_vcmd v-list-databases "$src_user" 2>/dev/null | grep -qw "$real_db"; then
            rm -rf "$tmpdir"
            stg_die "La BBDD nueva '$real_db' no existe tras v-add-database; abortado antes de importar."
        fi
    fi

    if ! stg_vcmd v-import-database "$src_user" "$real_db" "$dump" >/dev/null 2>&1; then
        if ! mysql "$real_db" < "$dump" >/dev/null 2>&1; then
            rm -rf "$tmpdir"
            stg_die "No se pudo importar el dump en la BBDD nueva de produccion ($real_db)."
        fi
    fi

    # Verificacion de integridad post-import ANTES de tocar la config del CMS.
    # Si la BD nueva quedo vacia (0 tablas), el import fallo silenciosamente:
    # NO cambiamos las credenciales (dejariamos prod apuntando a una BD rota).
    local new_tables
    new_tables="$(mysql -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${real_db}';" 2>/dev/null | head -n 1)"
    case "$new_tables" in
        ''|*[!0-9]*) new_tables=0 ;;
    esac
    if [ "$new_tables" -lt 1 ]; then
        rm -rf "$tmpdir"
        stg_die "La BBDD nueva '$real_db' quedo sin tablas tras el import; no se cambia la config (prod intacta)."
    fi
    stg_log "INFO" "Integridad de la BBDD nueva verificada: $new_tables tablas en '$real_db'."

    # Swap de credenciales en la config del CMS de produccion (apunta a la BD nueva).
    local real_user="${src_user}_${db_user}"
    _stg_push_swap_db_cfg "$source_domain" "$cms" "$src_docroot" "$real_db" "$real_user" "$db_pass" || \
        { rm -rf "$tmpdir"; _stg_push_abort_rollback "$source_domain" "fallo al cambiar credenciales de BD en produccion"; }

    stg_register_env "$source_domain" PUSH_DB_OLD "$prod_db_old"
    stg_register_env "$source_domain" PUSH_DB_NEW "$real_db"
    stg_log "INFO" "BBDD promovida a produccion: $real_db (anterior: $prod_db_old conservada)."
    rm -rf "$tmpdir" 2>/dev/null || true
    return 0
}

# ---------------------------------------------------------------------------
# _stg_push_sed_escape VALUE -> escapa los metacaracteres que sed interpreta en
# el REEMPLAZO (\, &, /). Imprime el valor saneado por stdout. Imprescindible
# para no corromper la config del CMS cuando una password/usuario/nombre de BD
# contiene '/', '&' o '\'. (Mismo patron que _stg_php_set_define en rewrite.sh.)
# ---------------------------------------------------------------------------
_stg_push_sed_escape() {
    printf '%s' "$1" | sed -e 's/[\/&]/\\&/g'
}

# ---------------------------------------------------------------------------
# _stg_push_swap_db_cfg SOURCE_DOMAIN CMS DOCROOT DBNAME DBUSER DBPASS
# Cambia las credenciales de BD en el fichero de config del CMS en produccion.
# Hace backup del fichero (para rollback) antes de tocar.
# ---------------------------------------------------------------------------
_stg_push_swap_db_cfg() {
    local source_domain="$1"; local cms="$2"; local docroot="$3"
    local dbname="$4"; local dbuser="$5"; local dbpass="$6"
    local cfg=''
    case "$cms" in
        wordpress)  cfg="$docroot/wp-config.php" ;;
        prestashop) cfg="$docroot/config/settings.inc.php"; [ -f "$cfg" ] || cfg="$docroot/app/config/parameters.php" ;;
        laravel)    cfg="$docroot/.env" ;;
        joomla)     cfg="$docroot/configuration.php" ;;
        *) stg_log "INFO" "CMS '$cms' sin swap de credenciales."; return 0 ;;
    esac
    [ -f "$cfg" ] || { stg_log "WARN" "Config CMS no encontrada ($cfg); no se cambian credenciales."; return 0; }

    local bak="$cfg.stgbak.$(date +%s)"
    cp -f "$cfg" "$bak" 2>/dev/null || return 1
    STG_PUSH_DB_CFG="$cfg"
    STG_PUSH_DB_CFG_BAK="$bak"
    stg_register_env "$source_domain" PUSH_CFG "$cfg"
    stg_register_env "$source_domain" PUSH_CFG_BAK "$bak"

    # Escapado obligatorio de los valores antes de usarlos en el REEMPLAZO de sed.
    # Sin esto, una password/usuario/nombre con '/', '&' o '\' corrompe el sed y
    # deja la config del CMS en estado indefinido (riesgo critico en produccion).
    local s_dbname s_dbuser s_dbpass
    s_dbname="$(_stg_push_sed_escape "$dbname")"
    s_dbuser="$(_stg_push_sed_escape "$dbuser")"
    s_dbpass="$(_stg_push_sed_escape "$dbpass")"

    # Reemplazos seguros por CMS. Se usa un script python si esta, si no sed
    # acotado por clave (sin tocar serializaciones: aqui son escalares de config).
    case "$cms" in
        wordpress)
            sed -i -E "s/(define\(\s*'DB_NAME'\s*,\s*')[^']*('\s*\))/\1${s_dbname}\2/" "$cfg"
            sed -i -E "s/(define\(\s*'DB_USER'\s*,\s*')[^']*('\s*\))/\1${s_dbuser}\2/" "$cfg"
            sed -i -E "s/(define\(\s*'DB_PASSWORD'\s*,\s*')[^']*('\s*\))/\1${s_dbpass}\2/" "$cfg"
            ;;
        laravel)
            sed -i -E "s/^DB_DATABASE=.*/DB_DATABASE=${s_dbname}/" "$cfg"
            sed -i -E "s/^DB_USERNAME=.*/DB_USERNAME=${s_dbuser}/" "$cfg"
            sed -i -E "s/^DB_PASSWORD=.*/DB_PASSWORD=${s_dbpass}/" "$cfg"
            ;;
        prestashop)
            if grep -q "_DB_NAME_" "$cfg"; then
                sed -i -E "s/(_DB_NAME_'\s*,\s*')[^']*(')/\1${s_dbname}\2/" "$cfg"
                sed -i -E "s/(_DB_USER_'\s*,\s*')[^']*(')/\1${s_dbuser}\2/" "$cfg"
                sed -i -E "s/(_DB_PASSWD_'\s*,\s*')[^']*(')/\1${s_dbpass}\2/" "$cfg"
            else
                sed -i -E "s/('database_name'\s*=>\s*')[^']*(')/\1${s_dbname}\2/" "$cfg"
                sed -i -E "s/('database_user'\s*=>\s*')[^']*(')/\1${s_dbuser}\2/" "$cfg"
                sed -i -E "s/('database_password'\s*=>\s*')[^']*(')/\1${s_dbpass}\2/" "$cfg"
            fi
            ;;
        joomla)
            sed -i -E "s/(\\\$db\s*=\s*')[^']*(')/\1${s_dbname}\2/" "$cfg"
            sed -i -E "s/(\\\$user\s*=\s*')[^']*(')/\1${s_dbuser}\2/" "$cfg"
            sed -i -E "s/(\\\$password\s*=\s*')[^']*(')/\1${s_dbpass}\2/" "$cfg"
            ;;
    esac
    STG_PUSH_DB_SWAPPED=1
    stg_log "INFO" "Credenciales de BD actualizadas en $cfg (backup en $bak)."
    return 0
}

# ---------------------------------------------------------------------------
# stg_push_live SOURCE_DOMAIN
# Punto de entrada del push-to-live con todas las salvaguardas.
# ---------------------------------------------------------------------------
stg_push_live() {
    local source_domain="$1"
    [ -n "$source_domain" ] || stg_die "stg_push_live: dominio origen vacio"

    stg_audit "$source_domain" push start "solicitud de push-to-live"

    # --- SALVAGUARDA 1: kill switch (por defecto bloqueado) -----------------
    if stg_push_blocked; then
        stg_audit "$source_domain" push blocked "STG_PUSH_KILL_SWITCH=true"
        stg_die "PUSH BLOQUEADO por kill switch (STG_PUSH_KILL_SWITCH='true'). Cambialo a 'false' en conf/staging.conf solo cuando estes seguro."
    fi

    # Verifica que el entorno staging existe.
    local stg_domain
    stg_domain="$(stg_get_env "$source_domain" STG_DOMAIN '')"
    [ -n "$stg_domain" ] || stg_die "No hay entorno staging para '$source_domain'. Nada que promover."

    # --- SALVAGUARDA 2: backup live reciente OBLIGATORIO --------------------
    # Forzamos un backup live ANTES de escribir nada. v-backup-user genera el
    # backup completo del usuario de produccion; registramos su ruta y fecha.
    local src_user
    src_user="$(stg_get_env "$source_domain" SOURCE_USER '')"
    [ -n "$src_user" ] || stg_die "No se conoce el usuario de produccion para '$source_domain'."
    stg_log "INFO" "Generando backup live de produccion (usuario '$src_user') antes del push."
    if stg_vcmd v-backup-user "$src_user" >/dev/null 2>&1; then
        # Localiza el backup mas reciente del usuario.
        local bdir="/backup" newest
        newest="$(ls -1t "$bdir"/${src_user}.*.tar 2>/dev/null | head -n 1)"
        [ -n "$newest" ] || newest="$(ls -1t "$bdir"/${src_user}.* 2>/dev/null | head -n 1)"
        if [ -n "$newest" ]; then
            # Verificacion de INTEGRIDAD del backup antes de tocar produccion. Un
            # backup truncado o corrupto pasaria la comprobacion de existencia/TTL
            # pero haria fallar el rollback en una catastrofe. No promovemos si el
            # backup no es minimamente valido.
            local bk_size=0
            bk_size="$(stat -c '%s' "$newest" 2>/dev/null || wc -c <"$newest" 2>/dev/null || echo 0)"
            case "$bk_size" in ''|*[!0-9]*) bk_size=0 ;; esac
            if [ "$bk_size" -lt 102400 ]; then
                stg_die "Backup live '$newest' demasiado pequeno ($bk_size bytes); posible truncado/corrupto. No se promueve."
            fi
            case "$newest" in
                *.tar.gz|*.tgz)
                    tar -tzf "$newest" >/dev/null 2>&1 || stg_die "Backup live '$newest' no es un tar.gz valido; no se promueve." ;;
                *.tar)
                    tar -tf "$newest" >/dev/null 2>&1 || stg_die "Backup live '$newest' no es un tar valido; no se promueve." ;;
            esac
            stg_register_env "$source_domain" LIVE_BACKUP_PATH "$newest"
            stg_register_env "$source_domain" LIVE_BACKUP_AT "$(date +%s)"
            stg_log "INFO" "Backup live registrado y verificado ($bk_size bytes): $newest"
        else
            stg_register_env "$source_domain" LIVE_BACKUP_PATH "/backup/${src_user}.tar"
            stg_register_env "$source_domain" LIVE_BACKUP_AT "$(date +%s)"
            stg_log "WARN" "No se localizo el fichero de backup exacto; registro generico."
        fi
    else
        stg_die "v-backup-user fallo para '$src_user'. No se promueve sin backup live."
    fi
    # Valida el backup segun el contrato (existe, reciente).
    stg_require_backup_done "$source_domain"

    # --- SALVAGUARDA 3: confirmacion explicita (doble verificacion) ---------
    stg_confirm "$source_domain"

    stg_audit "$source_domain" push authorized "kill_switch=off backup=ok confirm=ok"
    stg_log "INFO" "Salvaguardas superadas. Iniciando push-to-live de '$source_domain'."

    # --- Ejecucion del push (con rollback automatico ante cualquier fallo) --
    # Ficheros primero, BBDD despues; el orden importa para el rollback.
    if ! stg_push_files "$source_domain"; then
        _stg_push_abort_rollback "$source_domain" "fallo en el swap de ficheros"
    fi
    if ! stg_push_db "$source_domain"; then
        _stg_push_abort_rollback "$source_domain" "fallo en la promocion de BBDD"
    fi

    # Reconstruye la config web del dominio de produccion y valida HTTP.
    stg_vcmd v-rebuild-web-domain "$src_user" "$source_domain" >/dev/null 2>&1 || \
        stg_log "WARN" "v-rebuild-web-domain devolvio error (revisar)."

    if command -v curl >/dev/null 2>&1; then
        local code
        # Solo HTTP 200 cuenta como exito. Un 301/302 puede esconder un redirect
        # a una pagina rota o externa: indistinguible de un sitio sano, asi que NO
        # lo aceptamos. Seguimos hasta 3 redirects (-L) para llegar al destino real
        # y exigimos 200 ahi. Timeout ampliado a 90s para sitios lentos.
        code="$(curl -ksSL --max-redirs 3 -o /dev/null -w '%{http_code}' --max-time 90 "https://$source_domain/" 2>/dev/null || echo 000)"
        case "$code" in
            200) stg_log "INFO" "Produccion '$source_domain' responde HTTP 200 tras el push." ;;
            *)
                stg_log "ERROR" "Produccion responde HTTP $code (se exige 200) tras el push; revierto."
                _stg_push_abort_rollback "$source_domain" "validacion HTTP post-push fallida (HTTP $code, se exige 200)"
                ;;
        esac
    fi

    # Limpieza: el .stgold se conserva hasta que el operador confirme. Lo dejamos
    # para permitir rollback manual posterior; registramos su retencion.
    stg_register_env "$source_domain" PUSH_DONE_AT "$(date +%s)"
    stg_audit "$source_domain" push success "ficheros+bbdd promovidos; backup live y .stgold conservados"
    stg_log "INFO" "PUSH-TO-LIVE COMPLETADO para '$source_domain'. Rollback disponible (v-staging-rollback)."
    echo "PUSH-TO-LIVE OK para '$source_domain'. Backup live y copia anterior conservados para rollback."
    return 0
}

# Ejecucion directa.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    set -euo pipefail
    [ $# -ge 1 ] || stg_die "Uso: STG_CONFIRM=<domain> push_live.sh <source_domain>"
    stg_push_live "$1"
fi
