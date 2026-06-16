#!/bin/bash
# rewrite.sh - Reescritura del entorno staging tras el clonado (ficheros + BBDD).
# Aplica reemplazos origen->staging de forma SEGURA por CMS:
#   - WordPress: wp-cli search-replace SERIALIZE-SAFE (NUNCA sed plano sobre dump);
#     fallback a un reemplazo serialize-safe propio en PHP si no hay wp-cli.
#   - Actualiza credenciales de BBDD en wp-config.php / .env / settings.inc.php /
#     parameters.php / configuration.php.
#   - Desactiva en staging: envio de emails reales, pasarelas de pago, cron
#     destructivo. Aplica noindex (X-Robots-Tag + robots.txt + meta).
#
# Uso: rewrite.sh <cms> <docroot> <src_domain> <stg_domain> <db_map> [db_pass_map]
#   db_map      = "engine|src_db|stg_db|real_db|stg_dbuser|stg_dbpass; ..."
# Tambien sourceable: stg_rewrite ...

if [ -z "${STG_ROOT:-}" ] || ! declare -F stg_log >/dev/null 2>&1; then
    _rw_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
    # shellcheck source=/dev/null
    . "$_rw_dir/common.sh"
fi

# ---------------------------------------------------------------------------
# _stg_resolve_wpcli -> ruta de wp-cli (conf STG_WPCLI o PATH) o vacio.
# ---------------------------------------------------------------------------
_stg_resolve_wpcli() {
    local cfg
    cfg="$(stg_conf_get STG_WPCLI '')"
    if [ -n "$cfg" ] && [ -x "$cfg" ]; then printf '%s' "$cfg"; return 0; fi
    if command -v wp >/dev/null 2>&1; then command -v wp; return 0; fi
    return 0
}

# ---------------------------------------------------------------------------
# _stg_php_set_define FILE NAME VALUE -> reescribe define('NAME','VALUE'); en un
# fichero PHP de forma puntual (solo la linea del define, valor entre comillas
# simples). No toca el resto del fichero. Hace copia de seguridad .stgbak.
# ---------------------------------------------------------------------------
_stg_php_set_define() {
    local file="$1"; local name="$2"; local value="$3"
    [ -f "$file" ] || return 0
    [ -f "$file.stgbak" ] || cp -p "$file" "$file.stgbak"
    # Escapa para sed: solo se sustituye el literal de la linea del define exacto.
    local esc_val
    esc_val="$(printf '%s' "$value" | sed -e 's/[\/&]/\\&/g')"
    # Sustituye el contenido entre las comillas del segundo argumento del define.
    sed -i -E "s/(define\(\s*['\"]${name}['\"]\s*,\s*)['\"][^'\"]*['\"]/\1'${esc_val}'/" "$file"
    stg_log "DEBUG" "rewrite: define $name actualizado en $(basename "$file")"
}

# ---------------------------------------------------------------------------
# _stg_env_set FILE KEY VALUE -> reescribe KEY=VALUE en un fichero .env (Laravel).
# Crea la clave si no existe. Copia de seguridad .stgbak.
# ---------------------------------------------------------------------------
_stg_env_set() {
    local file="$1"; local key="$2"; local value="$3"
    [ -f "$file" ] || return 0
    [ -f "$file.stgbak" ] || cp -p "$file" "$file.stgbak"
    local esc_val
    esc_val="$(printf '%s' "$value" | sed -e 's/[\/&]/\\&/g')"
    if grep -qE "^[[:space:]]*${key}=" "$file"; then
        sed -i -E "s/^[[:space:]]*${key}=.*/${key}=${esc_val}/" "$file"
    else
        printf '%s=%s\n' "$key" "$value" >> "$file"
    fi
    stg_log "DEBUG" "rewrite: .env $key actualizado"
}

# ---------------------------------------------------------------------------
# _stg_first_dbmap DB_MAP -> imprime el primer registro (engine|src|stg|real|user|pass).
# La mayoria de CMS usan una sola BBDD principal.
# ---------------------------------------------------------------------------
_stg_first_dbmap() {
    printf '%s' "$1" | tr ';' '\n' | sed '/^[[:space:]]*$/d' | head -n 1 | sed 's/^[[:space:]]*//'
}

