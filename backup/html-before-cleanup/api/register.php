<?php
require '/var/www/private/Auth.php';

if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
    json_out(405, ['error' => 'Use POST']);
}

$username = trim((string) ($_POST['username'] ?? ''));
$password = (string) ($_POST['password'] ?? '');

if (!preg_match('/^[A-Za-z0-9_]{3,30}$/', $username)) {
    json_out(400, ['error' => 'Username must be 3 to 30 letters, numbers or underscores.']);
}
if (strlen($password) < 8 || strlen($password) > 72) {
    json_out(400, ['error' => 'Password must be 8 to 72 characters.']);
}

try {
    $hash = password_hash($password, PASSWORD_DEFAULT);
    $q = db()->prepare('INSERT INTO users (username, password_hash) VALUES (?, ?)');
    $q->execute([$username, $hash]);
    $userId = (int) db()->lastInsertId();
} catch (PDOException $e) {
    if ($e->getCode() === '23000') {
        json_out(409, ['error' => 'That username is already taken.']);
    }
    error_log('register.php: ' . $e->getMessage());
    json_out(500, ['error' => 'Server error']);
}

start_session();
session_regenerate_id(true);
$_SESSION['user_id']  = $userId;
$_SESSION['username'] = $username;
log_event('register', $userId, $username);
json_out(201, ['username' => $username]);
