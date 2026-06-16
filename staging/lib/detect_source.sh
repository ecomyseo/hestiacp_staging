#!/bin/bash
# detect_source.sh - Deteccion y lectura del entorno origen de un dominio.
# Dado un dominio, recolecta: usuario propietario, ruta public_html, version PHP,
# bases de datos asociadas (parseando wp-config.php / .env / settings.inc.php),
# SSL activo, registros DNS, CMS detectado, tamano y comprobacion de cuota.
# Salida: un manifiesto KEY=VALUE por stdout (apto para 'source' / parseo).
#
# Uso:    detect_source.sh <domain>
# Tambien puede sourcearse y llamar stg_detect_source <domain>.

# Carga la libreria nucleo si no esta cargada.
if [ -z "${STG_ROOT:-}" ] || ! declare -F stg_log >/dev/null 2>&1; then
    _ds_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
    # shellcheck source=/dev/null
    . "$_ds_dir/common.sh"
fi

# ---------------------------------------------------------------------------
# _stg_kv KEY VALUE -> imprime una linea del manifiesto, escapando comillas.
# ---------------------------------------------------------------------------
_stg_kv() {
    local key="$1"; shift
    local val="$*"
    # Escapa comillas simples para que el manifiesto sea sourceable de forma segura.
    val="${val//\'/\'\\\'\'}"
    printf "%s='%s'\n" "$key" "$val"
}

