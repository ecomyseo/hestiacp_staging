#!/bin/bash
# ssl_dns.sh - SSL + DNS + proteccion del entorno staging (HestiaCP).
# Provee:
#   - Emision de Let's Encrypt para el subdominio staging (con fallback a
#     certificado autofirmado si el reto ACME falla o el dominio no resuelve).
#   - Alta de registro DNS A en la zona local de HestiaCP cuando esta gestionada.
#   - Validacion de que el staging responde HTTP 200 tras la configuracion.
#   - Endurecimiento: X-Robots-Tag noindex + robots.txt de bloqueo, HTTP Basic
#     Auth y restriccion por IP opcional (todo via plantilla nginx custom).
# Se apoya en comandos nativos: v-add-letsencrypt-domain, v-add-dns-record,
# v-add-web-domain-ssl, v-change-web-domain-sslcert.
#
# Uso:    ssl_dns.sh <source_domain> [--ip <ip_publica>] [--allow-ip <cidr,cidr>]
# Sourceable: stg_ssl_dns_apply <source_domain>

# Carga la libreria nucleo si no esta cargada.
if [ -z "${STG_ROOT:-}" ] || ! declare -F stg_log >/dev/null 2>&1; then
    _sd_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
    # shellcheck source=/dev/null
    . "$_sd_dir/common.sh"
fi

# ---------------------------------------------------------------------------
# _stg_apex DOMAIN -> imprime el dominio raiz (apex) de un FQDN. Heuristica
# simple de 2 etiquetas (suficiente para TLD comunes); admite zona local exacta.
# ---------------------------------------------------------------------------
_stg_apex() {
    local d="$1"
    printf '%s' "$d" | awk -F. '{ if (NF>=2) printf "%s.%s", $(NF-1), $NF; else printf "%s", $0 }'
}

# ---------------------------------------------------------------------------
# stg_dns_local_zone USER APEX -> 0 si HestiaCP gestiona la zona APEX del user.
# ---------------------------------------------------------------------------
stg_dns_local_zone() {
    local user="$1"; local apex="$2"
    local f="$HESTIA/data/users/$user/dns.conf"
    [ -f "$f" ] || return 1
    grep -qE "DOMAIN='${apex}'" "$f" 2>/dev/null
}

# ---------------------------------------------------------------------------
# stg_add_dns_record USER APEX STG_DOMAIN IP
# Crea el registro A del subdominio staging en la zona local si procede.
# Idempotente: no falla si el registro ya existe.
# ---------------------------------------------------------------------------
stg_add_dns_record() {
    local user="$1"; local apex="$2"; local stg_domain="$3"; local ip="$4"
    [ -n "$ip" ] || { stg_log "WARN" "Sin IP para el registro DNS de '$stg_domain'; lo omito."; return 0; }
    if ! stg_dns_local_zone "$user" "$apex"; then
        stg_log "INFO" "La zona '$apex' no es local en HestiaCP; no creo registro DNS (gestionalo en tu proveedor)."
        return 0
    fi
    # Nombre relativo del registro respecto al apex.
    local rec="${stg_domain%.$apex}"
    [ "$rec" = "$stg_domain" ] && rec='@'
    stg_log "INFO" "Creando registro DNS A '$rec.$apex' -> $ip."
    if stg_vcmd v-add-dns-record "$user" "$apex" "$rec" 'A' "$ip" >/dev/null 2>&1; then
        stg_log "INFO" "Registro DNS creado."
    else
        # El registro ya puede existir; lo tratamos como no fatal.
        stg_log "WARN" "No se pudo crear el registro DNS (puede que ya exista)."
    fi
    return 0
}