# ---------------------------------------------------------------------------
# _stg_mysql_esc VALUE -> escapa un valor para usarlo DENTRO de comillas simples
# en una sentencia MySQL. Escapa la barra invertida y la comilla simple (en ese
# orden) para impedir inyeccion SQL al interpolar el valor en un literal '...'.
# Uso: "'$(_stg_mysql_esc "$valor")'"
# ---------------------------------------------------------------------------
_stg_mysql_esc() {
    local v="$1"
    v="${v//\\/\\\\}"   # \  -> \\   (primero, para no re-escapar lo anadido)
    v="${v//\'/\\\'}"   # '  -> \'
    printf '%s' "$v"
}

# ---------------------------------------------------------------------------
# _stg_is_safe_ident NAME -> 0 si NAME es un identificador seguro para usar como
# prefijo de tabla MySQL (solo [A-Za-z0-9_]). Evita inyeccion via backticks en
# nombres de tabla. Devuelve 1 si contiene cualquier otro caracter.
# ---------------------------------------------------------------------------
_stg_is_safe_ident() {
    case "$1" in
        ''|*[!A-Za-z0-9_]*) return 1 ;;
        *) return 0 ;;
    esac
}

# ---------------------------------------------------------------------------
# WordPress
# ---------------------------------------------------------------------------
_stg_rewrite_wordpress() {
    local docroot="$1"; local src_domain="$2"; local stg_domain="$3"; local dbmap="$4"
    local cfg="$docroot/wp-config.php"

    # Si el wp-config no se clono (excluido), genera uno minimo a partir del .stgbak
    # del origen si existe; en caso normal HestiaCP/clone deja el del origen excluido,
    # por lo que aqui se espera que rewrite reciba un wp-config presente o lo cree.
    if [ ! -f "$cfg" ] && [ -f "$cfg.src" ]; then
        cp -p "$cfg.src" "$cfg"
    fi

    # Credenciales de BBDD del primer mapeo.
    local first engine src_db stg_db real_db dbuser dbpass
    first="$(_stg_first_dbmap "$dbmap")"
    if [ -n "$first" ]; then
        IFS='|' read -r engine src_db stg_db real_db dbuser dbpass <<< "$first"
        _stg_php_set_define "$cfg" 'DB_NAME' "$real_db"
        _stg_php_set_define "$cfg" 'DB_USER' "$dbuser"
        _stg_php_set_define "$cfg" 'DB_PASSWORD' "$dbpass"
        _stg_php_set_define "$cfg" 'DB_HOST' 'localhost'
    fi

    # Entorno staging + desactivacion de envios y cron destructivo.
    _stg_wp_inject_constants "$cfg"

    # search-replace de URL SERIALIZE-SAFE (sobre la BBDD ya importada, NUNCA dump).
    local wp
    wp="$(_stg_resolve_wpcli)"
    local owner; owner="$(stat -c '%U' "$docroot" 2>/dev/null || echo '')"
    if [ -n "$wp" ]; then
        local -a run=( "$wp" --path="$docroot" --skip-themes --skip-plugins )
        # Ejecuta como el propietario para evitar avisos de wp-cli como root.
        local -a pre=()
        if [ -n "$owner" ] && [ "$owner" != "root" ] && command -v sudo >/dev/null 2>&1; then
            pre=( sudo -u "$owner" )
        fi
        local from to
        # Reemplaza tanto con esquema como sin el, y dominios desnudos.
        for from in "https://$src_domain" "http://$src_domain" "//$src_domain" "$src_domain"; do
            to="${from/$src_domain/$stg_domain}"
            if "${pre[@]}" "${run[@]}" search-replace "$from" "$to" --all-tables-with-prefix --precise --recurse-objects --skip-columns=guid >/dev/null 2>&1; then
                stg_log "INFO" "rewrite(wp): search-replace '$from' -> '$to' OK."
            else
                stg_log "WARN" "rewrite(wp): search-replace '$from' fallo o sin cambios."
            fi
        done
        # Actualiza siteurl/home por si quedaron fuera.
        "${pre[@]}" "${run[@]}" option update home "https://$stg_domain" >/dev/null 2>&1 || true
        "${pre[@]}" "${run[@]}" option update siteurl "https://$stg_domain" >/dev/null 2>&1 || true
        # Discourage search engines (noindex nativo de WP).
        "${pre[@]}" "${run[@]}" option update blog_public 0 >/dev/null 2>&1 || true
        # Pasarelas de pago y emails: desactiva en WooCommerce si esta presente.
        if [ "$(stg_conf_get STG_DISABLE_PAYMENTS true)" = "true" ]; then
            "${pre[@]}" "${run[@]}" option update woocommerce_default_gateway '' >/dev/null 2>&1 || true
        fi
    else
        # Fallback serialize-safe propio en PHP (NUNCA sed plano sobre el dump).
        stg_log "WARN" "rewrite(wp): wp-cli no disponible, se usa reemplazo serialize-safe PHP."
        _stg_db_php_search_replace "$real_db" "$src_domain" "$stg_domain"
    fi
}

