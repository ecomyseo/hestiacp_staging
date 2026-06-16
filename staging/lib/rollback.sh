#!/bin/bash
# rollback.sh - Rollback de un push-to-live (HestiaCP).
# Restaura produccion EXACTAMENTE como estaba antes del push. Dos modos:
#   --auto : invocado por push_live.sh cuando un paso falla (rollback rapido
#            basado en los artefactos del propio push: .stgold + backup config).
#   manual : el operador lo lanza despues; restaura desde .stgold/credenciales y,
#            si no estan, desde el backup live completo (v-restore-user).
#
# Estrategia de restauracion (idempotente, defensiva):
#   1) Ficheros: si existe <docroot>.stgold, swap atomico inverso. Si no, se
#      restaura el docroot desde el backup live.
#   2) BBDD: revierte las credenciales del CMS al fichero de config respaldado
#      (PUSH_CFG_BAK). La BD anterior de produccion no se borro en el push, por
#      lo que apuntar de nuevo a ella deja el sitio como estaba.
#   3) Auditoria completa.
#
# Uso:  STG_CONFIRM=<source_domain> rollback.sh <source_domain> [--auto]
# Sourceable: stg_rollback <source_domain> [--auto]

if [ -z "${STG_ROOT:-}" ] || ! declare -F stg_log >/dev/null 2>&1; then
    _rb_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
    # shellcheck source=/dev/null
    . "$_rb_dir/common.sh"
fi

# ---------------------------------------------------------------------------
# stg_rollback_files SOURCE_DOMAIN -> restaura el docroot de produccion desde
# <docroot>.stgold (swap atomico inverso). Devuelve 0 si lo hizo, 1 si no habia.
# ---------------------------------------------------------------------------
stg_rollback_files() {
    local source_domain="$1"
    local src_user src_docroot olddir
    src_user="$(stg_get_env "$source_domain" SOURCE_USER '')"
    src_docroot="$(stg_get_env "$source_domain" SOURCE_DOCROOT '')"
    olddir="$(stg_get_env "$source_domain" PUSH_OLDDIR '')"
    [ -n "$src_docroot" ] || src_docroot="/home/$src_user/web/$source_domain/public_html"
    [ -n "$olddir" ] || olddir="$src_docroot.stgold"

    if [ ! -d "$olddir" ]; then
        stg_log "WARN" "No existe la copia anterior de ficheros ($olddir)."
        return 1
    fi
    stg_log "INFO" "Restaurando ficheros de produccion desde $olddir (swap inverso)."
    # Aparta el docroot actual (el promovido) y recoloca el anterior.
    local cur_bak="$src_docroot.stgpushed.$(date +%s)"
    if [ -d "$src_docroot" ]; then
        mv -f "$src_docroot" "$cur_bak" 2>/dev/null || { stg_log "ERROR" "No se pudo apartar el docroot actual."; return 1; }
    fi
    if mv -f "$olddir" "$src_docroot" 2>/dev/null; then
        stg_log "INFO" "Ficheros de produccion restaurados. Copia promovida en $cur_bak."
        return 0
    fi
    # Si falla, intenta dejar el promovido de vuelta para no quedar sin docroot.
    [ -d "$cur_bak" ] && mv -f "$cur_bak" "$src_docroot" 2>/dev/null || true
    stg_log "ERROR" "No se pudo restaurar ficheros desde $olddir."
    return 1
}

# ---------------------------------------------------------------------------
# stg_rollback_db SOURCE_DOMAIN -> restaura el fichero de config del CMS desde
# PUSH_CFG_BAK (vuelve a apuntar a la BD anterior, que no se borro). Devuelve 0/1.
# ---------------------------------------------------------------------------
stg_rollback_db() {
    local source_domain="$1"
    local cfg bak
    cfg="$(stg_get_env "$source_domain" PUSH_CFG '')"
    bak="$(stg_get_env "$source_domain" PUSH_CFG_BAK '')"
    if [ -z "$cfg" ] || [ -z "$bak" ] || [ ! -f "$bak" ]; then
        stg_log "WARN" "No hay backup de credenciales de BD que restaurar (PUSH_CFG_BAK)."
        return 1
    fi
    if cp -f "$bak" "$cfg" 2>/dev/null; then
        stg_log "INFO" "Credenciales de BD de produccion restauradas en $cfg."
        return 0
    fi
    stg_log "ERROR" "No se pudo restaurar credenciales de BD en $cfg."
    return 1
}

