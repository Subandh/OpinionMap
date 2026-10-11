<?php
require '/var/www/private/Auth.php';

$userId = require_login();

if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
    json_out(405, ['error' => 'Use POST']);
}

$topic = trim((string) ($_POST['topic'] ?? ''));
if ($topic === '' || strlen($topic) > 200) {
    json_out(400, ['error' => 'Topic must be 1 to 200 characters']);
}

try {
    // One analysis at a time (protects your Apify credit)
    $busy = db()->query(
        "SELECT COUNT(*) FROM jobs
         WHERE status IN ('queued','collecting','analyzing') AND created_at > (NOW() - INTERVAL 20 MINUTE)"
    )->fetchColumn();
    if ((int) $busy > 0) {
        json_out(429, ['error' => 'Another analysis is still running. Please wait and try again.']);
    }

    // A new search replaces this user's previous raw data
    delete_user_raw_files($userId);

    $q = db()->prepare("INSERT INTO jobs (user_id, topic, status, message) VALUES (?, ?, 'queued', 'Starting...')");
    $q->execute([$userId, $topic]);
    $jobId = (int) db()->lastInsertId();

    $log = '/var/www/private/logs/job_' . $jobId . '.log';
    exec('nohup /usr/bin/php /var/www/private/worker.php ' . $jobId . ' > ' . escapeshellarg($log) . ' 2>&1 &');

    json_out(200, ['job_id' => $jobId]);
} catch (Throwable $e) {
    error_log('analyze.php: ' . $e->getMessage());
    json_out(500, ['error' => 'Server error']);
}