# ---------------------------------------------------------------------------
# _stg_wp_inject_constants CFG -> inyecta constantes de staging en wp-config.php
# antes de "stop editing". Idempotente (no duplica el bloque).
# ---------------------------------------------------------------------------
_stg_wp_inject_constants() {
    local cfg="$1"
    [ -f "$cfg" ] || return 0
    grep -q 'STG_STAGING_BLOCK' "$cfg" && return 0
    [ -f "$cfg.stgbak" ] || cp -p "$cfg" "$cfg.stgbak"
    local block
    local disable_mail; disable_mail="$(stg_conf_get STG_DISABLE_EMAILS true)"
    block="/* STG_STAGING_BLOCK inicio - inyectado por plugin Staging HestiaCP */\n"
    block+="if (!defined('WP_ENVIRONMENT_TYPE')) { define('WP_ENVIRONMENT_TYPE', 'staging'); }\n"
    block+="if (!defined('DISALLOW_FILE_MODS')) { define('DISALLOW_FILE_MODS', false); }\n"
    block+="if (!defined('DISABLE_WP_CRON')) { define('DISABLE_WP_CRON', true); }\n"  # cron no destructivo
    block+="if (!defined('WP_DISABLE_FATAL_ERROR_HANDLER')) { define('WP_DISABLE_FATAL_ERROR_HANDLER', false); }\n"
    if [ "$disable_mail" = "true" ]; then
        # Intercepta wp_mail: en staging no se envian correos reales.
        block+="if (!function_exists('wp_mail')) { function wp_mail(\$to=null, \$subject=null, \$message=null, \$headers='', \$attachments=array()) { return true; } }\n"
    fi
    block+="/* STG_STAGING_BLOCK fin */\n"
    # Inserta antes de la linea "stop editing" tipica de wp-config.php.
    if grep -q "stop editing" "$cfg"; then
        awk -v b="$block" '
            /stop editing/ && !done { printf "%s", b; done=1 }
            { print }
        ' "$cfg" > "$cfg.tmp" && mv -f "$cfg.tmp" "$cfg"
    else
        # Si no existe el marcador, lo anade tras la apertura <?php.
        printf '%b' "$block" >> "$cfg"
    fi
    stg_log "INFO" "rewrite(wp): constantes de staging inyectadas en wp-config.php."
}