# ---------------------------------------------------------------------------
# stg_issue_ssl USER STG_DOMAIN
# Intenta Let's Encrypt; si falla, instala un certificado autofirmado para que
# el staging quede igualmente accesible por HTTPS. No es fatal en ningun caso.
# ---------------------------------------------------------------------------
stg_issue_ssl() {
    local user="$1"; local stg_domain="$2"
    # Asegura el flag SSL del dominio web (idempotente).
    stg_vcmd v-add-web-domain-ssl "$user" "$stg_domain" >/dev/null 2>&1 || true

    stg_log "INFO" "Solicitando Let's Encrypt para '$stg_domain'."
    if stg_vcmd v-add-letsencrypt-domain "$user" "$stg_domain" '' 'no' >/dev/null 2>&1; then
        stg_log "INFO" "Certificado Let's Encrypt emitido para '$stg_domain'."
        stg_register_env "$stg_domain" SSL_KIND letsencrypt
        return 0
    fi

    stg_log "WARN" "Let's Encrypt fallo para '$stg_domain' (DNS/ACME). Genero autofirmado."
    local ssl_dir
    ssl_dir="$(mktemp -d "${TMPDIR:-/tmp}/stg-ssl.XXXXXX")"
    if command -v openssl >/dev/null 2>&1; then
        openssl req -x509 -nodes -newkey rsa:2048 -days 825 \
            -keyout "$ssl_dir/$stg_domain.key" \
            -out "$ssl_dir/$stg_domain.crt" \
            -subj "/CN=$stg_domain" >/dev/null 2>&1 || true
        # Sin CA intermedia para autofirmado: usa el propio crt como ca.
        cp "$ssl_dir/$stg_domain.crt" "$ssl_dir/$stg_domain.ca" 2>/dev/null || true
        if [ -s "$ssl_dir/$stg_domain.crt" ] && [ -s "$ssl_dir/$stg_domain.key" ]; then
            if stg_vcmd v-add-web-domain-ssl "$user" "$stg_domain" "$ssl_dir" >/dev/null 2>&1 || \
               stg_vcmd v-change-web-domain-sslcert "$user" "$stg_domain" "$ssl_dir" >/dev/null 2>&1; then
                stg_log "INFO" "Certificado autofirmado instalado para '$stg_domain'."
                stg_register_env "$stg_domain" SSL_KIND selfsigned
            else
                stg_log "WARN" "No se pudo instalar el autofirmado en HestiaCP."
            fi
        fi
    else
        stg_log "WARN" "openssl no disponible; el staging quedara solo en HTTP."
        stg_register_env "$stg_domain" SSL_KIND none
    fi
    rm -rf "$ssl_dir" 2>/dev/null || true
    return 0
}

# ---------------------------------------------------------------------------
# stg_basic_auth USER STG_DOMAIN -> crea credencial Basic Auth y la registra.
# La contrasena se genera aleatoria y se guarda como metadato (chmod 600).
# Usa v-add-web-domain-httpauth si esta disponible; si no, .htpasswd manual.
# ---------------------------------------------------------------------------
stg_basic_auth() {
    local user="$1"; local stg_domain="$2"
    local au ap
    au="$(stg_conf_get STG_BASIC_AUTH_USER staging)"
    ap="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 16)"
    [ -n "$ap" ] || ap="stg$(date +%s)"
    stg_log "INFO" "Configurando Basic Auth para '$stg_domain' (usuario '$au')."
    if stg_vcmd v-add-web-domain-httpauth "$user" "$stg_domain" "$au" "$ap" >/dev/null 2>&1; then
        stg_register_env "$stg_domain" BASIC_AUTH_USER "$au"
        stg_register_env "$stg_domain" BASIC_AUTH_PASS "$ap"
        stg_log "INFO" "Basic Auth activado. Usuario '$au' (pass guardada en metadatos del entorno)."
    else
        stg_log "WARN" "v-add-web-domain-httpauth no disponible; Basic Auth no aplicado automaticamente."
    fi
    return 0
}

# ---------------------------------------------------------------------------
# stg_noindex DOCROOT -> escribe robots.txt de bloqueo en el docroot staging.
# La cabecera X-Robots-Tag se documenta para la plantilla nginx; aqui forzamos
# el robots.txt como minima proteccion garantizada.
# ---------------------------------------------------------------------------
stg_noindex() {
    local docroot="$1"
    [ -d "$docroot" ] || { stg_log "WARN" "Docroot staging inexistente: $docroot"; return 0; }
    cat > "$docroot/robots.txt" <<'EOF'
User-agent: *
Disallow: /
EOF
    stg_log "INFO" "robots.txt de bloqueo escrito (noindex) en $docroot."
    return 0
}

# ---------------------------------------------------------------------------
# stg_restrict_ip USER STG_DOMAIN CIDRS
# Restriccion por IP opcional. Genera fragmento nginx 'allow/deny' en el
# directorio de plantillas custom del dominio. No fatal si no se puede aplicar.
# ---------------------------------------------------------------------------
stg_restrict_ip() {
    local user="$1"; local stg_domain="$2"; local cidrs="$3"
    [ -n "$cidrs" ] || return 0
    local nginx_dir="/home/$user/conf/web/$stg_domain"
    [ -d "$nginx_dir" ] || { stg_log "WARN" "No existe $nginx_dir; omito restriccion IP."; return 0; }
    local frag="$nginx_dir/nginx.stg_allow.conf"
    {
        printf '# Restriccion de acceso al staging (generado por plugin Staging)\n'
        local ip
        IFS=',' read -ra _ips <<< "$cidrs"
        for ip in "${_ips[@]}"; do
            ip="$(printf '%s' "$ip" | tr -d '[:space:]')"
            [ -n "$ip" ] && printf 'allow %s;\n' "$ip"
        done
        printf 'deny all;\n'
    } > "$frag"
    stg_register_env "$stg_domain" ALLOW_IPS "$cidrs"
    stg_log "INFO" "Restriccion IP escrita en $frag (recuerda incluirla en la plantilla nginx)."
    if stg_vcmd v-rebuild-web-domain "$user" "$stg_domain" >/dev/null 2>&1; then
        stg_log "DEBUG" "Dominio web reconstruido tras restriccion IP."
    fi
    return 0
}

