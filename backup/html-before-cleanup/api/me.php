<?php
require '/var/www/private/Auth.php';

$id = current_user_id();
if ($id < 1) {
    json_out(401, ['error' => 'Not logged in']);
}
json_out(200, ['username' => (string) ($_SESSION['username'] ?? '')]);