# ---------------------------------------------------------------------------
# _stg_db_php_search_replace REAL_DB SRC DST -> reemplazo serialize-safe en PHP
# sobre la BBDD ya importada (CMS-agnostico: WordPress, PrestaShop, etc.).
# Recorre todas las tablas/columnas de texto y reserializa los valores PHP cuyo
# unserialize cambia de longitud. NO usa sed plano sobre el dump.
# ---------------------------------------------------------------------------
_stg_db_php_search_replace() {
    local db="$1"; local from="$2"; local to="$3"
    command -v php >/dev/null 2>&1 || { stg_log "ERROR" "rewrite(wp): php CLI no disponible para reemplazo serialize-safe."; return 1; }
    local script="$STG_STATE_DIR/.wp_srdb.$$.php"
    cat > "$script" <<'PHP'
<?php
// Reemplazo serialize-safe de cadenas en una BBDD MySQL (sin sed plano).
// Recorre tablas y columnas de texto, reserializando estructuras PHP afectadas.
list($db, $from, $to) = array($argv[1], $argv[2], $argv[3]);
$mysqli = @mysqli_connect('localhost', null, null, $db); // usa ~/.my.cnf de root
if (!$mysqli) { fwrite(STDERR, "no db connection\n"); exit(2); }
mysqli_set_charset($mysqli, 'utf8mb4');
// Quoting seguro de identificadores (tabla/columna): duplica backticks para
// impedir inyeccion via nombres con caracteres especiales aunque provengan del esquema.
function srdb_qid($name) { return '`' . str_replace('`', '``', (string)$name) . '`'; }
function srdb_replace($data, $from, $to) {
    if (is_string($data) && ($un = @unserialize($data)) !== false) {
        return serialize(srdb_replace($un, $from, $to));
    } elseif (is_array($data)) {
        $r = array();
        foreach ($data as $k => $v) { $r[srdb_replace($k,$from,$to)] = srdb_replace($v,$from,$to); }
        return $r;
    } elseif (is_object($data)) {
        foreach ($data as $k => $v) { $data->$k = srdb_replace($v,$from,$to); }
        return $data;
    } elseif (is_string($data)) {
        return str_replace($from, $to, $data);
    }
    return $data;
}
$tables = array();
$res = mysqli_query($mysqli, "SHOW TABLES");
while ($row = mysqli_fetch_row($res)) { $tables[] = $row[0]; }
foreach ($tables as $t) {
    $cols = array(); $pk = null;
    $cr = mysqli_query($mysqli, "SHOW COLUMNS FROM " . srdb_qid($t));
    while ($c = mysqli_fetch_assoc($cr)) {
        if (preg_match('/char|text|blob/i', $c['Type'])) { $cols[] = $c['Field']; }
        if ($c['Key'] === 'PRI') { $pk = $c['Field']; }
    }
    if (!$cols || !$pk) { continue; }
    $qcols = array_map('srdb_qid', $cols);
    $sel = srdb_qid($pk) . ',' . implode(',', $qcols);
    $dr = mysqli_query($mysqli, "SELECT $sel FROM " . srdb_qid($t));
    if (!$dr) { continue; }
    while ($r = mysqli_fetch_assoc($dr)) {
        $set = array();
        foreach ($cols as $col) {
            if ($r[$col] === null) { continue; }
            $new = srdb_replace($r[$col], $from, $to);
            if ($new !== $r[$col]) {
                $set[] = srdb_qid($col) . "='" . mysqli_real_escape_string($mysqli, $new) . "'";
            }
        }
        if ($set) {
            $id = mysqli_real_escape_string($mysqli, $r[$pk]);
            mysqli_query($mysqli, "UPDATE " . srdb_qid($t) . " SET " . implode(',', $set) . " WHERE " . srdb_qid($pk) . "='$id'");
        }
    }
}
mysqli_close($mysqli);
echo "ok\n";
PHP
    if php "$script" "$db" "$from" "$to" >/dev/null 2>&1; then
        stg_log "INFO" "rewrite(wp): reemplazo serialize-safe PHP '$from' -> '$to' OK en '$db'."
    else
        stg_log "ERROR" "rewrite(wp): reemplazo serialize-safe PHP fallo en '$db'."
    fi
    rm -f "$script" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# PrestaShop
# ---------------------------------------------------------------------------
_stg_rewrite_prestashop() {
    local docroot="$1"; local src_domain="$2"; local stg_domain="$3"; local dbmap="$4"
    local first engine src_db stg_db real_db dbuser dbpass
    first="$(_stg_first_dbmap "$dbmap")"
    [ -n "$first" ] && IFS='|' read -r engine src_db stg_db real_db dbuser dbpass <<< "$first"

    # settings.inc.php (PS 1.6) o parameters.php (PS 1.7+).
    local sett="$docroot/config/settings.inc.php"
    local params="$docroot/app/config/parameters.php"
    if [ -f "$sett" ]; then
        [ -f "$sett.stgbak" ] || cp -p "$sett" "$sett.stgbak"
        sed -i -E "s/(define\(\s*'_DB_NAME_'\s*,\s*)'[^']*'/\1'${real_db}'/" "$sett"
        sed -i -E "s/(define\(\s*'_DB_USER_'\s*,\s*)'[^']*'/\1'${dbuser}'/" "$sett"
        sed -i -E "s/(define\(\s*'_DB_PASSWD_'\s*,\s*)'[^']*'/\1'${dbpass}'/" "$sett"
        sed -i -E "s/(define\(\s*'_DB_SERVER_'\s*,\s*)'[^']*'/\1'localhost'/" "$sett"
    elif [ -f "$params" ]; then
        [ -f "$params.stgbak" ] || cp -p "$params" "$params.stgbak"
        sed -i -E "s/('database_name'\s*=>\s*)'[^']*'/\1'${real_db}'/" "$params"
        sed -i -E "s/('database_user'\s*=>\s*)'[^']*'/\1'${dbuser}'/" "$params"
        sed -i -E "s/('database_password'\s*=>\s*)'[^']*'/\1'${dbpass}'/" "$params"
        sed -i -E "s/('database_host'\s*=>\s*)'[^']*'/\1'localhost'/" "$params"
    fi

    # 1) Cambio puntual del dominio en ps_shop_url + PS_SHOP_DOMAIN(_SSL).
    #    UPDATE directo sobre la BBDD ya importada (NUNCA sed sobre el dump).
    if command -v mysql >/dev/null 2>&1 && [ -n "${real_db:-}" ]; then
        local pfx
        pfx="$(mysql -N -B "$real_db" -e "SHOW TABLES LIKE '%shop_url'" 2>/dev/null | head -n 1 | sed 's/shop_url$//')"
        pfx="${pfx:-ps_}"
        # El prefijo procede del esquema, pero se valida para impedir inyeccion
        # via backticks en el nombre de tabla. Si no es seguro, se aborta el bloque.
        if ! _stg_is_safe_ident "$pfx"; then
            stg_log "WARN" "rewrite(ps): prefijo de tabla no valido '$pfx'; se omite el UPDATE de dominio y mantenimiento."
        else
            # Dominio escapado para literal MySQL: impide inyeccion via comilla
            # simple en un dominio malformado (p.ej. test'.com).
            local stg_domain_sql
            stg_domain_sql="$(_stg_mysql_esc "$stg_domain")"
            mysql "$real_db" <<SQL 2>/dev/null || stg_log "WARN" "rewrite(ps): UPDATE de ps_shop_url pudo fallar."
UPDATE \`${pfx}shop_url\` SET domain='${stg_domain_sql}', domain_ssl='${stg_domain_sql}';
UPDATE \`${pfx}configuration\` SET value='${stg_domain_sql}' WHERE name IN ('PS_SHOP_DOMAIN','PS_SHOP_DOMAIN_SSL');
SQL
            stg_log "INFO" "rewrite(ps): ps_shop_url + PS_SHOP_DOMAIN reescritos a '$stg_domain' (prefijo $pfx)."

            # Modo mantenimiento opcional para que el staging no quede publico/operativo.
            if [ "$(stg_conf_get STG_DISABLE_PAYMENTS true)" = "true" ]; then
                mysql "$real_db" -e "UPDATE \`${pfx}configuration\` SET value='1' WHERE name='PS_MAINTENANCE'" 2>/dev/null || true
            fi
        fi

        # 2) Busqueda y reemplazo GENERAL serialize-safe en TODA la BBDD: URLs
        #    cableadas en cms, meta, modulos y configuracion serializada. Solo
        #    variantes con esquema (https/http///) para no tocar emails @dominio.
        #    No depende del prefijo: opera sobre toda la BBDD ya importada.
        if [ "$(stg_conf_get STG_PS_SEARCH_REPLACE true)" = "true" ]; then
            local from to
            for from in "https://$src_domain" "http://$src_domain" "//$src_domain"; do
                to="${from/$src_domain/$stg_domain}"
                _stg_db_php_search_replace "$real_db" "$from" "$to"
            done
            stg_log "INFO" "rewrite(ps): busqueda y reemplazo de URLs completado en '$real_db'."
        fi
    fi

    # Limpia la cache de PrestaShop tras el cambio de dominio (PS 1.6 y 1.7/8).
    rm -rf "$docroot/var/cache/"* 2>/dev/null || true
    rm -f  "$docroot/cache/class_index.php" 2>/dev/null || true
    rm -rf "$docroot/app/cache/"* 2>/dev/null || true
    stg_log "INFO" "rewrite(ps): cache de PrestaShop limpiada."
}

# ---------------------------------------------------------------------------
# Laravel
# ---------------------------------------------------------------------------
_stg_rewrite_laravel() {
    local docroot="$1"; local src_domain="$2"; local stg_domain="$3"; local dbmap="$4"
    local env="$docroot/.env"
    [ -f "$env" ] || { stg_log "WARN" "rewrite(laravel): no hay .env en $docroot."; return 0; }
    local first engine src_db stg_db real_db dbuser dbpass
    first="$(_stg_first_dbmap "$dbmap")"
    [ -n "$first" ] && IFS='|' read -r engine src_db stg_db real_db dbuser dbpass <<< "$first"

    _stg_env_set "$env" 'DB_DATABASE' "$real_db"
    _stg_env_set "$env" 'DB_USERNAME' "$dbuser"
    _stg_env_set "$env" 'DB_PASSWORD' "$dbpass"
    _stg_env_set "$env" 'DB_HOST' '127.0.0.1'
    _stg_env_set "$env" 'APP_ENV' 'staging'
    _stg_env_set "$env" 'APP_URL' "https://$stg_domain"
    _stg_env_set "$env" 'APP_DEBUG' 'false'
    # Desactiva envios reales y cron/colas destructivas en staging.
    [ "$(stg_conf_get STG_DISABLE_EMAILS true)" = "true" ] && _stg_env_set "$env" 'MAIL_MAILER' 'log'
    _stg_env_set "$env" 'QUEUE_CONNECTION' 'sync'
    _stg_env_set "$env" 'SESSION_SECURE_COOKIE' 'false'
    if [ "$(stg_conf_get STG_DISABLE_PAYMENTS true)" = "true" ]; then
        _stg_env_set "$env" 'CASHIER_KEY' ''
        _stg_env_set "$env" 'STRIPE_KEY' ''
    fi
    stg_log "INFO" "rewrite(laravel): .env reescrito para staging '$stg_domain'."
}

# ---------------------------------------------------------------------------
# Joomla
# ---------------------------------------------------------------------------
_stg_rewrite_joomla() {
    local docroot="$1"; local src_domain="$2"; local stg_domain="$3"; local dbmap="$4"
    local cfg="$docroot/configuration.php"
    [ -f "$cfg" ] || { stg_log "WARN" "rewrite(joomla): no hay configuration.php."; return 0; }
    [ -f "$cfg.stgbak" ] || cp -p "$cfg" "$cfg.stgbak"
    local first engine src_db stg_db real_db dbuser dbpass
    first="$(_stg_first_dbmap "$dbmap")"
    [ -n "$first" ] && IFS='|' read -r engine src_db stg_db real_db dbuser dbpass <<< "$first"
    sed -i -E "s/(\\\$db\s*=\s*)'[^']*'/\1'${real_db}'/" "$cfg"
    sed -i -E "s/(\\\$user\s*=\s*)'[^']*'/\1'${dbuser}'/" "$cfg"
    sed -i -E "s/(\\\$password\s*=\s*)'[^']*'/\1'${dbpass}'/" "$cfg"
    sed -i -E "s/(\\\$host\s*=\s*)'[^']*'/\1'localhost'/" "$cfg"
    # Modo offline (evita acceso publico al staging) y sin envio real opcional.
    sed -i -E "s/(\\\$offline\s*=\s*).*/\1'1';/" "$cfg" 2>/dev/null || true
    stg_log "INFO" "rewrite(joomla): configuration.php reescrito para staging."
}

# ---------------------------------------------------------------------------
# _stg_apply_noindex DOCROOT -> robots.txt de bloqueo total + .htaccess noindex +
# nota .stg-noindex. Solo si STG_NOINDEX='true'.
# ---------------------------------------------------------------------------
_stg_apply_noindex() {
    local docroot="$1"
    [ "$(stg_conf_get STG_NOINDEX true)" = "true" ] || return 0
    [ -d "$docroot" ] || return 0
    # robots.txt: Disallow total.
    cat > "$docroot/robots.txt" <<'ROBOTS'
User-agent: *
Disallow: /
ROBOTS
    # X-Robots-Tag via .htaccess (Apache). Idempotente.
    local ht="$docroot/.htaccess"
    if [ -f "$ht" ]; then
        grep -q 'STG_NOINDEX_BLOCK' "$ht" || cat >> "$ht" <<'HT'
# STG_NOINDEX_BLOCK - cabecera noindex inyectada por plugin Staging HestiaCP
<IfModule mod_headers.c>
    Header set X-Robots-Tag "noindex, nofollow, noarchive"
</IfModule>
HT
    else
        cat > "$ht" <<'HT'
# STG_NOINDEX_BLOCK - cabecera noindex inyectada por plugin Staging HestiaCP
<IfModule mod_headers.c>
    Header set X-Robots-Tag "noindex, nofollow, noarchive"
</IfModule>
HT
    fi
    stg_log "INFO" "rewrite: noindex aplicado (robots.txt + X-Robots-Tag) en $docroot."
}

# ---------------------------------------------------------------------------
# stg_rewrite CMS DOCROOT SRC_DOMAIN STG_DOMAIN DB_MAP
# Orquesta la reescritura completa segun el CMS.
# ---------------------------------------------------------------------------
stg_rewrite() {
    local cms="$1"; local docroot="$2"; local src_domain="$3"; local stg_domain="$4"; local dbmap="${5:-}"

    [ -n "$cms" ]        || stg_die "rewrite: cms vacio."
    [ -n "$docroot" ]    || stg_die "rewrite: docroot vacio."
    [ -d "$docroot" ]    || stg_die "rewrite: docroot inexistente: $docroot"
    [ -n "$src_domain" ] || stg_die "rewrite: dominio origen vacio."
    [ -n "$stg_domain" ] || stg_die "rewrite: dominio staging vacio."

    stg_log "INFO" "rewrite: CMS=$cms docroot=$docroot $src_domain -> $stg_domain"

    case "$cms" in
        wordpress)  _stg_rewrite_wordpress  "$docroot" "$src_domain" "$stg_domain" "$dbmap" ;;
        prestashop) _stg_rewrite_prestashop "$docroot" "$src_domain" "$stg_domain" "$dbmap" ;;
        laravel)    _stg_rewrite_laravel    "$docroot" "$src_domain" "$stg_domain" "$dbmap" ;;
        joomla)     _stg_rewrite_joomla     "$docroot" "$src_domain" "$stg_domain" "$dbmap" ;;
        estatico|static)
            stg_log "INFO" "rewrite: sitio estatico, sin BBDD; solo se aplica noindex." ;;
        *)
            stg_log "WARN" "rewrite: CMS no reconocido '$cms'; se aplica solo noindex." ;;
    esac

    # noindex siempre que proceda, independientemente del CMS.
    _stg_apply_noindex "$docroot"

    # Reajusta propietario de los ficheros de config tocados al usuario del docroot.
    local owner; owner="$(stat -c '%U' "$docroot" 2>/dev/null || echo '')"
    if [ -n "$owner" ] && [ "$owner" != "root" ]; then
        chown -R "$owner":"$owner" "$docroot" 2>/dev/null || true
    fi

    stg_log "INFO" "rewrite: reescritura de staging completada para '$stg_domain'."
    return 0
}

# Ejecucion directa.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    set -euo pipefail
    [ $# -ge 4 ] || stg_die "Uso: rewrite.sh <cms> <docroot> <src_domain> <stg_domain> [db_map]"
    stg_rewrite "$1" "$2" "$3" "$4" "${5:-}"
fi
