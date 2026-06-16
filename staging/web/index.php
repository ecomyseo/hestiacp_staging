<?php
/**
 * web/index.php - Interfaz web del plugin Staging para HestiaCP.
 * Lista los dominios del usuario, permite crear un staging (asistente), y por
 * cada staging ofrece Sync / Push / Eliminar. El Push muestra un modal de
 * confirmacion fuerte con checkbox de backup y aviso del kill switch.
 *
 * Seguridad: token CSRF por sesion, escape de TODA la salida (htmlspecialchars),
 * validacion estricta de dominios/usuarios y ejecucion de los comandos v-staging-*
 * mediante escapeshellarg. No ejecuta ninguna accion destructiva sin POST + CSRF.
 *
 * @author    Ecom Experts <ecomyseo@gmail.com>
 * @copyright 2026 Ecom Experts
 * @license   AFL-3.0
 */

/* --------------------------------------------------------------------------
 * Autenticacion del panel HestiaCP (OBLIGATORIA). Esta pagina solo es accesible
 * para el administrador con sesion iniciada. Se integra con la sesion real del
 * panel via inc/main.php (que arranca la sesion correcta y define HESTIA_CMD).
 * Sin esto la UI quedaria abierta y el push-to-live seria accesible sin login.
 * ------------------------------------------------------------------------ */
$__hestia_doc = (isset($_SERVER['DOCUMENT_ROOT']) && $_SERVER['DOCUMENT_ROOT'] !== '')
    ? $_SERVER['DOCUMENT_ROOT'] : '/usr/local/hestia/web';
$__hestia_main = $__hestia_doc . '/inc/main.php';
if (is_file($__hestia_main)) {
    require_once $__hestia_main;
}
// Cualquier usuario del panel con sesion iniciada puede gestionar el staging de
// SUS PROPIOS dominios. El administrador ademas puede operar sobre los de todos.
if (empty($_SESSION['user'])) {
    header('Location: /login/');
    exit;
}
$stg_is_admin = (isset($_SESSION['userContext']) && $_SESSION['userContext'] === 'admin');

if (session_status() === PHP_SESSION_NONE) {
    session_start();
}

/* --------------------------------------------------------------------------
 * Rutas base del plugin y de los binarios.
 * ------------------------------------------------------------------------ */
define('STG_WEB_ROOT', dirname(__DIR__));
define('STG_BIN', STG_WEB_ROOT . '/bin');
define('STG_HESTIA', getenv('HESTIA') ?: '/usr/local/hestia');
// El PHP del panel corre como 'hestiaweb' (no root): los comandos se ejecutan via
// sudo sobre los wrappers de /usr/local/hestia/bin (permitido por el sudoers de
// HestiaCP). HESTIA_CMD lo define inc/main.php = "/usr/bin/sudo /usr/local/hestia/bin/".
define('STG_CMD', defined('HESTIA_CMD') ? HESTIA_CMD : '/usr/bin/sudo /usr/local/hestia/bin/');

/* --------------------------------------------------------------------------
 * Identidad del usuario del panel. En HestiaCP el contexto expone el usuario
 * autenticado; aqui lo tomamos de la sesion de Hestia o de un parametro firmado.
 * Para un panel real, $_SESSION['user'] lo fija el login de HestiaCP.
 * ------------------------------------------------------------------------ */
$panel_user = isset($_SESSION['user']) ? (string) $_SESSION['user'] : '';
if ($panel_user === '' && isset($_SERVER['REMOTE_USER'])) {
    $panel_user = (string) $_SERVER['REMOTE_USER'];
}
// Validacion del nombre de usuario (alfanumerico, guion y subrayado).
if ($panel_user !== '' && !preg_match('/^[a-zA-Z0-9._-]+$/', $panel_user)) {
    $panel_user = '';
}

/* --------------------------------------------------------------------------
 * CSRF: genera/recupera el token de sesion.
 * ------------------------------------------------------------------------ */
if (empty($_SESSION['stg_csrf'])) {
    $_SESSION['stg_csrf'] = bin2hex(random_bytes(32));
}
$csrf = $_SESSION['stg_csrf'];

/**
 * Escapa para HTML (UTF-8). Atajo local.
 */
function h($s)
{
    return htmlspecialchars((string) $s, ENT_QUOTES, 'UTF-8');
}

/**
 * Valida un FQDN de forma estricta.
 */
