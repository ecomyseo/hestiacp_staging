<?php
/**
 * web/index.php - Panel web del plugin Watchdog para HestiaCP.
 *
 * Dashboard de estado (semaforo por categoria leyendo state/), listado de
 * alertas con filtros y boton ACK, y formulario de configuracion. TODA accion
 * de escritura se delega en los binarios CLI (v-watchdog-config-set,
 * v-watchdog-ack, v-watchdog-test-notify, v-watchdog-run): este PHP NUNCA edita
 * ficheros de configuracion directamente. Salida escapada siempre y token CSRF
 * en todos los formularios.
 *
 * @author    Ecom Experts <ecomyseo@gmail.com>
 * @copyright 2026 Ecom Experts
 * @license   AFL-3.0
 */

/* Autenticacion del panel HestiaCP (OBLIGATORIA): solo el administrador con
 * sesion iniciada puede ver el dashboard. Integracion via inc/main.php. */
$__hestia_doc = (isset($_SERVER['DOCUMENT_ROOT']) && $_SERVER['DOCUMENT_ROOT'] !== '')
    ? $_SERVER['DOCUMENT_ROOT'] : '/usr/local/hestia/web';
$__hestia_main = $__hestia_doc . '/inc/main.php';
if (is_file($__hestia_main)) {
    require_once $__hestia_main;
}
if (!isset($_SESSION['userContext']) || $_SESSION['userContext'] !== 'admin') {
    header('Location: /login/');
    exit;
}

if (session_status() === PHP_SESSION_NONE) {
    session_start();
}

// Raiz del plugin (un nivel por encima de web/).
$WD_ROOT = dirname(__DIR__);
$WD_BIN  = $WD_ROOT . '/bin';
$WD_STATE = $WD_ROOT . '/state';
// El PHP del panel corre como 'hestiaweb' (no root): los comandos del plugin se
// ejecutan via sudo sobre los wrappers de /usr/local/hestia/bin (permitido por el
// sudoers de HestiaCP). HESTIA_CMD lo define inc/main.php.
define('WD_CMD', defined('HESTIA_CMD') ? HESTIA_CMD : '/usr/bin/sudo /usr/local/hestia/bin/');

// ---------------------------------------------------------------------------
// Helpers de seguridad.
// ---------------------------------------------------------------------------