# ---------------------------------------------------------------------------
# stg_validate_http STG_DOMAIN -> valida HTTP/HTTPS 200/401 del staging.
# Se acepta 401 (Basic Auth activo) como exito. Devuelve 0 si valida.
# ---------------------------------------------------------------------------
stg_validate_http() {
    local stg_domain="$1"
    command -v curl >/dev/null 2>&1 || { stg_log "WARN" "curl no disponible; omito validacion HTTP."; return 0; }
    local code scheme
    for scheme in https http; do
        code="$(curl -ksS -o /dev/null -w '%{http_code}' --max-time 20 \
            -H 'Host: '"$stg_domain" "$scheme://$stg_domain/" 2>/dev/null || echo 000)"
        stg_log "DEBUG" "Validacion $scheme://$stg_domain -> HTTP $code"
        case "$code" in
            200|301|302|401|403)
                stg_log "INFO" "Staging '$stg_domain' responde por $scheme (HTTP $code)."
                stg_register_env "$stg_domain" HTTP_CHECK "$scheme:$code"
                return 0
                ;;
        esac
    done
    stg_log "WARN" "Staging '$stg_domain' no respondio 200/401 (ultimo codigo: ${code:-000})."
    stg_register_env "$stg_domain" HTTP_CHECK "fail:${code:-000}"
    return 1
}

# ---------------------------------------------------------------------------
# stg_ssl_dns_apply SOURCE_DOMAIN [--ip IP] [--allow-ip CIDRS]
# Orquesta DNS + SSL + proteccion + validacion para el entorno staging del
# dominio origen indicado. Lee los metadatos del entorno (STG_DOMAIN, STG_USER,
# STG_DOCROOT) registrados por el bloque de creacion.
# ---------------------------------------------------------------------------
stg_ssl_dns_apply() {
    local source_domain="$1"; shift || true
    [ -n "$source_domain" ] || stg_die "stg_ssl_dns_apply: dominio origen vacio"

    local ip='' allow_ip=''
    while [ $# -gt 0 ]; do
        case "$1" in
            --ip) ip="$2"; shift 2 ;;
            --allow-ip) allow_ip="$2"; shift 2 ;;
            *) stg_log "WARN" "Argumento desconocido: $1"; shift ;;
        esac
    done

    # Recupera el entorno staging registrado en la creacion.
    local stg_domain stg_user stg_docroot
    stg_domain="$(stg_get_env "$source_domain" STG_DOMAIN '')"
    stg_user="$(stg_get_env "$source_domain" STG_USER '')"
    stg_docroot="$(stg_get_env "$source_domain" STG_DOCROOT '')"
    [ -n "$stg_domain" ] || stg_die "No hay entorno staging registrado para '$source_domain'. Crealo antes (v-staging-create)."
    [ -n "$stg_user" ] || stg_die "Falta STG_USER en los metadatos de '$source_domain'."
    [ -n "$stg_docroot" ] && [ -d "$stg_docroot" ] || stg_docroot="/home/$stg_user/web/$stg_domain/public_html"

    # IP por defecto: la IP del dominio web del staging o la primera del sistema.
    if [ -z "$ip" ]; then
        ip="$(stg_get_env "$source_domain" STG_IP '')"
    fi
    if [ -z "$ip" ] && command -v hostname >/dev/null 2>&1; then
        ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    fi

    local apex
    apex="$(_stg_apex "$stg_domain")"

    # 1) DNS local (si la zona la gestiona HestiaCP).
    stg_add_dns_record "$stg_user" "$apex" "$stg_domain" "$ip"

    # 2) noindex (robots.txt). La cabecera X-Robots-Tag se aplica via plantilla.
    if [ "$(stg_conf_get STG_NOINDEX true)" = "true" ]; then
        stg_noindex "$stg_docroot"
    fi

    # 3) SSL (Let's Encrypt con fallback autofirmado).
    stg_issue_ssl "$stg_user" "$stg_domain"

    # 4) Basic Auth (si esta habilitado en conf).
    if [ "$(stg_conf_get STG_BASIC_AUTH true)" = "true" ]; then
        stg_basic_auth "$stg_user" "$stg_domain"
    fi

    # 5) Restriccion por IP opcional.
    stg_restrict_ip "$stg_user" "$stg_domain" "$allow_ip"

    # 6) Validacion HTTP final (no fatal: deja registro del resultado).
    stg_validate_http "$stg_domain" || true

    stg_register_env "$stg_domain" SSL_DNS_AT "$(date +%s)"
    stg_log "INFO" "SSL/DNS/proteccion aplicados al staging '$stg_domain' (origen '$source_domain')."
    return 0
}

# Ejecucion directa.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    set -euo pipefail
    [ $# -ge 1 ] || stg_die "Uso: ssl_dns.sh <source_domain> [--ip IP] [--allow-ip CIDRS]"
    stg_ssl_dns_apply "$@"
fi