function stg_is_domain($d)
{
    return is_string($d) && $d !== '' && strlen($d) <= 253
        && preg_match('/^(?=.{1,253}$)([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$/', $d);
}

/**
 * Valida un nombre de usuario del panel.
 */
function stg_is_user($u)
{
    return is_string($u) && $u !== '' && preg_match('/^[a-zA-Z0-9._-]{1,64}$/', $u);
}

/**
 * Ejecuta un comando v-staging-* con argumentos ya validados. Devuelve array
 * con 'code', 'out'. Usa escapeshellarg en cada argumento y fuerza salida JSON.
 * Las variables de entorno (STG_CONFIRM) se pasan de forma controlada.
 */
function stg_run($script, array $args = [], array $env = [])
{
    // Lista blanca de comandos propios del plugin (wrappers en /usr/local/hestia/bin).
    static $allowed = [
        'v-staging-create', 'v-staging-sync', 'v-staging-push', 'v-staging-rollback',
        'v-staging-list', 'v-staging-info', 'v-staging-delete', 'v-staging-debug',
    ];
    if (!in_array($script, $allowed, true)) {
        return ['code' => 127, 'out' => 'Comando no permitido: ' . $script];
    }
    // sudo NO propaga el entorno: la confirmacion (STG_CONFIRM) se pasa como flag
    // --confirm <domain>, validada como FQDN (defensa en profundidad). Asi las
    // operaciones destructivas funcionan a traves de sudo desde la UI.
    if (isset($env['STG_CONFIRM']) && stg_is_domain((string) $env['STG_CONFIRM'])) {
        $args[] = '--confirm';
        $args[] = (string) $env['STG_CONFIRM'];
    }
    // Ejecucion via sudo sobre el wrapper del panel (el PHP corre como hestiaweb).
    $cmd = STG_CMD . $script;
    foreach ($args as $a) {
        $cmd .= ' ' . escapeshellarg((string) $a);
    }
    $cmd .= ' --format json 2>&1';

    $output = [];
    $code = 0;
    exec($cmd, $output, $code);
    return ['code' => $code, 'out' => implode("\n", $output)];
}

/**
 * Lista los dominios web del usuario via v-list-web-domains (json nativo Hestia).
 * Devuelve array de dominios (strings). Filtra a los dominios validos.
 */
function stg_list_domains($user)
{
    if (!stg_is_user($user)) {
        return [];
    }
    $cmd = STG_CMD . 'v-list-web-domains ' . escapeshellarg($user) . ' json 2>/dev/null';
    $out = shell_exec($cmd);
    $domains = [];
    if (is_string($out) && $out !== '') {
        $data = json_decode($out, true);
        if (is_array($data)) {
            foreach (array_keys($data) as $d) {
                if (stg_is_domain($d)) {
                    $domains[] = $d;
                }
            }
        }
    }
    sort($domains);
    return $domains;
}

/**
 * Lista todos los usuarios del panel (v-list-users json).
 */
function stg_list_users()
{
    $out = shell_exec(STG_CMD . 'v-list-users json 2>/dev/null');
    $users = [];
    $data = json_decode((string) $out, true);
    if (is_array($data)) {
        foreach (array_keys($data) as $u) {
            if (stg_is_user($u)) {
                $users[] = $u;
            }
        }
    }
    sort($users);
    return $users;
}

/**
 * Lista TODOS los dominios web de TODOS los usuarios. Devuelve domain => owner.
 * Asi el administrador puede clonar cualquier dominio del servidor desde el panel.
 */
function stg_list_all_domains()
{
    $map = [];
    foreach (stg_list_users() as $u) {
        foreach (stg_list_domains($u) as $d) {
            if (!isset($map[$d])) {
                $map[$d] = $u;
            }
        }
    }
    ksort($map);
    return $map;
}

/**
 * Resuelve el usuario propietario de un dominio web. Usa v-search-domain-owner si
 * existe; si no, itera los usuarios. Devuelve '' si no se encuentra.
 */
function stg_domain_owner($domain)
{
    if (!stg_is_domain($domain)) {
        return '';
    }
    $out = trim((string) shell_exec(
        STG_CMD . 'v-search-domain-owner ' . escapeshellarg($domain) . ' web 2>/dev/null'
    ));
    if (stg_is_user($out)) {
        return $out;
    }
    foreach (stg_list_users() as $u) {
        foreach (stg_list_domains($u) as $d) {
            if ($d === $domain) {
                return $u;
            }
        }
    }
    return '';
}