/** Escape HTML para salida. */
function h($s)
{
    return htmlspecialchars((string) $s, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
}

/** Token CSRF de la sesion (se genera una vez). */
function wd_csrf_token()
{
    if (empty($_SESSION['wd_csrf'])) {
        $_SESSION['wd_csrf'] = bin2hex(random_bytes(16));
    }
    return $_SESSION['wd_csrf'];
}

/** Verifica el token CSRF recibido por POST. */
function wd_csrf_check()
{
    $sent = isset($_POST['csrf']) ? (string) $_POST['csrf'] : '';
    return !empty($_SESSION['wd_csrf']) && hash_equals($_SESSION['wd_csrf'], $sent);
}

/**
 * Ejecuta un binario del plugin de forma segura (sin shell), pasando los
 * argumentos como array. Devuelve [codigo, salida].
 */
function wd_run_bin($WD_BIN, $name, array $args = array())
{
    // Lista blanca de comandos del plugin (wrappers en /usr/local/hestia/bin).
    static $allowed = array(
        'v-watchdog-run', 'v-watchdog-status', 'v-watchdog-list-alerts', 'v-watchdog-ack',
        'v-watchdog-test-notify', 'v-watchdog-config-get', 'v-watchdog-config-set', 'v-watchdog-debug',
    );
    if (!in_array($name, $allowed, true)) {
        return array(127, "Comando no permitido: $name");
    }
    // Ejecucion via sudo sobre el wrapper del panel (el PHP corre como hestiaweb,
    // y el estado/conf son de root; los comandos devuelven los datos ya formateados).
    $cmd = WD_CMD . $name;
    foreach ($args as $a) {
        $cmd .= ' ' . escapeshellarg((string) $a);
    }
    $cmd .= ' 2>&1';
    $output = array();
    $code = 0;
    exec($cmd, $output, $code);
    return array($code, implode("\n", $output));
}

/** Lee un fichero de estado simple (state/<key>). */
function wd_state_read($WD_STATE, $key, $default = '')
{
    $safe = preg_replace('/[^A-Za-z0-9._-]/', '_', $key);
    $f = $WD_STATE . '/' . $safe;
    if (is_file($f)) {
        return trim((string) file_get_contents($f));
    }
    return $default;
}

// ---------------------------------------------------------------------------
// Manejo de acciones POST (config / ack / test / run). Requiere CSRF valido.
// ---------------------------------------------------------------------------
$flash = array();   // mensajes a mostrar (tipo => texto)

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    if (!wd_csrf_check()) {
        $flash[] = array('error', 'Token CSRF invalido. Recarga la pagina e intentalo de nuevo.');
    } else {
        $action = isset($_POST['action']) ? (string) $_POST['action'] : '';

        if ($action === 'config_set') {
            // Solo claves conocidas; el binario aplica su propia lista blanca.
            $key = isset($_POST['key']) ? (string) $_POST['key'] : '';
            $val = isset($_POST['value']) ? (string) $_POST['value'] : '';
            if ($key === '') {
                $flash[] = array('error', 'Clave vacia.');
            } else {
                list($code, $out) = wd_run_bin($WD_BIN, 'v-watchdog-config-set', array($key, $val));
                $flash[] = array($code === 0 ? 'ok' : 'error', ($code === 0 ? 'Guardado: ' : 'Error: ') . $out);
            }
        } elseif ($action === 'config_bulk') {
            // Guarda varios pares clave/valor del formulario de config.
            $pairs = isset($_POST['cfg']) && is_array($_POST['cfg']) ? $_POST['cfg'] : array();
            // Claves secreto: si vienen vacias se omiten (no se borra lo guardado).
            $secretKeys = array('WD_TELEGRAM_TOKEN');
            $errors = 0;
            foreach ($pairs as $k => $v) {
                if (in_array($k, $secretKeys, true) && (string) $v === '') {
                    continue;
                }
                list($code, $out) = wd_run_bin($WD_BIN, 'v-watchdog-config-set', array((string) $k, (string) $v));
                if ($code !== 0) {
                    $errors++;
                    $flash[] = array('error', h($k) . ': ' . $out);
                }
            }
            if ($errors === 0) {
                $flash[] = array('ok', 'Configuracion guardada correctamente.');
            }
        } elseif ($action === 'ack') {
            $id = isset($_POST['id']) ? (string) $_POST['id'] : '';
            if (ctype_digit($id)) {
                list($code, $out) = wd_run_bin($WD_BIN, 'v-watchdog-ack', array($id));
                $flash[] = array($code === 0 ? 'ok' : 'error', $out);
            } else {
                $flash[] = array('error', 'Id de alerta invalido.');
            }
        } elseif ($action === 'ack_all') {
            list($code, $out) = wd_run_bin($WD_BIN, 'v-watchdog-ack', array('--all'));
            $flash[] = array($code === 0 ? 'ok' : 'error', $out);
        } elseif ($action === 'test_notify') {
            // Prueba puntual; respeta el kill switch salvo --force explicito.
            $args = array();
            if (!empty($_POST['force'])) {
                $args[] = '--force';
            }
            list($code, $out) = wd_run_bin($WD_BIN, 'v-watchdog-test-notify', $args);
            $flash[] = array($code === 0 ? 'ok' : 'error', $out !== '' ? $out : 'Prueba ejecutada.');
        } elseif ($action === 'run_now') {
            // Ejecucion manual en modo dry-run (no notifica) para refrescar estado.
            list($code, $out) = wd_run_bin($WD_BIN, 'v-watchdog-run', array('run', '--dry-run'));
            $flash[] = array($code === 0 ? 'ok' : 'error', 'Ejecucion (dry-run) completada.');
        }
    }
    // Patron PRG: redirige para evitar reenvio del POST. Conserva la pestana.
    $tab = isset($_POST['tab']) ? (string) $_POST['tab'] : 'dashboard';
    $_SESSION['wd_flash'] = $flash;
    header('Location: ?tab=' . urlencode($tab));
    exit;
}

