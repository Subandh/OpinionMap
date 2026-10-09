<?php
require '/var/www/private/Auth.php';

if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
    json_out(405, ['error' => 'Use POST']);
}

$username = trim((string) ($_POST['username'] ?? ''));
$password = (string) ($_POST['password'] ?? '');
if ($username === '' || $password === '') {
    json_out(400, ['error' => 'Enter your username and password.']);
}

try {
    $q = db()->prepare(
        'SELECT id, username, password_hash, failed_logins,
                (locked_until IS NOT NULL AND locked_until > NOW()) AS locked
         FROM users WHERE username = ?'
    );
    $q->execute([$username]);
    $u = $q->fetch();

    if ($u && (int) $u['locked'] === 1) {
        log_event('login_blocked', (int) $u['id'], $username);
        json_out(429, ['error' => 'Too many failed attempts. Try again in 10 minutes.']);
    }

    if ($u && password_verify($password, $u['password_hash'])) {
        db()->prepare('UPDATE users SET failed_logins = 0, locked_until = NULL, last_login_at = NOW() WHERE id = ?')
            ->execute([$u['id']]);
        start_session();
        session_regenerate_id(true);
        $_SESSION['user_id']  = (int) $u['id'];
        $_SESSION['username'] = $u['username'];
        log_event('login_ok', (int) $u['id'], $u['username']);
        json_out(200, ['username' => $u['username']]);
    }

    if ($u) {
        $fails = (int) $u['failed_logins'] + 1;
        if ($fails >= 5) {
            db()->prepare('UPDATE users SET failed_logins = 0, locked_until = NOW() + INTERVAL 10 MINUTE WHERE id = ?')
                ->execute([$u['id']]);
        } else {
            db()->prepare('UPDATE users SET failed_logins = ? WHERE id = ?')->execute([$fails, $u['id']]);
        }
        log_event('login_fail', (int) $u['id'], $username);
    } else {
        password_hash($password, PASSWORD_DEFAULT);   // takes the same time as a real check
        log_event('login_fail', null, $username);
    }
    json_out(401, ['error' => 'Wrong username or password.']);
} catch (Throwable $e) {
    error_log('login.php: ' . $e->getMessage());
    json_out(500, ['error' => 'Server error']);
}