/**
 * Comprueba que un dominio (de produccion o un origen con staging) pertenece al
 * usuario indicado. Evita que un usuario opere sobre dominios de otros.
 */
function stg_user_owns($user, $domain)
{
    if (!stg_is_user($user) || !stg_is_domain($domain)) {
        return false;
    }
    if (in_array($domain, stg_list_domains($user), true)) {
        return true;
    }
    $mine = stg_list_staging($user);
    return isset($mine[$domain]);
}

/**
 * Lista los staging via v-staging-list (json). Si $user es '' lista TODOS.
 * Indexado por dominio de origen.
 */
function stg_list_staging($user)
{
    $args = ($user !== '' && stg_is_user($user)) ? [$user] : [];
    $res = stg_run('v-staging-list', $args);
    $map = [];
    $data = json_decode($res['out'], true);
    if (is_array($data)) {
        foreach ($data as $row) {
            if (isset($row['source_domain'])) {
                $map[$row['source_domain']] = $row;
            }
        }
    }
    return $map;
}

/**
 * Espacio libre (bytes) del filesystem que aloja /home (donde se crea el staging).
 * Devuelve -1 si no se puede determinar.
 */
function stg_disk_free_bytes()
{
    $out = shell_exec('df -Pk /home 2>/dev/null');
    if (is_string($out) && preg_match('/\n\S+\s+\d+\s+\d+\s+(\d+)\s/', $out, $m)) {
        return ((int) $m[1]) * 1024;
    }
    return -1;
}

/** Formatea bytes a unidades legibles (B/KB/MB/GB/TB). */
function stg_hbytes($b)
{
    $b = (float) $b;
    if ($b < 0) {
        return '?';
    }
    $u = array('B', 'KB', 'MB', 'GB', 'TB');
    $i = 0;
    while ($b >= 1024 && $i < count($u) - 1) {
        $b /= 1024;
        $i++;
    }
    return round($b, 1) . ' ' . $u[$i];
}

/* --------------------------------------------------------------------------
 * Manejo de acciones POST (todas requieren CSRF valido).
 * ------------------------------------------------------------------------ */