# ---------------------------------------------------------------------------
# stg_rollback_from_backup SOURCE_DOMAIN -> ultima red: restaura el usuario de
# produccion completo desde el backup live registrado (v-restore-user).
# OPERACION fuerte: solo se usa si no hay artefactos de swap. Exige el backup.
# ---------------------------------------------------------------------------
stg_rollback_from_backup() {
    local source_domain="$1"
    local src_user path
    src_user="$(stg_get_env "$source_domain" SOURCE_USER '')"
    path="$(stg_get_env "$source_domain" LIVE_BACKUP_PATH '')"
    [ -n "$src_user" ] || { stg_log "ERROR" "Sin usuario de produccion para restore."; return 1; }
    if [ -z "$path" ] || [ ! -e "$path" ]; then
        stg_log "ERROR" "Backup live no disponible en disco ($path); no se puede restaurar por backup."
        return 1
    fi
    local fname
    fname="$(basename "$path")"
    stg_log "INFO" "Restaurando produccion desde backup live completo: $fname (v-restore-user)."
    if stg_vcmd v-restore-user "$src_user" "$fname" >/dev/null 2>&1; then
        stg_log "INFO" "Restore completo del usuario '$src_user' realizado."
        return 0
    fi
    stg_log "ERROR" "v-restore-user fallo para '$src_user' con '$fname'."
    return 1
}

# ---------------------------------------------------------------------------
# stg_rollback SOURCE_DOMAIN [--auto]
# Punto de entrada. En modo manual exige confirmacion (stg_confirm). En --auto
# (llamado desde push_live ante un fallo) NO vuelve a pedir confirmacion porque
# el push ya estaba autorizado y debe revertirse de inmediato.
# ---------------------------------------------------------------------------
stg_rollback() {
    local source_domain="$1"; shift || true
    [ -n "$source_domain" ] || stg_die "stg_rollback: dominio origen vacio"

    local auto=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --auto) auto=1; shift ;;
            *) stg_log "WARN" "Argumento desconocido en rollback: $1"; shift ;;
        esac
    done

    stg_audit "$source_domain" rollback start "auto=$auto"

    # En modo manual exigimos confirmacion explicita (destructivo sobre prod).
    if [ "$auto" -eq 0 ]; then
        stg_confirm "$source_domain"
    fi

    local src_user
    src_user="$(stg_get_env "$source_domain" SOURCE_USER '')"

    # 1) Intento rollback por artefactos del swap (rapido, exacto).
    local files_ok=1 db_ok=1
    stg_rollback_files "$source_domain" || files_ok=0
    stg_rollback_db "$source_domain" || db_ok=0

    # 2) Si no habia artefactos de ficheros, recurrimos al backup live completo.
    #    Solo damos por buena la restauracion si v-restore-user devuelve 0 Y el
    #    docroot resultante contiene ficheros (verificacion explicita). Nunca se
    #    enmascara un fallo de restore como "todo OK".
    if [ "$files_ok" -eq 0 ]; then
        stg_log "WARN" "Sin artefactos de swap de ficheros; intento restore desde backup live."
        if stg_rollback_from_backup "$source_domain"; then
            local rb_docroot
            rb_docroot="$(stg_get_env "$source_domain" SOURCE_DOCROOT '')"
            [ -n "$rb_docroot" ] || rb_docroot="/home/$src_user/web/$source_domain/public_html"
            if [ -d "$rb_docroot" ] && [ -n "$(ls -A "$rb_docroot" 2>/dev/null)" ]; then
                stg_log "INFO" "Docroot '$rb_docroot' restaurado y no vacio tras backup live."
                files_ok=1; db_ok=1
            else
                stg_log "ERROR" "v-restore-user no dejo ficheros en '$rb_docroot'; restauracion NO verificada."
            fi
        else
            stg_log "ERROR" "Restore desde backup live fallo; los ficheros NO fueron restaurados."
        fi
    fi

    # Reconstruye y valida produccion.
    if [ -n "$src_user" ]; then
        stg_vcmd v-rebuild-web-domain "$src_user" "$source_domain" >/dev/null 2>&1 || \
            stg_log "WARN" "v-rebuild-web-domain devolvio error durante el rollback."
    fi
    if command -v curl >/dev/null 2>&1; then
        local code
        code="$(curl -ksS -o /dev/null -w '%{http_code}' --max-time 25 "https://$source_domain/" 2>/dev/null || echo 000)"
        stg_log "INFO" "Produccion '$source_domain' responde HTTP $code tras el rollback."
    fi

    if [ "$files_ok" -eq 1 ] && [ "$db_ok" -eq 1 ]; then
        stg_register_env "$source_domain" ROLLBACK_AT "$(date +%s)"
        stg_audit "$source_domain" rollback success "produccion restaurada al estado previo al push"
        stg_log "INFO" "ROLLBACK COMPLETADO para '$source_domain'. Produccion como antes del push."
        echo "ROLLBACK OK para '$source_domain'."
        return 0
    fi

    stg_audit "$source_domain" rollback partial "files_ok=$files_ok db_ok=$db_ok"
    stg_die "ROLLBACK INCOMPLETO para '$source_domain' (files_ok=$files_ok db_ok=$db_ok). Revisa manualmente; el backup live sigue en disco."
}

# Ejecucion directa.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    set -euo pipefail
    [ $# -ge 1 ] || stg_die "Uso: STG_CONFIRM=<domain> rollback.sh <source_domain> [--auto]"
    stg_rollback "$@"
fi