// Recupera flash tras la redireccion.
if (!empty($_SESSION['wd_flash'])) {
    $flash = $_SESSION['wd_flash'];
    unset($_SESSION['wd_flash']);
}

// ---------------------------------------------------------------------------
// Carga de datos para la vista (solo lectura via binarios CLI / state).
// ---------------------------------------------------------------------------
$tab = isset($_GET['tab']) ? (string) $_GET['tab'] : 'dashboard';
if (!in_array($tab, array('dashboard', 'alerts', 'config'), true)) {
    $tab = 'dashboard';
}

// Estado global (JSON del binario de status).
list(, $statusJson) = wd_run_bin($WD_BIN, 'v-watchdog-status', array('json'));
$status = json_decode($statusJson, true);
if (!is_array($status)) {
    $status = array();
}
// Normaliza la estructura esperada: si el JSON viene corrupto o incompleto,
// garantiza que cada clave existe con el tipo correcto antes de usarla en la
// vista (evita warnings de foreach y datos enganosos en el dashboard).
$status += array('last_run' => 0, 'global_severity' => 'INFO', 'kill_switch' => 'true', 'categories' => array(), 'duration' => 0);
if (!is_array($status['categories'])) {
    $status['categories'] = array();
}

// Filtros de alertas.
$fSeverity = isset($_GET['severity']) ? (string) $_GET['severity'] : '';
$fStatus   = isset($_GET['status']) ? (string) $_GET['status'] : 'open';
if (!in_array($fStatus, array('open', 'acked', 'all'), true)) {
    $fStatus = 'open';
}
$alertArgs = array('--status', $fStatus, '--limit', '100', '--format', 'json');
if (in_array($fSeverity, array('WARNING', 'CRITICAL'), true)) {
    $alertArgs[] = '--severity';
    $alertArgs[] = $fSeverity;
}
list(, $alertsJson) = wd_run_bin($WD_BIN, 'v-watchdog-list-alerts', $alertArgs);
$alerts = json_decode($alertsJson, true);
if (!is_array($alerts)) {
    $alerts = array();
}

// Configuracion completa (JSON enmascarado) para el formulario.
list(, $cfgJson) = wd_run_bin($WD_BIN, 'v-watchdog-config-get', array('--all', 'json'));
$cfg = json_decode($cfgJson, true);
if (!is_array($cfg)) {
    $cfg = array();
}
function cfgv($cfg, $key, $def = '')
{
    return isset($cfg[$key]) ? $cfg[$key] : $def;
}

// Mapea severidad a clase/color de semaforo.
function sev_class($sev)
{
    switch (strtoupper((string) $sev)) {
        case 'CRITICAL': return 'crit';
        case 'WARNING':  return 'warn';
        case 'INFO':     return 'ok';
        default:         return 'unknown';
    }
}

