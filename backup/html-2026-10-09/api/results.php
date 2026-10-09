<?php
require '/var/www/private/Auth.php';

$userId = require_login();
$id = (int) ($_GET['job_id'] ?? 0);
if ($id < 1) {
    json_out(400, ['error' => 'job_id is required']);
}
try {
    $q = db()->prepare('SELECT id, status, result_json FROM jobs WHERE id = ? AND user_id = ?');
    $q->execute([$id, $userId]);
    $row = $q->fetch();
} catch (Throwable $e) {
    error_log('results.php: ' . $e->getMessage());
    json_out(500, ['error' => 'Database error']);
}
if (!$row) {
    json_out(404, ['error' => 'Job not found']);
}
$result = json_decode((string) $row['result_json'], true) ?: [];
$result['job_id'] = (int) $row['id'];
$result['status'] = $row['status'];
json_out(200, $result);