$notice = '';
$notice_type = 'info';

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $token = isset($_POST['csrf']) ? (string) $_POST['csrf'] : '';
    if (!hash_equals($csrf, $token)) {
        http_response_code(400);
        $notice = 'Token CSRF invalido. Recarga la pagina e intenta de nuevo.';
        $notice_type = 'error';
    } elseif ($panel_user === '') {
        $notice = 'No se pudo determinar el usuario del panel.';
        $notice_type = 'error';
    } else {
        $action = isset($_POST['action']) ? (string) $_POST['action'] : '';
        $source = isset($_POST['source_domain']) ? (string) $_POST['source_domain'] : '';

        if (!stg_is_domain($source)) {
            $notice = 'Dominio invalido.';
            $notice_type = 'error';
        } elseif (!$stg_is_admin && !stg_user_owns($panel_user, $source)) {
            // Seguridad: un usuario no-admin solo opera sobre SUS dominios/staging.
            $notice = 'No tienes permiso sobre el dominio ' . h($source) . '.';
            $notice_type = 'error';
        } else {
            switch ($action) {
                case 'create':
                    $mode = isset($_POST['mode']) ? (string) $_POST['mode'] : 'subdomain';
                    if (!in_array($mode, ['subdomain', 'domain', 'user'], true)) {
                        $mode = 'subdomain';
                    }
                    // Propietario: un no-admin solo puede clonar SUS dominios (forzamos
                    // su usuario); el admin clona cualquiera (se resuelve en servidor).
                    $owner = $stg_is_admin ? stg_domain_owner($source) : $panel_user;
                    if ($owner === '') {
                        $notice = 'No se pudo determinar el usuario propietario de ' . h($source) . '.';
                        $notice_type = 'error';
                        break;
                    }
                    $args = [$owner, $source, '--mode', $mode];
                    $name = isset($_POST['stg_name']) ? trim((string) $_POST['stg_name']) : '';
                    if ($name !== '') {
                        if (!stg_is_domain($name)) {
                            $notice = 'El nombre del dominio de staging no es valido.';
                            $notice_type = 'error';
                            break;
                        }
                        $args[] = '--name';
                        $args[] = $name;
                    } elseif ($mode === 'domain') {
                        $notice = 'El modo "dominio aparte" requiere indicar un nombre de dominio.';
                        $notice_type = 'error';
                        break;
                    }
                    $r = stg_run('v-staging-create', $args);
                    $notice = $r['code'] === 0
                        ? 'Staging creado correctamente para ' . h($source) . '.'
                        : 'Error al crear el staging (codigo ' . (int) $r['code'] . '). ' . h($r['out']);
                    $notice_type = $r['code'] === 0 ? 'ok' : 'error';
                    break;

                case 'sync':
                    $sargs = [$source];
                    $scope = isset($_POST['scope']) ? (string) $_POST['scope'] : 'all';
                    if ($scope === 'files') {
                        $sargs[] = '--files-only';
                    } elseif ($scope === 'db') {
                        $sargs[] = '--db-only';
                    }
                    if (!empty($_POST['exclude_uploads'])) {
                        $sargs[] = '--exclude-uploads';
                    }
                    $r = stg_run('v-staging-sync', $sargs);
                    $notice = $r['code'] === 0
                        ? 'Staging re-sincronizado desde produccion.'
                        : 'Error en la sincronizacion (codigo ' . (int) $r['code'] . '). ' . h($r['out']);
                    $notice_type = $r['code'] === 0 ? 'ok' : 'error';
                    break;

                case 'push':
                    // Doble verificacion en el servidor: checkbox de backup + confirm exacto.
                    $confirm = isset($_POST['confirm_domain']) ? (string) $_POST['confirm_domain'] : '';
                    if (empty($_POST['ack_backup']) || empty($_POST['ack_killswitch'])) {
                        $notice = 'Debes confirmar el backup y el aviso del kill switch antes del push.';
                        $notice_type = 'error';
                        break;
                    }
                    if ($confirm !== $source) {
                        $notice = 'El dominio de confirmacion no coincide. Push cancelado.';
                        $notice_type = 'error';
                        break;
                    }
                    // STG_CONFIRM se pasa como entorno controlado (no via shell del usuario).
                    $r = stg_run('v-staging-push', [$source], ['STG_CONFIRM' => $source]);
                    if ($r['code'] === 5) {
                        $notice = 'PUSH BLOQUEADO por el kill switch (STG_PUSH_KILL_SWITCH=true). '
                            . 'Un administrador debe desactivarlo en conf/staging.conf.';
                        $notice_type = 'error';
                    } elseif ($r['code'] === 0) {
                        $notice = 'Push-to-live completado. Produccion actualizada (rollback disponible).';
                        $notice_type = 'ok';
                    } else {
                        $notice = 'Error en el push (codigo ' . (int) $r['code'] . '). ' . h($r['out']);
                        $notice_type = 'error';
                    }
                    break;

                case 'rollback':
                    $r = stg_run('v-staging-rollback', [$source], ['STG_CONFIRM' => $source]);
                    $notice = $r['code'] === 0
                        ? 'Rollback completado. Produccion restaurada al estado previo.'
                        : 'Error en el rollback (codigo ' . (int) $r['code'] . '). ' . h($r['out']);
                    $notice_type = $r['code'] === 0 ? 'ok' : 'error';
                    break;

                case 'delete':
                    $confirm = isset($_POST['confirm_domain']) ? (string) $_POST['confirm_domain'] : '';
                    if ($confirm !== $source) {
                        $notice = 'El dominio de confirmacion no coincide. Borrado cancelado.';
                        $notice_type = 'error';
                        break;
                    }
                    $r = stg_run('v-staging-delete', [$source], ['STG_CONFIRM' => $source]);
                    if ($r['code'] === 6) {
                        $notice = 'Borrado abortado por seguridad: el objetivo parece produccion.';
                        $notice_type = 'error';
                    } else {
                        $notice = $r['code'] === 0
                            ? 'Staging eliminado. Produccion intacta.'
                            : 'Error al eliminar (codigo ' . (int) $r['code'] . '). ' . h($r['out']);
                        $notice_type = $r['code'] === 0 ? 'ok' : 'error';
                    }
                    break;

                default:
                    $notice = 'Accion no reconocida.';
                    $notice_type = 'error';
            }
        }
    }
}

/* --------------------------------------------------------------------------
 * Datos para la vista.
 * ------------------------------------------------------------------------ */
