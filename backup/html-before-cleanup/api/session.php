<?php
require '/var/www/private/Auth.php';

header('Cache-Control: no-store');
$id = current_user_id();
json_out(200, [
    'loggedIn' => $id > 0,
    'username' => $id > 0 ? (string) ($_SESSION['username'] ?? '') : '',
]);
