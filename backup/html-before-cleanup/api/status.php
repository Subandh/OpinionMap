<?php
require '/var/www/private/Auth.php';

$userId = require_login();
$id = (int) ($_GET['job_id'] ?? 0);
if ($id < 1) {
    json_out(400, ['error' => 'job_id is required']);
}
try {
    $q = db()->prepare('SELECT status, message, error_message FROM jobs WHERE id = ? AND user_id = ?');
    $q->execute([$id, $userId]);
    $row = $q->fetch();
} catch (Throwable $e) {
    error_log('status.php: ' . $e->getMessage());
    json_out(500, ['error' => 'Database error']);
}
if (!$row) {
    json_out(404, ['error' => 'Job not found']);
}
json_out(200, ['status' => $row['status'], 'message' => $row['message'], 'error' => $row['error_message']]);