// Cada usuario ve y clona SUS dominios; el administrador ve los de todo el servidor.
if ($stg_is_admin) {
    $domain_owners = stg_list_all_domains();   // domain => owner (todos)
    $staging = stg_list_staging('');           // todos los entornos staging
} else {
    $domain_owners = array();
    foreach (stg_list_domains($panel_user) as $d) {
        $domain_owners[$d] = $panel_user;
    }
    $staging = stg_list_staging($panel_user);  // solo los staging del usuario
}
$domains = array_keys($domain_owners);
$disk_free = stg_disk_free_bytes();            // espacio libre en /home

// Estado del kill switch (solo lectura, para mostrar el aviso en el modal).
// Lectura atomica con bloqueo compartido (LOCK_SH): evita leer el fichero a medio
// reescribir si un administrador lo esta modificando concurrentemente. Por defecto
// 'true' (fail-safe: si no se puede leer, se asume bloqueado). La aplicacion real
// del kill switch ocurre siempre en el lado servidor (v-staging-push, codigo 5);
// este valor es solo para mostrar el aviso correcto en la UI.
$kill_switch = 'true';
$conf_file = STG_WEB_ROOT . '/conf/staging.conf';
if (is_readable($conf_file)) {
    $conf = '';
    $fh = @fopen($conf_file, 'rb');
    if ($fh !== false) {
        if (flock($fh, LOCK_SH)) {
            $conf = stream_get_contents($fh);
            flock($fh, LOCK_UN);
        }
        fclose($fh);
    }
    if (is_string($conf) && $conf !== ''
        && preg_match('/^\s*STG_PUSH_KILL_SWITCH=\'?([^\'\n]+)\'?/m', $conf, $m)) {
        $kill_switch = trim($m[1]);
    }
}
?>
<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="robots" content="noindex, nofollow">
    <title>Staging - HestiaCP</title>
    <style>
        :root { --bg:#0f1419; --panel:#1b232c; --line:#2c3742; --txt:#e6edf3; --mut:#9aa7b4; --acc:#3b82f6; --ok:#22c55e; --err:#ef4444; --warn:#f59e0b; }
        * { box-sizing: border-box; }
        body { margin:0; font-family: system-ui, Segoe UI, Roboto, sans-serif; background:var(--bg); color:var(--txt); }
        .wrap { max-width:1080px; margin:0 auto; padding:24px 16px 64px; }
        h1 { font-size:22px; margin:0 0 4px; }
        .sub { color:var(--mut); margin:0 0 20px; font-size:13px; }
        .notice { padding:12px 14px; border-radius:8px; margin:0 0 18px; font-size:14px; border:1px solid var(--line); }
        .notice.ok { background:rgba(34,197,94,.12); border-color:var(--ok); }
        .notice.error { background:rgba(239,68,68,.12); border-color:var(--err); }
        .notice.info { background:rgba(59,130,246,.10); border-color:var(--acc); }
        .card { background:var(--panel); border:1px solid var(--line); border-radius:10px; padding:16px; margin:0 0 14px; }
        .card h2 { font-size:15px; margin:0 0 10px; }
        table { width:100%; border-collapse:collapse; font-size:13px; }
        th, td { text-align:left; padding:8px 10px; border-bottom:1px solid var(--line); }
        th { color:var(--mut); font-weight:600; }
        .tag { display:inline-block; padding:2px 8px; border-radius:99px; font-size:11px; border:1px solid var(--line); color:var(--mut); }
        .tag.ready { color:var(--ok); border-color:var(--ok); }
        .btn { display:inline-block; border:1px solid var(--line); background:#243038; color:var(--txt); padding:6px 12px; border-radius:6px; font-size:13px; cursor:pointer; text-decoration:none; }
        .btn:hover { border-color:var(--acc); }
        .btn.acc { background:var(--acc); border-color:var(--acc); color:#fff; }
        .btn.danger { background:var(--err); border-color:var(--err); color:#fff; }
        .btn.warn { background:var(--warn); border-color:var(--warn); color:#161616; }
        .btn[disabled] { opacity:.45; cursor:not-allowed; }
        form.inline { display:inline; }
        label { display:block; font-size:13px; margin:10px 0 4px; color:var(--mut); }
        select, input[type=text] { width:100%; padding:8px; border-radius:6px; border:1px solid var(--line); background:#0f1419; color:var(--txt); font-size:13px; }
        .row { display:flex; gap:10px; flex-wrap:wrap; }
        .row > div { flex:1 1 220px; }
        .actions { display:flex; gap:8px; flex-wrap:wrap; }
        .modal-bg { display:none; position:fixed; inset:0; background:rgba(0,0,0,.6); align-items:center; justify-content:center; padding:16px; z-index:50; }
        .modal-bg.open { display:flex; }
        .modal { background:var(--panel); border:1px solid var(--err); border-radius:10px; max-width:520px; width:100%; padding:20px; }
        .modal h3 { margin:0 0 8px; color:var(--err); }
        .modal p { font-size:13px; color:var(--mut); line-height:1.5; }
        .chk { display:flex; gap:8px; align-items:flex-start; margin:10px 0; font-size:13px; color:var(--txt); }
        .chk input { margin-top:3px; }
        .kill-banner { background:rgba(245,158,11,.12); border:1px solid var(--warn); border-radius:8px; padding:10px 12px; font-size:13px; margin:6px 0 0; }
        .muted { color:var(--mut); font-size:12px; }
        code { background:#0f1419; padding:1px 5px; border-radius:4px; }
    </style>
</head>
<body>
<div class="wrap">
    <h1>Entornos de Staging</h1>
    <p class="sub">Crea, sincroniza y promociona copias de pruebas de tus dominios. Usuario: <strong><?php echo h($panel_user !== '' ? $panel_user : '(desconocido)'); ?></strong></p>
    <p class="sub">Espacio libre en <code>/home</code>: <strong><?php echo h(stg_hbytes($disk_free)); ?></strong>. El clonado comprueba el espacio (ficheros + BBDD + margen) <strong>antes de empezar</strong> y se cancela si no cabe.</p>

    <?php if ($notice !== '') : ?>
        <div class="notice <?php echo h($notice_type); ?>"><?php echo $notice; /* ya escapado donde corresponde */ ?></div>
    <?php endif; ?>

    <?php if ($panel_user === '') : ?>
        <div class="card"><p>No se ha podido identificar tu usuario del panel. Accede desde HestiaCP.</p></div>
    <?php else : ?>

    <div class="card">
        <h2><?php echo $stg_is_admin ? 'Dominios del servidor' : 'Tus dominios'; ?></h2>
        <?php if (empty($domains)) : ?>
            <p class="muted">No se han encontrado dominios web.</p>
        <?php else : ?>
        <table>
            <thead><tr><th>Dominio</th><th>Usuario</th><th>Staging</th><th>Estado</th><th style="width:1%">Acciones</th></tr></thead>
            <tbody>
            <?php foreach ($domains as $d) :
                // No mostramos los propios dominios staging como "origen" candidato.
                $is_staging_target = false;
                foreach ($staging as $st) {
                    if (isset($st['staging_domain']) && $st['staging_domain'] === $d) { $is_staging_target = true; break; }
                }
                if ($is_staging_target) { continue; }
                $has = isset($staging[$d]);
                $st = $has ? $staging[$d] : null;
            ?>
                <tr>
                    <td><strong><?php echo h($d); ?></strong></td>
                    <td><span class="muted"><?php echo h($domain_owners[$d] ?? '?'); ?></span></td>
                    <td>
                        <?php echo $has ? h($st['staging_domain']) : '<span class="muted">- sin staging -</span>'; ?>
                    </td>
                    <td>
                        <?php if ($has) : ?>
                            <span class="tag <?php echo h(($st['status'] ?? '') === 'ready' ? 'ready' : ''); ?>"><?php echo h($st['status'] ?? '?'); ?></span>
                        <?php else : ?>
                            <span class="muted">-</span>
                        <?php endif; ?>
                    </td>
                    <td>
                        <?php if (!$has) : ?>
                            <button class="btn acc" type="button" onclick="openCreate('<?php echo h($d); ?>')">Crear staging</button>
                        <?php else : ?>
                            <a class="btn" href="#stg-<?php echo h(rawurlencode($d)); ?>">Ver</a>
                        <?php endif; ?>
                    </td>
                </tr>
            <?php endforeach; ?>
            </tbody>
        </table>
        <?php endif; ?>
    </div>

    <?php /* Vista detallada por cada staging existente. */ ?>
    <?php foreach ($staging as $src => $st) :
        if (!stg_is_domain($src)) { continue; }
        $sid = 'stg-' . rawurlencode($src);
        $pushed = !empty($st['pushed_at']) && $st['pushed_at'] !== '0';
    ?>
    <div class="card" id="<?php echo h($sid); ?>">
        <h2>Staging de <?php echo h($src); ?> &rarr; <?php echo h($st['staging_domain'] ?? '?'); ?></h2>
        <p class="muted">
            Usuario: <?php echo h($st['user'] ?? '?'); ?> &middot;
            Modo: <?php echo h($st['mode'] ?? '?'); ?> &middot;
            CMS: <?php echo h($st['cms'] ?? '?'); ?> &middot;
            Estado: <?php echo h($st['status'] ?? '?'); ?>
        </p>

        <div class="actions">
            <!-- Sync (produccion -> staging): seguro, sin confirmacion fuerte. -->
            <form class="inline" method="post">
                <input type="hidden" name="csrf" value="<?php echo h($csrf); ?>">
                <input type="hidden" name="action" value="sync">
                <input type="hidden" name="source_domain" value="<?php echo h($src); ?>">
                <input type="hidden" name="scope" value="all">
                <button class="btn" type="submit">Sincronizar desde produccion</button>
            </form>

            <!-- Push (staging -> produccion): abre modal de confirmacion fuerte. -->
            <button class="btn danger" type="button"
                onclick="openPush('<?php echo h($src); ?>')"
                <?php echo $kill_switch === 'true' ? 'title="Bloqueado por kill switch"' : ''; ?>>
                Push a produccion
            </button>

            <?php if ($pushed) : ?>
            <!-- Rollback del ultimo push. -->
            <form class="inline" method="post" onsubmit="return confirm('Restaurar produccion al estado previo al ultimo push?');">
                <input type="hidden" name="csrf" value="<?php echo h($csrf); ?>">
                <input type="hidden" name="action" value="rollback">
                <input type="hidden" name="source_domain" value="<?php echo h($src); ?>">
                <button class="btn warn" type="submit">Rollback del push</button>
            </form>
            <?php endif; ?>

            <!-- Eliminar staging: modal de confirmacion (escribir dominio). -->
            <button class="btn" type="button" onclick="openDelete('<?php echo h($src); ?>')">Eliminar staging</button>
        </div>

        <?php if ($kill_switch === 'true') : ?>
        <div class="kill-banner">
            El <strong>push-to-live esta BLOQUEADO</strong> por el kill switch
            (<code>STG_PUSH_KILL_SWITCH='true'</code>). Un administrador debe
            desactivarlo en <code>conf/staging.conf</code> tras verificar los backups.
        </div>
        <?php endif; ?>
    </div>
    <?php endforeach; ?>

    <?php endif; /* panel_user */ ?>
</div>

<!-- Modal: crear staging (asistente). -->
<div class="modal-bg" id="modal-create">
    <div class="modal" style="border-color:var(--acc)">
        <h3 style="color:var(--acc)">Crear entorno de staging</h3>
        <p>Se clonara <strong id="create-domain-label"></strong> (ficheros + BBDD) a un entorno aislado, con URLs y credenciales reescritas y proteccion noindex/Basic Auth. No se toca produccion.</p>
        <form method="post">
            <input type="hidden" name="csrf" value="<?php echo h($csrf); ?>">
            <input type="hidden" name="action" value="create">
            <input type="hidden" name="source_domain" id="create-source" value="">
            <div class="row">
                <div>
                    <label for="create-mode">Modo</label>
                    <select name="mode" id="create-mode" onchange="toggleName()">
                        <option value="subdomain">Subdominio (staging.tudominio)</option>
                        <option value="domain">Dominio aparte</option>
                        <option value="user">Usuario de staging dedicado</option>
                    </select>
                </div>
                <div id="create-name-wrap" style="display:none">
                    <label for="create-name">Nombre del dominio de staging</label>
                    <input type="text" name="stg_name" id="create-name" placeholder="staging.midominio.com" autocomplete="off">
                </div>
            </div>
            <div class="actions" style="margin-top:16px">
                <button class="btn acc" type="submit">Crear staging</button>
                <button class="btn" type="button" onclick="closeModal('modal-create')">Cancelar</button>
            </div>
        </form>
    </div>
</div>

<!-- Modal: push a produccion (confirmacion fuerte). -->
<div class="modal-bg" id="modal-push">
    <div class="modal">
        <h3>Confirmar PUSH a produccion</h3>
        <p>Esta operacion <strong>sobrescribe produccion</strong> con el contenido del staging. Es destructiva. Antes de continuar se generara un backup completo del usuario y se conservara una copia anterior para rollback.</p>
        <div class="kill-banner" id="push-kill-warn">
            <?php if ($kill_switch === 'true') : ?>
                Aviso: el kill switch esta <strong>ACTIVO</strong>. El push se rechazara
                hasta que un administrador ponga <code>STG_PUSH_KILL_SWITCH='false'</code>.
            <?php else : ?>
                El kill switch esta desactivado: el push se ejecutara si confirmas todo.
            <?php endif; ?>
        </div>
        <form method="post" id="push-form">
            <input type="hidden" name="csrf" value="<?php echo h($csrf); ?>">
            <input type="hidden" name="action" value="push">
            <input type="hidden" name="source_domain" id="push-source" value="">
            <label class="chk"><input type="checkbox" name="ack_backup" id="push-ack-backup" onchange="checkPush()"> Confirmo que se hara un backup previo y entiendo que es obligatorio.</label>
            <label class="chk"><input type="checkbox" name="ack_killswitch" id="push-ack-kill" onchange="checkPush()"> He leido el aviso del kill switch.</label>
            <label for="push-confirm">Escribe el dominio de produccion para confirmar:</label>
            <input type="text" name="confirm_domain" id="push-confirm" autocomplete="off" oninput="checkPush()" placeholder="">
            <div class="actions" style="margin-top:16px">
                <button class="btn danger" type="submit" id="push-submit" disabled>Promocionar a produccion</button>
                <button class="btn" type="button" onclick="closeModal('modal-push')">Cancelar</button>
            </div>
        </form>
    </div>
</div>

<!-- Modal: eliminar staging. -->
<div class="modal-bg" id="modal-delete">
    <div class="modal">
        <h3>Eliminar entorno de staging</h3>
        <p>Se eliminara <strong>solo el staging</strong> (dominio web + BBDD clonadas). Produccion no se toca. Escribe el dominio de produccion para confirmar.</p>
        <form method="post" id="delete-form">
            <input type="hidden" name="csrf" value="<?php echo h($csrf); ?>">
            <input type="hidden" name="action" value="delete">
            <input type="hidden" name="source_domain" id="delete-source" value="">
            <label for="delete-confirm">Dominio de produccion:</label>
            <input type="text" name="confirm_domain" id="delete-confirm" autocomplete="off" oninput="checkDelete()" placeholder="">
            <div class="actions" style="margin-top:16px">
                <button class="btn danger" type="submit" id="delete-submit" disabled>Eliminar staging</button>
                <button class="btn" type="button" onclick="closeModal('modal-delete')">Cancelar</button>
            </div>
        </form>
    </div>
</div>

<script>
    // Apertura/cierre de modales y validaciones de confirmacion en cliente.
    function openModal(id) { document.getElementById(id).classList.add('open'); }
    function closeModal(id) { document.getElementById(id).classList.remove('open'); }

    function openCreate(domain) {
        document.getElementById('create-source').value = domain;
        document.getElementById('create-domain-label').textContent = domain;
        document.getElementById('create-name').value = '';
        document.getElementById('create-mode').value = 'subdomain';
        toggleName();
        openModal('modal-create');
    }
    function toggleName() {
        var mode = document.getElementById('create-mode').value;
        document.getElementById('create-name-wrap').style.display = (mode === 'subdomain') ? 'none' : 'block';
    }

    var pushSource = '';
    function openPush(domain) {
        pushSource = domain;
        document.getElementById('push-source').value = domain;
        document.getElementById('push-confirm').value = '';
        document.getElementById('push-confirm').placeholder = domain;
        document.getElementById('push-ack-backup').checked = false;
        document.getElementById('push-ack-kill').checked = false;
        checkPush();
        openModal('modal-push');
    }
    function checkPush() {
        var ok = document.getElementById('push-ack-backup').checked
            && document.getElementById('push-ack-kill').checked
            && document.getElementById('push-confirm').value === pushSource;
        document.getElementById('push-submit').disabled = !ok;
    }

    var delSource = '';
    function openDelete(domain) {
        delSource = domain;
        document.getElementById('delete-source').value = domain;
        document.getElementById('delete-confirm').value = '';
        document.getElementById('delete-confirm').placeholder = domain;
        checkDelete();
        openModal('modal-delete');
    }
    function checkDelete() {
        document.getElementById('delete-submit').disabled =
            document.getElementById('delete-confirm').value !== delSource;
    }

    // Cierre al hacer click en el fondo.
    document.querySelectorAll('.modal-bg').forEach(function (bg) {
        bg.addEventListener('click', function (e) { if (e.target === bg) { bg.classList.remove('open'); } });
    });
</script>
</body>
</html>