# ---------------------------------------------------------------------------
# stg_find_domain_owner DOMAIN -> imprime el usuario propietario o vacio.
# Intenta v-search-domain-owner; si no existe, parsea data/users/*/web.conf.
# ---------------------------------------------------------------------------
stg_find_domain_owner() {
    local domain="$1"
    local owner=""
    if [ -x "$STG_VBIN/v-search-domain-owner" ]; then
        owner="$("$STG_VBIN/v-search-domain-owner" "$domain" 'web' 2>/dev/null | head -n 1 | tr -d '[:space:]')"
    fi
    if [ -z "$owner" ]; then
        local users_dir="$HESTIA/data/users"
        if [ -d "$users_dir" ]; then
            local f
            for f in "$users_dir"/*/web.conf; do
                [ -f "$f" ] || continue
                if grep -qE "DOMAIN='${domain}'" "$f" 2>/dev/null; then
                    owner="$(basename "$(dirname "$f")")"
                    break
                fi
            done
        fi
    fi
    printf '%s' "$owner"
}

# ---------------------------------------------------------------------------
# _stg_webconf_field USER DOMAIN FIELD -> lee un campo del bloque del dominio
# en data/users/<user>/web.conf (formato lineas FIELD='value').
# ---------------------------------------------------------------------------
_stg_webconf_field() {
    local user="$1"; local domain="$2"; local field="$3"
    local f="$HESTIA/data/users/$user/web.conf"
    [ -f "$f" ] || return 0
    grep -E "DOMAIN='${domain}'" "$f" 2>/dev/null | head -n 1 | \
        grep -oE "${field}='[^']*'" | head -n 1 | sed "s/^${field}='//; s/'$//"
}

# ---------------------------------------------------------------------------
# stg_detect_cms DOCROOT -> imprime wordpress|prestashop|laravel|joomla|estatico
# ---------------------------------------------------------------------------
stg_detect_cms() {
    local docroot="$1"
    if [ -f "$docroot/wp-config.php" ] || [ -f "$docroot/wp-load.php" ]; then
        printf 'wordpress'; return 0
    fi
    if [ -f "$docroot/config/settings.inc.php" ] || [ -d "$docroot/app/AppKernel.php" ] || [ -f "$docroot/app/config/parameters.php" ]; then
        printf 'prestashop'; return 0
    fi
    if [ -f "$docroot/artisan" ] && [ -f "$docroot/.env" ]; then
        printf 'laravel'; return 0
    fi
    if [ -f "$docroot/configuration.php" ] && grep -q 'JConfig' "$docroot/configuration.php" 2>/dev/null; then
        printf 'joomla'; return 0
    fi
    printf 'estatico'
}

# ---------------------------------------------------------------------------
# _stg_php_quote_val FILE 'pattern' -> extrae el valor entre comillas de una
# definicion tipo define('NAME', 'valor'); o $var = 'valor'; en un fichero PHP.
# Recibe un patron de grep para localizar la linea y devuelve el ultimo literal
# entre comillas de esa linea.
# ---------------------------------------------------------------------------
_stg_php_quote_val() {
    local file="$1"; local pattern="$2"
    [ -f "$file" ] || return 0
    grep -E "$pattern" "$file" 2>/dev/null | head -n 1 | \
        grep -oE "['\"][^'\"]*['\"]" | tail -n 1 | sed "s/^['\"]//; s/['\"]$//"
}

# ---------------------------------------------------------------------------
# stg_detect_dbs CMS DOCROOT -> imprime las BBDD detectadas, una por linea,
# en formato engine|dbname|dbuser|dbhost. engine = mysql|pgsql.
# Parsea wp-config.php / .env / settings.inc.php segun el CMS.
# ---------------------------------------------------------------------------
stg_detect_dbs() {
    local cms="$1"; local docroot="$2"
    case "$cms" in
        wordpress)
            local cfg="$docroot/wp-config.php"
            [ -f "$cfg" ] || return 0
            local name user host
            name="$(_stg_php_quote_val "$cfg" "define\\(\\s*['\"]DB_NAME['\"]")"
            user="$(_stg_php_quote_val "$cfg" "define\\(\\s*['\"]DB_USER['\"]")"
            host="$(_stg_php_quote_val "$cfg" "define\\(\\s*['\"]DB_HOST['\"]")"
            [ -n "$name" ] && printf 'mysql|%s|%s|%s\n' "$name" "$user" "${host:-localhost}"
            ;;
        prestashop)
            local cfg="$docroot/config/settings.inc.php"
            local pcfg="$docroot/app/config/parameters.php"
            local name user host engine='mysql'
            if [ -f "$cfg" ]; then
                name="$(_stg_php_quote_val "$cfg" "_DB_NAME_")"
                user="$(_stg_php_quote_val "$cfg" "_DB_USER_")"
                host="$(_stg_php_quote_val "$cfg" "_DB_SERVER_")"
            elif [ -f "$pcfg" ]; then
                name="$(_stg_php_quote_val "$pcfg" "'database_name'")"
                user="$(_stg_php_quote_val "$pcfg" "'database_user'")"
                host="$(_stg_php_quote_val "$pcfg" "'database_host'")"
            fi
            [ -n "$name" ] && printf '%s|%s|%s|%s\n' "$engine" "$name" "$user" "${host:-localhost}"
            ;;
        laravel)
            local env="$docroot/.env"
            [ -f "$env" ] || return 0
            local conn name user host engine='mysql'
            conn="$(grep -E '^DB_CONNECTION=' "$env" 2>/dev/null | head -n 1 | cut -d= -f2- | tr -d '"'"'"' [:space:]')"
            name="$(grep -E '^DB_DATABASE='   "$env" 2>/dev/null | head -n 1 | cut -d= -f2- | tr -d '\042\047')"
            user="$(grep -E '^DB_USERNAME='   "$env" 2>/dev/null | head -n 1 | cut -d= -f2- | tr -d '\042\047')"
            host="$(grep -E '^DB_HOST='       "$env" 2>/dev/null | head -n 1 | cut -d= -f2- | tr -d '\042\047')"
            case "$conn" in
                pgsql|postgres|postgresql) engine='pgsql' ;;
                *) engine='mysql' ;;
            esac
            [ -n "$name" ] && printf '%s|%s|%s|%s\n' "$engine" "$name" "$user" "${host:-127.0.0.1}"
            ;;
        joomla)
            local cfg="$docroot/configuration.php"
            [ -f "$cfg" ] || return 0
            local name user host
            name="$(_stg_php_quote_val "$cfg" "\\\$db\\s*=")"
            user="$(_stg_php_quote_val "$cfg" "\\\$user\\s*=")"
            host="$(_stg_php_quote_val "$cfg" "\\\$host\\s*=")"
            [ -n "$name" ] && printf 'mysql|%s|%s|%s\n' "$name" "$user" "${host:-localhost}"
            ;;
        *)
            return 0
            ;;
    esac
}

# ---------------------------------------------------------------------------
# stg_dir_size_bytes DIR -> tamano en bytes (0 si no existe).
# ---------------------------------------------------------------------------
stg_dir_size_bytes() {
    local dir="$1"
    [ -d "$dir" ] || { printf '0'; return 0; }
    du -sb "$dir" 2>/dev/null | awk '{print $1}' | head -n 1
}

# ---------------------------------------------------------------------------
# stg_detect_source DOMAIN -> imprime el manifiesto KEY=VALUE del origen.
# Es la funcion principal del modulo.
# ---------------------------------------------------------------------------
stg_detect_source() {
    local domain="$1"
    [ -n "$domain" ] || stg_die "stg_detect_source: dominio vacio"

    stg_log "INFO" "Detectando origen del dominio '$domain'."

    local owner
    owner="$(stg_find_domain_owner "$domain")"
    [ -n "$owner" ] || stg_die "No se encontro el propietario del dominio '$domain'. Verifica que existe en HestiaCP."

    # Ruta public_html. HestiaCP usa /home/<user>/web/<domain>/public_html.
    local docroot="/home/$owner/web/$domain/public_html"
    local custom_docroot
    custom_docroot="$(_stg_webconf_field "$owner" "$domain" 'CUSTOM_DOCROOT')"
    [ -n "$custom_docroot" ] && docroot="$custom_docroot"

    # Version PHP: campo BACKEND (php-fpm-X.Y) o TPL en web.conf.
    local backend php_ver
    backend="$(_stg_webconf_field "$owner" "$domain" 'BACKEND')"
    php_ver="$(printf '%s' "$backend" | grep -oE '[0-9]+\.[0-9]+' | head -n 1)"
    if [ -z "$php_ver" ]; then
        local tpl
        tpl="$(_stg_webconf_field "$owner" "$domain" 'PROXY_SYSTEM')"
        php_ver="$(printf '%s' "$tpl" | grep -oE '[0-9]+\.[0-9]+' | head -n 1)"
    fi

    # SSL activo.
    local ssl
    ssl="$(_stg_webconf_field "$owner" "$domain" 'SSL')"
    [ -z "$ssl" ] && ssl='no'

    # Alias / dominios extra.
    local aliases
    aliases="$(_stg_webconf_field "$owner" "$domain" 'ALIAS')"

    # CMS y BBDD.
    local cms
    cms="$(stg_detect_cms "$docroot")"

    local dbs
    dbs="$(stg_detect_dbs "$cms" "$docroot" | paste -sd ';' -)"
    local db_count=0
    if [ -n "$dbs" ]; then
        db_count="$(printf '%s' "$dbs" | tr ';' '\n' | grep -c '.')"
    fi

    # DNS: comprueba si HestiaCP gestiona la zona del dominio.
    local dns_local='no'
    if [ -f "$HESTIA/data/users/$owner/dns.conf" ]; then
        if grep -qE "DOMAIN='${domain}'" "$HESTIA/data/users/$owner/dns.conf" 2>/dev/null; then
            dns_local='yes'
        fi
    fi
    # Registro A actual resuelto (informativo, no bloqueante).
    local dns_a=''
    if command -v dig >/dev/null 2>&1; then
        dns_a="$(dig +short A "$domain" 2>/dev/null | head -n 1)"
    elif command -v host >/dev/null 2>&1; then
        dns_a="$(host -t A "$domain" 2>/dev/null | awk '/has address/{print $NF; exit}')"
    fi

    # Tamano de ficheros.
    local size_bytes size_human
    size_bytes="$(stg_dir_size_bytes "$docroot")"
    case "$size_bytes" in ''|*[!0-9]*) size_bytes=0 ;; esac
    size_human="$(numfmt --to=iec "$size_bytes" 2>/dev/null || printf '%s' "$size_bytes")"

    # Comprobacion de cuota: espacio disponible en el filesystem de /home.
    local fs_avail_kb fs_avail_bytes quota_ok='unknown'
    fs_avail_kb="$(df -Pk /home 2>/dev/null | awk 'NR==2{print $4}')"
    case "$fs_avail_kb" in ''|*[!0-9]*) fs_avail_kb=0 ;; esac
    fs_avail_bytes=$(( fs_avail_kb * 1024 ))
    if [ "$fs_avail_bytes" -gt 0 ]; then
        # Margen de seguridad: el staging copia ficheros + dumps de BBDD (~ x1.5).
        local needed=$(( size_bytes + size_bytes / 2 ))
        if [ "$fs_avail_bytes" -ge "$needed" ]; then
            quota_ok='yes'
        else
            quota_ok='no'
        fi
    fi

    # Cuota del paquete del usuario (DISK_QUOTA, en MB) si esta disponible.
    local user_quota_mb=''
    if [ -f "$HESTIA/data/users/$owner/user.conf" ]; then
        user_quota_mb="$(grep -oE "DISK_QUOTA='[^']*'" "$HESTIA/data/users/$owner/user.conf" 2>/dev/null | head -n 1 | sed "s/DISK_QUOTA='//; s/'$//")"
    fi

    # Manifiesto.
    _stg_kv SOURCE_DOMAIN   "$domain"
    _stg_kv SOURCE_USER     "$owner"
    _stg_kv SOURCE_DOCROOT  "$docroot"
    _stg_kv SOURCE_PHP      "$php_ver"
    _stg_kv SOURCE_SSL      "$ssl"
    _stg_kv SOURCE_ALIASES  "$aliases"
    _stg_kv SOURCE_CMS      "$cms"
    _stg_kv SOURCE_DBS      "$dbs"
    _stg_kv SOURCE_DB_COUNT "$db_count"
    _stg_kv SOURCE_DNS_LOCAL "$dns_local"
    _stg_kv SOURCE_DNS_A    "$dns_a"
    _stg_kv SOURCE_SIZE_BYTES "$size_bytes"
    _stg_kv SOURCE_SIZE_HUMAN "$size_human"
    _stg_kv SOURCE_FS_AVAIL_BYTES "$fs_avail_bytes"
    _stg_kv SOURCE_QUOTA_OK  "$quota_ok"
    _stg_kv SOURCE_USER_QUOTA_MB "$user_quota_mb"

    stg_log "INFO" "Origen '$domain': user=$owner cms=$cms php=${php_ver:-?} dbs=$db_count size=$size_human quota_ok=$quota_ok"
    return 0
}

# Ejecucion directa: emite el manifiesto por stdout.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    set -euo pipefail
    [ $# -ge 1 ] || stg_die "Uso: detect_source.sh <domain>"
    stg_detect_source "$1"
fi
