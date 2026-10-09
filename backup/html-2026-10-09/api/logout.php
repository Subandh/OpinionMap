<?php
require '/var/www/private/Auth.php';

if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
    json_out(405, ['error' => 'Use POST']);
}

start_session();
$uid  = (int) ($_SESSION['user_id'] ?? 0);
$name = (string) ($_SESSION['username'] ?? '');

if ($uid > 0) {
    try {
        delete_user_raw_files($uid);          // raw data lives only while the user is logged in
        log_event('logout', $uid, $name);
    } catch (Throwable $e) {
        error_log('logout.php: ' . $e->getMessage());
    }
}
$_SESSION = [];
session_destroy();
json_out(200, ['ok' => true]);
