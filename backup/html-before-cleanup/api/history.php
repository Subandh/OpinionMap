<?php
require '/var/www/private/Auth.php';

$userId = require_login();
try {
    $q = db()->prepare(
        'SELECT id, topic, status, item_count, created_at
         FROM jobs WHERE user_id = ? ORDER BY id DESC LIMIT 20'
    );
    $q->execute([$userId]);
    json_out(200, ['jobs' => $q->fetchAll()]);
} catch (Throwable $e) {
    error_log('history.php: ' . $e->getMessage());
    json_out(500, ['error' => 'Database error']);
}
