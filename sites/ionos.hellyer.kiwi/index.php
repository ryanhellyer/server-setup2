<?php
/**
 * Test diagnostics page for the containerised stack.
 * Copied to /var/www/ionos.hellyer.kiwi/public/ by scripts/test-site.sh.
 * Remove for production.
 */
header('Content-Type: text/html; charset=utf-8');

function status($ok, $label, $detail = '') {
    return sprintf(
        "<tr><td><span style='color:%s'>%s</span></td><td><code>%s</code></td><td>%s</td></tr>",
        $ok ? 'green' : 'red', $ok ? 'OK' : 'FAIL', htmlspecialchars($label), htmlspecialchars($detail)
    );
}

$checks = [];
$checks[] = status(true, 'PHP version', PHP_VERSION . ' (FPM ' . (PHP_SAPI) . ')');
$checks[] = status(function_exists('opcache_get_status') ? (bool)@opcache_get_status() : false, 'OPcache', 'enabled/disabled');
$checks[] = status(extension_loaded('redis'), 'php-redis extension', '');
$checks[] = status(extension_loaded('imagick'), 'php-imagick', '');
$checks[] = status(extension_loaded('gd'), 'php-gd', '');
$checks[] = status(function_exists('exec') && trim(@shell_exec('ffmpeg -version 2>/dev/null | head -1')) !== '', 'ffmpeg', trim(@shell_exec('ffmpeg -version 2>/dev/null | head -1')));

// Valkey connectivity (drop-in Redis replacement; container reachable at both
// `valkey` and the legacy `redis` network alias from the php container).
$redis = false; $redisDetail = '';
$sock = @fsockopen('valkey', 6379, $errno, $errstr, 2);
if ($sock) {
    fwrite($sock, "PING\r\n");
    $resp = trim((string)fgets($sock));
    fclose($sock);
    $redis = strtoupper($resp) === '+PONG';
    $redisDetail = $resp;
}
$checks[] = status($redis, 'Valkey 127.0.0.1:6379 (alias redis)', $redisDetail);

// MariaDB connectivity (optional — only if creds are provided).
$db = null; $dbDetail = 'creds not provided (skip)';
$dbUser = getenv('DB_TEST_USER'); $dbPass = getenv('DB_TEST_PASSWORD');
if ($dbUser !== false && $dbPass !== false) {
    try {
        $pdo = new PDO('mysql:host=mariadb;port=3306', $dbUser, $dbPass, [PDO::ATTR_TIMEOUT => 2]);
        $db = true; $dbDetail = 'connected to mariadb';
    } catch (Throwable $e) { $db = false; $dbDetail = $e->getMessage(); }
}
$dbCell = $db === null
    ? "<tr><td><span style='color:orange'>SKIP</span></td><td><code>MariaDB (mariadb:3306)</code></td><td>$dbDetail</td></tr>"
    : status($db, 'MariaDB (mariadb:3306)', $dbDetail);
$checks[] = $dbCell;
?>
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Test server — ionos.hellyer.kiwi</title>
<style>body{font-family:system-ui,sans-serif;max-width:800px;margin:3rem auto;padding:0 1rem}table{border-collapse:collapse;width:100%}td,th{border:1px solid #ccc;padding:.5rem;text-align:left}th{background:#eee}</style>
</head>
<body>
<h1>TEST SERVER — ionos.hellyer.kiwi</h1>
<p>Containerised stack is running. Hostname: <code><?= htmlspecialchars((string)gethostname()) ?></code></p>
<table>
<tr><th>Status</th><th>Component</th><th>Detail</th></tr>
<?= implode("\n", $checks) ?>
</table>
</body>
</html>