$CSRF = wd_csrf_token();
$killOn = (cfgv($cfg, 'WD_KILL_SWITCH', 'true') === 'true');
?>
<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Watchdog - HestiaCP</title>
<style>
 body{font-family:-apple-system,Segoe UI,Roboto,Arial,sans-serif;margin:0;background:#f4f6f8;color:#222}
 header{background:#1f2d3d;color:#fff;padding:14px 20px;display:flex;align-items:center;justify-content:space-between}
 header h1{font-size:18px;margin:0}
 .wrap{max-width:1100px;margin:0 auto;padding:18px}
 nav a{display:inline-block;padding:8px 14px;margin-right:6px;text-decoration:none;color:#1f2d3d;border-radius:6px}
 nav a.active{background:#1f2d3d;color:#fff}
 .cards{display:grid;grid-template-columns:repeat(auto-fill,minmax(200px,1fr));gap:12px;margin:16px 0}
 .card{background:#fff;border-radius:8px;padding:14px;box-shadow:0 1px 3px rgba(0,0,0,.1);border-left:6px solid #ccc}
 .card.ok{border-color:#2e9e5b}.card.warn{border-color:#e0a800}.card.crit{border-color:#d9534f}.card.unknown{border-color:#999}
 .card h3{margin:0 0 6px;font-size:14px;text-transform:capitalize}
 .badge{display:inline-block;padding:2px 8px;border-radius:10px;font-size:11px;color:#fff}
 .badge.ok{background:#2e9e5b}.badge.warn{background:#e0a800}.badge.crit{background:#d9534f}.badge.unknown{background:#999}
 .card p{margin:6px 0 0;font-size:12px;color:#555;word-break:break-word}
 table{width:100%;border-collapse:collapse;background:#fff;border-radius:8px;overflow:hidden}
 th,td{padding:8px 10px;text-align:left;font-size:13px;border-bottom:1px solid #eee}
 th{background:#eef1f4}
 .pill{padding:2px 8px;border-radius:10px;font-size:11px;color:#fff}
 .pill.WARNING{background:#e0a800}.pill.CRITICAL{background:#d9534f}
 form.inline{display:inline}
 button{cursor:pointer;border:0;border-radius:6px;padding:7px 12px;font-size:13px}
 button.primary{background:#1f2d3d;color:#fff}button.warn{background:#e0a800;color:#000}button.small{padding:4px 9px;font-size:12px}
 .flash{padding:10px 14px;border-radius:6px;margin:10px 0;font-size:13px}
 .flash.ok{background:#dff3e6;color:#205c36}.flash.error{background:#fbe3e2;color:#8a1f1b}
 .kill{padding:6px 12px;border-radius:6px;font-weight:600}
 .kill.on{background:#d9534f;color:#fff}.kill.off{background:#2e9e5b;color:#fff}
 fieldset{border:1px solid #ddd;border-radius:8px;margin:14px 0;padding:14px;background:#fff}
 legend{font-weight:600;padding:0 6px}
 .grid2{display:grid;grid-template-columns:1fr 1fr;gap:12px}
 label{display:block;font-size:13px;margin:8px 0 3px;color:#333}
 input[type=text],input[type=number],select{width:100%;padding:7px;border:1px solid #ccc;border-radius:6px;box-sizing:border-box}
 .filters{margin:10px 0}
 .muted{color:#888;font-size:12px}
</style>
</head>
<body>
<header>
 <h1>Watchdog &middot; HestiaCP</h1>
 <span class="kill <?php echo $killOn ? 'on' : 'off'; ?>">
  KILL SWITCH: <?php echo $killOn ? 'ACTIVO (no envia)' : 'desactivado (envia)'; ?>
 </span>
</header>
<div class="wrap">

 <nav>
  <a class="<?php echo $tab === 'dashboard' ? 'active' : ''; ?>" href="?tab=dashboard">Dashboard</a>
  <a class="<?php echo $tab === 'alerts' ? 'active' : ''; ?>" href="?tab=alerts">Alertas</a>
  <a class="<?php echo $tab === 'config' ? 'active' : ''; ?>" href="?tab=config">Configuracion</a>
 </nav>

 <?php foreach ($flash as $f): ?>
  <div class="flash <?php echo h($f[0]); ?>"><?php echo h($f[1]); ?></div>
 <?php endforeach; ?>

 <?php if ($tab === 'dashboard'): ?>
  <?php
    $lr = (int) cfgv($status, 'last_run', 0);
    $when = $lr > 0 ? date('Y-m-d H:i:s', $lr) : 'sin ejecuciones';
    $gsev = isset($status['global_severity']) ? $status['global_severity'] : 'INFO';
  ?>
  <p class="muted">
   Estado global:
   <span class="badge <?php echo sev_class($gsev); ?>"><?php echo h($gsev); ?></span>
   &nbsp;|&nbsp; Ultima ejecucion: <?php echo h($when); ?>
   &nbsp;|&nbsp; Duracion: <?php echo (int) cfgv($status, 'duration', 0); ?>s
  </p>

  <form class="inline" method="post" action="?tab=dashboard">
   <input type="hidden" name="csrf" value="<?php echo h($CSRF); ?>">
   <input type="hidden" name="action" value="run_now">
   <input type="hidden" name="tab" value="dashboard">
   <button class="primary" type="submit">Ejecutar ahora (dry-run)</button>
  </form>

  <div class="cards">
   <?php if (empty($status['categories'])): ?>
    <p class="muted">No hay datos todavia. Ejecuta el watchdog para poblar el semaforo.</p>
   <?php else: foreach ($status['categories'] as $cat): ?>
    <?php $cls = sev_class(isset($cat['severity']) ? $cat['severity'] : 'INFO'); ?>
    <div class="card <?php echo $cls; ?>">
     <h3><?php echo h(isset($cat['name']) ? $cat['name'] : '?'); ?></h3>
     <span class="badge <?php echo $cls; ?>"><?php echo h(isset($cat['severity']) ? $cat['severity'] : 'INFO'); ?></span>
     <p><?php echo h(isset($cat['msg']) ? $cat['msg'] : ''); ?></p>
    </div>
   <?php endforeach; endif; ?>
  </div>

 <?php elseif ($tab === 'alerts'): ?>
  <div class="filters">
   <form class="inline" method="get" action="">
    <input type="hidden" name="tab" value="alerts">
    Severidad:
    <select name="severity" onchange="this.form.submit()">
     <option value="" <?php echo $fSeverity === '' ? 'selected' : ''; ?>>Todas</option>
     <option value="WARNING" <?php echo $fSeverity === 'WARNING' ? 'selected' : ''; ?>>WARNING</option>
     <option value="CRITICAL" <?php echo $fSeverity === 'CRITICAL' ? 'selected' : ''; ?>>CRITICAL</option>
    </select>
    Estado:
    <select name="status" onchange="this.form.submit()">
     <option value="open" <?php echo $fStatus === 'open' ? 'selected' : ''; ?>>Abiertas</option>
     <option value="acked" <?php echo $fStatus === 'acked' ? 'selected' : ''; ?>>Reconocidas</option>
     <option value="all" <?php echo $fStatus === 'all' ? 'selected' : ''; ?>>Todas</option>
    </select>
   </form>
   <form class="inline" method="post" action="?tab=alerts">
    <input type="hidden" name="csrf" value="<?php echo h($CSRF); ?>">
    <input type="hidden" name="action" value="ack_all">
    <input type="hidden" name="tab" value="alerts">
    <button class="warn small" type="submit">Reconocer todas</button>
   </form>
  </div>

  <table>
   <thead>
    <tr><th>#</th><th>Fecha</th><th>Sev.</th><th>Check</th><th>Metrica</th><th>Mensaje</th><th>ACK</th><th></th></tr>
   </thead>
   <tbody>
   <?php if (empty($alerts)): ?>
    <tr><td colspan="8" class="muted">No hay alertas con estos filtros.</td></tr>
   <?php else: foreach ($alerts as $a): ?>
    <?php
      $aid = isset($a['id']) ? (int) $a['id'] : 0;
      $ats = isset($a['ts']) ? (int) $a['ts'] : 0;
      $asev = isset($a['severity']) ? $a['severity'] : 'WARNING';
      $aack = isset($a['ack']) ? (int) $a['ack'] : 0;
    ?>
    <tr>
     <td><?php echo $aid; ?></td>
     <td><?php echo h($ats > 0 ? date('Y-m-d H:i', $ats) : ''); ?></td>
     <td><span class="pill <?php echo h($asev); ?>"><?php echo h($asev); ?></span></td>
     <td><?php echo h(isset($a['check']) ? $a['check'] : ''); ?></td>
     <td><?php echo h(isset($a['metric']) ? $a['metric'] : ''); ?></td>
     <td><?php echo h(isset($a['msg']) ? $a['msg'] : ''); ?></td>
     <td><?php echo $aack ? 'Si' : 'No'; ?></td>
     <td>
      <?php if (!$aack): ?>
      <form class="inline" method="post" action="?tab=alerts">
       <input type="hidden" name="csrf" value="<?php echo h($CSRF); ?>">
       <input type="hidden" name="action" value="ack">
       <input type="hidden" name="tab" value="alerts">
       <input type="hidden" name="id" value="<?php echo $aid; ?>">
       <button class="small primary" type="submit">ACK</button>
      </form>
      <?php endif; ?>
     </td>
    </tr>
   <?php endforeach; endif; ?>
   </tbody>
  </table>

 <?php elseif ($tab === 'config'): ?>
  <form method="post" action="?tab=config">
   <input type="hidden" name="csrf" value="<?php echo h($CSRF); ?>">
   <input type="hidden" name="action" value="config_bulk">
   <input type="hidden" name="tab" value="config">

   <fieldset>
    <legend>Seguridad</legend>
    <label>Kill switch (corta TODO envio al exterior)</label>
    <select name="cfg[WD_KILL_SWITCH]">
     <option value="true" <?php echo cfgv($cfg, 'WD_KILL_SWITCH', 'true') === 'true' ? 'selected' : ''; ?>>true (no envia - recomendado hasta validar)</option>
     <option value="false" <?php echo cfgv($cfg, 'WD_KILL_SWITCH', 'true') === 'false' ? 'selected' : ''; ?>>false (envia notificaciones)</option>
    </select>
    <p class="muted">Manten 'true' hasta validar canales con el boton de prueba.</p>
   </fieldset>

   <fieldset>
    <legend>Canales</legend>
    <div class="grid2">
     <div>
      <label>Email activo</label>
      <select name="cfg[WD_CHANNEL_EMAIL]">
       <option value="false" <?php echo cfgv($cfg, 'WD_CHANNEL_EMAIL', 'false') === 'false' ? 'selected' : ''; ?>>false</option>
       <option value="true" <?php echo cfgv($cfg, 'WD_CHANNEL_EMAIL', 'false') === 'true' ? 'selected' : ''; ?>>true</option>
      </select>
      <label>Email destino</label>
      <input type="text" name="cfg[WD_EMAIL_TO]" value="<?php echo h(cfgv($cfg, 'WD_EMAIL_TO', '')); ?>">
     </div>
     <div>
      <label>Telegram activo</label>
      <select name="cfg[WD_CHANNEL_TELEGRAM]">
       <option value="false" <?php echo cfgv($cfg, 'WD_CHANNEL_TELEGRAM', 'false') === 'false' ? 'selected' : ''; ?>>false</option>
       <option value="true" <?php echo cfgv($cfg, 'WD_CHANNEL_TELEGRAM', 'false') === 'true' ? 'selected' : ''; ?>>true</option>
      </select>
      <label>Telegram chat id</label>
      <input type="text" name="cfg[WD_TELEGRAM_CHAT_ID]" value="<?php echo h(cfgv($cfg, 'WD_TELEGRAM_CHAT_ID', '')); ?>">
     </div>
    </div>
    <label>Telegram token (dejar vacio para no cambiar el almacenado)</label>
    <input type="text" name="cfg[WD_TELEGRAM_TOKEN]" value="" placeholder="<?php echo h(cfgv($cfg, 'WD_TELEGRAM_TOKEN', '')); ?>">
    <div class="grid2">
     <div>
      <label>Webhook activo</label>
      <select name="cfg[WD_CHANNEL_WEBHOOK]">
       <option value="false" <?php echo cfgv($cfg, 'WD_CHANNEL_WEBHOOK', 'false') === 'false' ? 'selected' : ''; ?>>false</option>
       <option value="true" <?php echo cfgv($cfg, 'WD_CHANNEL_WEBHOOK', 'false') === 'true' ? 'selected' : ''; ?>>true</option>
      </select>
     </div>
     <div>
      <label>Webhook URL</label>
      <input type="text" name="cfg[WD_WEBHOOK_URL]" value="<?php echo h(cfgv($cfg, 'WD_WEBHOOK_URL', '')); ?>">
     </div>
    </div>
   </fieldset>

   <fieldset>
    <legend>Notificaciones</legend>
    <div class="grid2">
     <div>
      <label>Ventana anti-duplicado (min)</label>
      <input type="number" name="cfg[WD_NOTIFY_WINDOW]" min="0" value="<?php echo h(cfgv($cfg, 'WD_NOTIFY_WINDOW', '30')); ?>">
     </div>
     <div>
      <label>Max. notificaciones por hora</label>
      <input type="number" name="cfg[WD_RATE_MAX_HOUR]" min="0" value="<?php echo h(cfgv($cfg, 'WD_RATE_MAX_HOUR', '20')); ?>">
     </div>
    </div>
   </fieldset>

   <fieldset>
    <legend>Umbrales de recursos (%)</legend>
    <div class="grid2">
     <div>
      <label>CPU warning</label>
      <input type="number" name="cfg[RES_CPU_WARN]" value="<?php echo h(cfgv($cfg, 'RES_CPU_WARN', '85')); ?>">
      <label>RAM warning</label>
      <input type="number" name="cfg[RES_MEM_WARN]" value="<?php echo h(cfgv($cfg, 'RES_MEM_WARN', '85')); ?>">
      <label>Disco warning</label>
      <input type="number" name="cfg[RES_DISK_WARN]" value="<?php echo h(cfgv($cfg, 'RES_DISK_WARN', '85')); ?>">
     </div>
     <div>
      <label>CPU critical</label>
      <input type="number" name="cfg[RES_CPU_CRIT]" value="<?php echo h(cfgv($cfg, 'RES_CPU_CRIT', '95')); ?>">
      <label>RAM critical</label>
      <input type="number" name="cfg[RES_MEM_CRIT]" value="<?php echo h(cfgv($cfg, 'RES_MEM_CRIT', '95')); ?>">
      <label>Disco critical</label>
      <input type="number" name="cfg[RES_DISK_CRIT]" value="<?php echo h(cfgv($cfg, 'RES_DISK_CRIT', '95')); ?>">
     </div>
    </div>
   </fieldset>

   <fieldset>
    <legend>Depuracion</legend>
    <label>DEBUG (logs verbosos)</label>
    <select name="cfg[DEBUG]">
     <option value="false" <?php echo cfgv($cfg, 'DEBUG', 'false') === 'false' ? 'selected' : ''; ?>>false</option>
     <option value="true" <?php echo cfgv($cfg, 'DEBUG', 'false') === 'true' ? 'selected' : ''; ?>>true</option>
    </select>
   </fieldset>

   <button class="primary" type="submit">Guardar configuracion</button>
  </form>

  <form method="post" action="?tab=config" style="margin-top:14px">
   <input type="hidden" name="csrf" value="<?php echo h($CSRF); ?>">
   <input type="hidden" name="action" value="test_notify">
   <input type="hidden" name="tab" value="config">
   <label><input type="checkbox" name="force" value="1"> Forzar prueba aunque el kill switch este activo</label>
   <button class="warn" type="submit">Enviar notificacion de prueba</button>
   <p class="muted">El token de Telegram solo se actualiza si escribes uno nuevo (el campo va vacio por seguridad).</p>
  </form>

 <?php endif; ?>

</div>
</body>
</html>
