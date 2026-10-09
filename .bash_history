        timer = setTimeout(function () { poll(jobId); }, 3000);
      }
    }).fail(function () { finish('Lost connection to the server.'); });
  }

  function run() {
    var topic = $.trim($('#topic').val());
    if (!topic) {
      $('#status').text('Please type a topic first.');
      return;
    }
    clearTimeout(timer);
    $('#results').prop('hidden', true);
    $('#status').text('Starting...');
    $('#analyzeBtn').prop('disabled', true);

    $.ajax({ url: 'api/analyze.php', method: 'POST', data: { topic: topic }, dataType: 'json' })
      .done(function (d) { poll(d.job_id); })
      .fail(function (xhr) {
        finish((xhr.responseJSON && xhr.responseJSON.error) || 'Something went wrong. Please try again.');
      });
  }

  $('#analyzeBtn').on('click', run);
  $('#topic').on('keypress', function (e) {
    if (e.which === 13) { run(); }
  });
});
EOF

which php
cat > /var/www/private/cleanup.php <<'EOF'
<?php
require __DIR__ . '/Database.php';

$maxAge   = 2 * 3600;            // raw files live at most 2 hours
$maxBytes = 300 * 1024 * 1024;   // hard cap for the whole raw folder
$removed  = 0;

$files = glob(__DIR__ . '/raw/job_*.json.gz') ?: [];
usort($files, fn($a, $b) => filemtime($a) <=> filemtime($b));   // oldest first
$total = array_sum(array_map('filesize', $files));

foreach ($files as $f) {
    if ((time() - filemtime($f)) > $maxAge || $total > $maxBytes) {
        $total -= filesize($f);
        unlink($f);
        db()->prepare('UPDATE jobs SET raw_file = NULL WHERE raw_file = ?')->execute([$f]);
        $removed++;
    }
}

// Cleaned text rows are kept 7 days (the finished results stay in the jobs table)
db()->exec("DELETE FROM comments WHERE job_id IN (SELECT id FROM jobs WHERE created_at < (NOW() - INTERVAL 7 DAY))");

// Old logs
foreach (glob(__DIR__ . '/logs/job_*.log') ?: [] as $l) {
    if (time() - filemtime($l) > 7 * 86400) {
        unlink($l);
    }
}
echo date('Y-m-d H:i:s') . " cleanup done, raw files removed: {$removed}\n";
EOF

php /var/www/private/cleanup.php
sudo systemctl enable --now cron
(crontab -l 2>/dev/null; echo "*/15 * * * * /usr/bin/php /var/www/private/cleanup.php >> /var/www/private/logs/cleanup.log 2>&1") | crontab -
crontab -l
ls -t /var/www/private/logs | head -3
tail -n 20 /var/www/private/logs/job_3.log
sed -i "s/'max_items_per_source' => 30/'max_items_per_source' => 500/" /var/www/private/apify.php
df -h /
sudo mariadb opinionmap <<'EOF'
CREATE TABLE IF NOT EXISTS users (
  id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  username VARCHAR(30) NOT NULL,
  password_hash VARCHAR(255) NOT NULL,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  last_login_at DATETIME NULL,
  failed_logins TINYINT UNSIGNED NOT NULL DEFAULT 0,
  locked_until DATETIME NULL,
  UNIQUE KEY uq_username (username)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS auth_log (
  id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  user_id INT UNSIGNED NULL,
  username VARCHAR(50) NOT NULL,
  event ENUM('register','login_ok','login_fail','login_blocked','logout') NOT NULL,
  ip VARCHAR(45) NOT NULL,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  KEY idx_user (user_id),
  KEY idx_created (created_at)
) ENGINE=InnoDB;

ALTER TABLE jobs
  ADD COLUMN IF NOT EXISTS user_id INT UNSIGNED NULL,
  ADD INDEX IF NOT EXISTS idx_jobs_user (user_id);
EOF

sudo mariadb opinionmap -e "SHOW TABLES;"
cat > /var/www/private/Auth.php <<'EOF'
<?php
require_once __DIR__ . '/Database.php';

function start_session(): void
{
    if (session_status() === PHP_SESSION_NONE) {
        session_name('opinionmap');
        session_set_cookie_params([
            'lifetime' => 0,
            'path'     => '/',
            'secure'   => !empty($_SERVER['HTTPS']),
            'httponly' => true,
            'samesite' => 'Lax',
        ]);
        session_start();
    }
}

function json_out(int $code, array $data): void
{
    http_response_code($code);
    header('Content-Type: application/json');
    echo json_encode($data, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    exit;
}

function current_user_id(): int
{
    start_session();
    $id = (int) ($_SESSION['user_id'] ?? 0);
    session_write_close();      // release the session lock so other requests are not blocked
    return $id;
}

function require_login(): int
{
    $id = current_user_id();
    if ($id < 1) {
        json_out(401, ['error' => 'Please log in first.']);
    }
    return $id;
}

function log_event(string $event, ?int $userId, string $username): void
{
    try {
        db()->prepare('INSERT INTO auth_log (user_id, username, event, ip) VALUES (?, ?, ?, ?)')
            ->execute([$userId, substr($username, 0, 50), $event, $_SERVER['REMOTE_ADDR'] ?? '']);
    } catch (Throwable $e) {
        error_log('log_event: ' . $e->getMessage());
    }
}

// Delete the compressed raw Apify files that belong to one user
function delete_user_raw_files(int $userId): void
{
    $q = db()->prepare('SELECT raw_file FROM jobs WHERE user_id = ? AND raw_file IS NOT NULL');
    $q->execute([$userId]);
    foreach ($q->fetchAll() as $row) {
        $f = (string) $row['raw_file'];
        if (strpos($f, '/var/www/private/raw/') === 0 && is_file($f)) {
            @unlink($f);
        }
    }
    db()->prepare('UPDATE jobs SET raw_file = NULL WHERE user_id = ?')->execute([$userId]);
}
EOF

cat > /var/www/html/api/register.php <<'EOF'
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
EOF

cat > /var/www/html/api/login.php <<'EOF'
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
EOF

cat > /var/www/html/api/logout.php <<'EOF'
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
EOF

cat > /var/www/html/api/me.php <<'EOF'
<?php
require '/var/www/private/Auth.php';

$id = current_user_id();
if ($id < 1) {
    json_out(401, ['error' => 'Not logged in']);
}
json_out(200, ['username' => (string) ($_SESSION['username'] ?? '')]);
EOF

cat > /var/www/html/api/history.php <<'EOF'
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
EOF

cat > /var/www/html/api/analyze.php <<'EOF'
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
EOF

cat > /var/www/html/api/status.php <<'EOF'
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
EOF

cat > /var/www/html/api/results.php <<'EOF'
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
EOF

cat > /var/www/html/index.html <<'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>OpinionMap</title>
  <link rel="stylesheet" href="css/style.css">
</head>
<body>
  <header>
    <h1>OpinionMap</h1>
    <p>Enter a topic to see the majority voice, minority views and outliers in online discussions.</p>
    <div id="userBar" hidden>Logged in as <strong id="userName"></strong>
      <button id="logoutBtn" class="link">Log out</button></div>
  </header>

  <main>
    <section id="authBox" class="card" hidden>
      <h2 id="authTitle">Log in</h2>
      <input type="text" id="authUser" placeholder="Username" maxlength="30" autocomplete="username">
      <input type="password" id="authPass" placeholder="Password (8+ characters)" maxlength="72" autocomplete="current-password">
      <button id="authBtn">Log in</button>
      <p id="authMsg"></p>
      <p><a href="#" id="authSwitch">New here? Create an account</a></p>
    </section>

    <section id="appBox" hidden>
      <div class="search">
        <input type="text" id="topic" placeholder="e.g. Artificial Intelligence in Education" maxlength="200">
        <button id="analyzeBtn">Analyze</button>
      </div>
      <p id="status"></p>

      <section id="results" hidden>
        <p id="demoNote" class="note" hidden></p>
        <h2 id="resTopic"></h2>
        <p id="resMeta"></p>

        <div class="cards">
          <div class="card"><h3>Majority viewpoint</h3><div id="majority"></div></div>
          <div class="card"><h3>Stance distribution</h3><div id="stance"></div></div>
        </div>
        <div class="card"><h3>Major themes</h3><ul id="themes"></ul></div>
        <div class="card"><h3>Potential outliers</h3><ul id="outliers"></ul></div>
        <div class="card"><h3>Sample collected posts</h3><ul id="samples"></ul></div>
      </section>

      <div class="card"><h3>Your past searches</h3><ul id="history" class="history"></ul></div>
    </section>
  </main>

  <script src="https://cdnjs.cloudflare.com/ajax/libs/jquery/3.7.1/jquery.min.js"></script>
  <script src="js/app.js"></script>
</body>
</html>
EOF

cat >> /var/www/html/css/style.css <<'EOF'

[hidden] { display: none !important; }
#authBox { max-width: 380px; margin: 0 auto 16px; display: flex; flex-direction: column; gap: 10px; }
#authBox h2 { margin: 0; }
#authBox input { padding: 12px; font-size: 16px; border: 1px solid #bbb; border-radius: 6px; }
#authBox button { padding: 12px; font-size: 16px; background: #1f3a5f; color: #fff; border: 0; border-radius: 6px; cursor: pointer; }
#authBox button:disabled { background: #999; }
#authMsg { color: #b00020; min-height: 20px; margin: 0; }
#userBar { margin-top: 10px; font-size: 14px; }
button.link { background: none; border: 0; color: #cfe3ff; text-decoration: underline; cursor: pointer; font-size: 14px; }
.history { list-style: none; padding: 0; margin: 0; }
.history li { padding: 8px 4px; border-bottom: 1px solid #eee; cursor: pointer; }
.history li:hover { background: #f4f6f8; }
.history .meta { color: #777; font-size: 13px; }
EOF

cat > /var/www/html/js/app.js <<'EOF'
$(function () {
  var timer = null;
  var mode = 'login';

  // ---------- screens ----------
  function showApp(username) {
    $('#authBox').prop('hidden', true);
    $('#appBox, #userBar').prop('hidden', false);
    $('#userName').text(username);
    loadHistory();
  }

  function showAuth() {
    clearTimeout(timer);
    $('#appBox, #userBar, #results').prop('hidden', true);
    $('#authBox').prop('hidden', false);
    $('#authPass').val('');
    $('#history').empty();
    $('#status').text('');
    $('#analyzeBtn').prop('disabled', false);
  }

  function setMode(m) {
    mode = m;
    $('#authTitle').text(m === 'login' ? 'Log in' : 'Create an account');
    $('#authBtn').text(m === 'login' ? 'Log in' : 'Sign up');
    $('#authSwitch').text(m === 'login' ? 'New here? Create an account' : 'Already have an account? Log in');
    $('#authPass').attr('autocomplete', m === 'login' ? 'current-password' : 'new-password');
    $('#authMsg').text('');
  }

  // ---------- login / sign-up ----------
  function submitAuth() {
    $('#authMsg').text('');
    $('#authBtn').prop('disabled', true);
    $.ajax({
      url: 'api/' + (mode === 'login' ? 'login.php' : 'register.php'),
      method: 'POST',
      data: { username: $.trim($('#authUser').val()), password: $('#authPass').val() },
      dataType: 'json'
    }).done(function (d) {
      showApp(d.username);
    }).fail(function (xhr) {
      $('#authMsg').text((xhr.responseJSON && xhr.responseJSON.error) || 'Something went wrong.');
    }).always(function () {
      $('#authBtn').prop('disabled', false);
    });
  }

  // ---------- results ----------
  function finish(msg) {
    clearTimeout(timer);
    $('#status').text(msg || '');
    $('#analyzeBtn').prop('disabled', false);
  }

  function render(d) {
    $('#resTopic').text('Topic: ' + d.topic);
    $('#resMeta').text('Responses analyzed: ' + d.total +
      ' (Reddit: ' + d.sources.reddit + ', X: ' + d.sources.x + ')');
    $('#demoNote').prop('hidden', !d.demo)
      .text('Counts and sample posts are real. Stance, themes and outliers are demo values until the analysis step is added.');

    $('#majority').empty().append(
      $('<div class="big">').text(d.majority.percent + '% ' + d.majority.label)
    );

    var $stance = $('#stance').empty();
    $.each(d.stance, function (name, pct) {
      var $row = $('<div class="bar-row">');
      $row.append($('<span class="bar-label">').text(name + ' ' + pct + '%'));
      $row.append($('<div class="bar">').append($('<div class="fill">').css('width', pct + '%')));
      $stance.append($row);
    });

    var $themes = $('#themes').empty();
    $.each(d.themes, function (i, t) {
      $themes.append($('<li>').text(t.label + ' - ' + t.share + '%'));
    });

    var $outliers = $('#outliers').empty();
    $.each(d.outliers, function (i, o) {
      $outliers.append($('<li>').text('"' + o.text + '" - ' + o.reason));
    });

    var $samples = $('#samples').empty();
    $.each(d.samples || [], function (i, s) {
      var where = s.community ? ' r/' + s.community : '';
      $samples.append($('<li>').text('[' + s.source + where + '] ' + s.text + ' (score ' + s.score + ')'));
    });

    $('#results').prop('hidden', false);
  }

  function poll(jobId) {
    $.getJSON('api/status.php', { job_id: jobId }).done(function (s) {
      if (s.status === 'done') {
        $.getJSON('api/results.php', { job_id: jobId }).done(function (d) {
          render(d);
          finish((d.warnings && d.warnings.length) ? 'Note: ' + d.warnings.join(' | ') : '');
          loadHistory();
        }).fail(function () { finish('Could not load the results.'); });
      } else if (s.status === 'failed') {
        finish('Analysis failed: ' + (s.error || 'unknown error'));
        loadHistory();
      } else {
        $('#status').text(s.message || 'Working...');
        timer = setTimeout(function () { poll(jobId); }, 3000);
      }
    }).fail(function (xhr) {
      if (xhr.status === 401) { showAuth(); } else { finish('Lost connection to the server.'); }
    });
  }

  function run() {
    var topic = $.trim($('#topic').val());
    if (!topic) {
      $('#status').text('Please type a topic first.');
      return;
    }
    clearTimeout(timer);
    $('#results').prop('hidden', true);
    $('#status').text('Starting...');
    $('#analyzeBtn').prop('disabled', true);

    $.ajax({ url: 'api/analyze.php', method: 'POST', data: { topic: topic }, dataType: 'json' })
      .done(function (d) { poll(d.job_id); })
      .fail(function (xhr) {
        if (xhr.status === 401) { showAuth(); return; }
        finish((xhr.responseJSON && xhr.responseJSON.error) || 'Something went wrong. Please try again.');
      });
  }

  // ---------- history ----------
  function loadHistory() {
    $.getJSON('api/history.php').done(function (d) {
      var $h = $('#history').empty();
      if (!d.jobs.length) {
        $h.append($('<li class="meta">').text('No searches yet.'));
        return;
      }
      $.each(d.jobs, function (i, j) {
        var $li = $('<li>').data('id', j.id);
        $li.append($('<div>').text(j.topic));
        $li.append($('<div class="meta">').text(
          j.created_at + ' - ' + j.status + (j.item_count > 0 ? ' - ' + j.item_count + ' items' : '')));
        $h.append($li);
      });
    }).fail(function (xhr) {
      if (xhr.status === 401) { showAuth(); }
    });
  }

  $('#history').on('click', 'li', function () {
    var id = $(this).data('id');
    if (!id) { return; }
    clearTimeout(timer);
    $('#results').prop('hidden', true);
    $('#status').text('Loading...');
    poll(id);
  });

  // ---------- wiring ----------
  $('#authBtn').on('click', submitAuth);
  $('#authSwitch').on('click', function (e) {
    e.preventDefault();
    setMode(mode === 'login' ? 'register' : 'login');
  });
  $('#authUser, #authPass').on('keypress', function (e) {
    if (e.which === 13) { submitAuth(); }
  });
  $('#logoutBtn').on('click', function () {
    $.post('api/logout.php').always(function () { showAuth(); });
  });
  $('#analyzeBtn').on('click', run);
  $('#topic').on('keypress', function (e) {
    if (e.which === 13) { run(); }
  });

  setMode('login');
  $.getJSON('api/me.php').done(function (d) { showApp(d.username); }).fail(function () { showAuth(); });
});
EOF

sudo tail -n 20 /var/log/apache2/error.log
sed -i "s|'x_actor' => ''|'x_actor' => 'kaitoeasyapi/twitter-x-data-tweet-scraper-pay-per-result-cheapest'|" /var/www/private/apify.php
grep x_actor /var/www/private/apify.php
sed -i "s|\[\$topic\], 'maxItems'|[\$topic . ' lang:en -filter:retweets'], 'maxItems'|" /var/www/private/worker.php
grep -n "lang:en" /var/www/private/worker.php
sudo mariadb opinionmap -e "INSERT INTO jobs (topic, status) VALUES ('AI in education', 'queued'); SELECT LAST_INSERT_ID() AS job_id;"
php /var/www/private/worker.php 3
/var/www/private/worker.php
ls -l /var/www/private /var/www/private/raw /var/www/private/logs
cat > /var/www/private/worker.php <<'EOF'
<?php
require __DIR__ . '/Database.php';
require __DIR__ . '/Apify.php';
require __DIR__ . '/Normalize.php';

$jobId = (int) ($argv[1] ?? 0);
if ($jobId < 1) {
    fwrite(STDERR, "Usage: php worker.php JOB_ID\n");
    exit(1);
}

function say(int $id, string $status, string $msg): void
{
    echo date('H:i:s') . " [{$status}] {$msg}\n";
    db()->prepare('UPDATE jobs SET status = ?, message = ? WHERE id = ?')->execute([$status, $msg, $id]);
}

function reddit_input(string $topic, int $limit): array
{
    return [
        'searches'          => [$topic],
        'searchPosts'       => true,
        'searchComments'    => false,
        'searchCommunities' => false,
        'searchUsers'       => false,
        'ignoreStartUrls'   => true,
        'skipComments'      => false,
        'skipUserPosts'     => true,
        'skipCommunity'     => true,
        'includeNSFW'       => false,
        'sort'              => 'relevance',
        'time'              => 'year',
        'maxItems'          => $limit,
        'maxPostCount'      => max(3, (int) ceil($limit / 10)),
        'maxComments'       => 10,
        'scrollTimeout'     => 40,
        'navigationTimeout' => 60,
        'proxy'             => ['useApifyProxy' => true, 'apifyProxyGroups' => ['RESIDENTIAL']],
    ];
}

function x_input(string $topic, int $limit): array
{
    $extra = apify_cfg()['x_extra_input'] ?? [];
    return array_merge(['searchTerms' => [$topic . ' lang:en -filter:retweets'], 'maxItems' => $limit], $extra);
}

$stmt = db()->prepare('SELECT topic FROM jobs WHERE id = ?');
$stmt->execute([$jobId]);
$topic = $stmt->fetchColumn();
if ($topic === false) {
    fwrite(STDERR, "Job {$jobId} not found\n");
    exit(1);
}

$cfg       = apify_cfg();
$perSource = (int) ($cfg['max_items_per_source'] ?? 30);

$sources = [];
if (!empty($cfg['reddit_actor'])) {
    $sources['reddit'] = [$cfg['reddit_actor'], reddit_input($topic, $perSource), 'normalize_reddit_item'];
}
if (!empty($cfg['x_actor'])) {
    $sources['x'] = [$cfg['x_actor'], x_input($topic, $perSource), 'normalize_x_item'];
}

try {
    $raw      = [];
    $rows     = [];
    $warnings = [];

    foreach ($sources as $name => [$actor, $input, $normalize]) {
        say($jobId, 'collecting', 'Collecting from ' . ucfirst($name) . '...');
        try {
            $items = apify_run_and_collect($actor, $input, $perSource);
        } catch (Throwable $e) {
            $warnings[] = ucfirst($name) . ': ' . $e->getMessage();
            echo 'WARNING ' . end($warnings) . "\n";
            continue;
        }
        $raw[$name] = $items;
        foreach ($items as $item) {
            $row = $normalize($item);
            if ($row !== null) {
                $rows[] = $row;
            }
        }
    }
    if (!$raw) {
        throw new RuntimeException($warnings ? implode(' | ', $warnings) : 'No data source is configured');
    }

    // Raw data, exactly as Apify returned it, compressed
    $file = __DIR__ . "/raw/job_{$jobId}.json.gz";
    file_put_contents($file, gzencode(json_encode($raw, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES), 6));

    // Cleaned rows
    $pdo = db();
    $ins = $pdo->prepare(
        'INSERT IGNORE INTO comments (job_id, source, external_id, kind, community, body, score, created_at_src, url)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)'
    );
    $pdo->beginTransaction();
    foreach ($rows as $r) {
        $ins->execute([$jobId, $r['source'], $r['external_id'], $r['kind'], $r['community'],
                       $r['body'], $r['score'], $r['created'], $r['url']]);
    }
    $pdo->commit();

    $counts = ['reddit' => 0, 'x' => 0];
    $q = $pdo->prepare('SELECT source, COUNT(*) AS n FROM comments WHERE job_id = ? GROUP BY source');
    $q->execute([$jobId]);
    foreach ($q->fetchAll() as $c) {
        $counts[$c['source']] = (int) $c['n'];
    }
    $total = array_sum($counts);
    if ($total === 0) {
        throw new RuntimeException('The actor returned no usable posts. Check its input settings.');
    }

    $q = $pdo->prepare('SELECT source, kind, community, LEFT(body, 280) AS text, score, url
                        FROM comments WHERE job_id = ? ORDER BY score DESC LIMIT 5');
    $q->execute([$jobId]);

    $result = [
        'demo'     => true,   // stance, themes and outliers stay demo values until the Python step
        'topic'    => $topic,
        'total'    => $total,
        'sources'  => $counts,
        'majority' => ['label' => 'Supportive', 'percent' => 61],
        'stance'   => ['supportive' => 61, 'opposed' => 27, 'neutral' => 12],
        'themes'   => [
            ['label' => 'Personalized learning', 'share' => 24],
            ['label' => 'Accessibility',         'share' => 19],
            ['label' => 'Productivity',          'share' => 17],
            ['label' => 'Academic integrity',    'share' => 21],
            ['label' => 'Privacy',               'share' => 11],
        ],
        'outliers' => [
            ['text' => 'Sample unusual viewpoint', 'reason' => 'low similarity to all other posts'],
            ['text' => 'Sample rare theme',        'reason' => 'appears in under 1% of posts'],
        ],
        'samples'  => $q->fetchAll(),
        'warnings' => $warnings,
    ];

    $pdo->prepare("UPDATE jobs SET status = 'done', message = 'Done', result_json = ?, raw_file = ?,
                   item_count = ?, finished_at = NOW() WHERE id = ?")
        ->execute([json_encode($result, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES), $file, $total, $jobId]);
    echo "Done: {$total} items stored\n";

} catch (Throwable $e) {
    echo 'FAILED: ' . $e->getMessage() . "\n";
    if (db()->inTransaction()) {
        db()->rollBack();
    }
    db()->prepare("UPDATE jobs SET status = 'failed', error_message = ?, finished_at = NOW() WHERE id = ?")
        ->execute([substr($e->getMessage(), 0, 500), $jobId]);
    exit(1);
}
EOF

tail -n 3 /var/www/private/worker.php
php -l /var/www/private/worker.php
php /var/www/private/worker.php 3
sudo mariadb opinionmap -e "SELECT source, kind, COUNT(*) AS n FROM comments WHERE job_id = 5 GROUP BY source, kind; SELECT source, score, LEFT(body, 100) AS text FROM comments WHERE job_id = 3 AND source = 'x' LIMIT 3;" 
df -h /
sudo mariadb opinionmap <<'EOF'
ALTER TABLE comments
  ADD COLUMN IF NOT EXISTS stance ENUM('supportive','opposed','neutral') NULL,
  ADD COLUMN IF NOT EXISTS sentiment_score FLOAT NULL,
  ADD COLUMN IF NOT EXISTS cluster_id INT NULL,
  ADD COLUMN IF NOT EXISTS outlier_score FLOAT NULL,
  ADD COLUMN IF NOT EXISTS is_outlier TINYINT(1) NOT NULL DEFAULT 0;
EOF

sudo mariadb opinionmap -e "DESCRIBE comments;"
sudo mkdir -p /var/www/private/python /var/www/private/tmp
sudo chown ubuntu:www-data /var/www/private/python /var/www/private/tmp
sudo chmod 2750 /var/www/private/python
sudo chmod 2770 /var/www/private/tmp
cd /var/www/private/python
python3 -m venv venv
./venv/bin/pip install --upgrade pip
./venv/bin/pip install --only-binary=:all: numpy scipy scikit-learn vaderSentiment
./venv/bin/python -c "import numpy, scipy, sklearn, vaderSentiment; print('python ok', sklearn.__version__)"
sudo -u www-data /var/www/private/python/venv/bin/python -c "import sklearn; print('apache user ok')"
du -sh venv
df -h /
cat > /var/www/private/python/analyze.py <<'EOF'
#!/usr/bin/env python3
"""Usage: python analyze.py INPUT.json OUTPUT.json

Reads collected posts, then works out:
  1. stance (estimated from sentiment)
  2. themes (TF-IDF + clustering)
  3. outliers (Local Outlier Factor)
and writes per-row labels plus the dashboard result as JSON.
"""
import html
import json
import re
import sys
import warnings
from collections import Counter

import numpy as np
from sklearn.cluster import KMeans
from sklearn.decomposition import TruncatedSVD
from sklearn.feature_extraction.text import ENGLISH_STOP_WORDS, TfidfVectorizer
from sklearn.metrics import silhouette_score
from sklearn.neighbors import LocalOutlierFactor
from sklearn.preprocessing import Normalizer
from vaderSentiment.vaderSentiment import SentimentIntensityAnalyzer

warnings.filterwarnings("ignore")

# ---- settings you can tune ----
POS_T, NEG_T = 0.2, -0.2     # sentiment above/below these counts as supportive/opposed
MIN_WORDS = 4                # shorter texts are skipped
MAX_THEMES = 6
OUTLIER_SHARE = 0.03         # flag roughly the 3% most unusual items
EXTRA_STOP = {
    "like", "just", "people", "think", "really", "would", "could", "also", "one", "get", "got",
    "dont", "don", "doesn", "didn", "isn", "ve", "ll", "re", "https", "http", "www", "com",
    "amp", "gt", "lt", "im", "thats", "use", "even", "much", "make", "know", "going", "yeah",
}
LABELS = {"supportive": "Supportive", "opposed": "Opposed", "neutral": "Neutral or uncertain"}

URL_RE = re.compile(r"https?://\S+|www\.\S+")
MENTION_RE = re.compile(r"(?<!\w)@\w+")


def strip_links(text):
    t = html.unescape(text or "")
    t = URL_RE.sub(" ", t)
    t = MENTION_RE.sub(" ", t)
    return re.sub(r"\s+", " ", t).strip()


def normalize(text):
    t = re.sub(r"[#*_>~`\[\]()]", " ", text.lower())
    return re.sub(r"\s+", " ", t).strip()


def snippet(text, n):
    return text if len(text) <= n else text[:n].rstrip() + "..."


def top_terms(centroid, names, n=3):
    chosen, used = [], set()
    for i in centroid.argsort()[::-1][:40]:
        words = set(names[i].split())
        if words & used:
            continue
        chosen.append(names[i])
        used |= words
        if len(chosen) == n:
            break
    return ", ".join(chosen) if chosen else "miscellaneous"


def choose_k(Z, n):
    max_k = min(8, n // 10)
    if max_k < 3:
        return 2
    best_k, best = 3, -1.0
    for k in range(3, max_k + 1):
        labels = KMeans(n_clusters=k, n_init=5, random_state=42).fit_predict(Z)
        if len(set(labels)) < 2:
            continue
        s = silhouette_score(Z, labels)
        if s > best:
            best_k, best = k, s
    return best_k


def main():
    if len(sys.argv) != 3:
        sys.exit("Usage: python analyze.py INPUT.json OUTPUT.json")
    with open(sys.argv[1], encoding="utf-8") as f:
        data = json.load(f)
    topic = data.get("topic") or ""
    rows = sorted(data.get("rows", []), key=lambda r: -(r.get("score") or 0))
    total_in = len(rows)

    # 1. Clean, skip junk, remove duplicates (keeping the best-scored copy)
    kept, seen = [], set()
    for r in rows:
        body = (r.get("body") or "").strip()
        if body.lower() in ("[deleted]", "[removed]"):
            continue
        raw = strip_links(body)
        clean = normalize(raw)
        if len(clean.split()) < MIN_WORDS or clean in seen:
            continue
        seen.add(clean)
        r["_raw"], r["_clean"] = raw, clean
        kept.append(r)
    n = len(kept)
    if n == 0:
        sys.exit("No usable text to analyze (everything was too short, deleted or duplicated)")
    skipped = total_in - n

    # 2. Sentiment -> stance estimate
    vader = SentimentIntensityAnalyzer()
    for r in kept:
        c = vader.polarity_scores(r["_raw"])["compound"]
        r["sentiment"] = c
        r["stance"] = "supportive" if c >= POS_T else ("opposed" if c <= NEG_T else "neutral")
        r["cluster"], r["outlier"], r["is_outlier"] = None, 0.0, 0

    # 3. Themes and outliers
    themes = []
    X = None
    vec = None
    topic_words = set(re.findall(r"[a-z]{2,}", topic.lower()))
    stop = list(ENGLISH_STOP_WORDS | EXTRA_STOP | topic_words)
    if n >= 10:
        vec = TfidfVectorizer(stop_words=stop, ngram_range=(1, 2),
                              min_df=2 if n >= 30 else 1, max_df=0.6,
                              max_features=4000, sublinear_tf=True)
        try:
            X = vec.fit_transform([r["_clean"] for r in kept])
        except ValueError:
            X = None

    if X is not None and X.shape[1] >= 3:
        names = vec.get_feature_names_out()
        comps = min(50, X.shape[1] - 1, n - 1)
        Z = TruncatedSVD(n_components=comps, random_state=42).fit_transform(X)
        Z = Normalizer(copy=False).fit_transform(Z)
        labels = KMeans(n_clusters=choose_k(Z, n), n_init=10, random_state=42).fit_predict(Z)
        for r, c in zip(kept, labels):
            r["cluster"] = int(c)
        for cid, size in Counter(labels.tolist()).most_common(MAX_THEMES):
            centroid = np.asarray(X[np.where(labels == cid)[0]].mean(axis=0)).ravel()
            themes.append({"label": top_terms(centroid, names), "share": round(100 * size / n, 1)})

        if n >= 20:
            lof = LocalOutlierFactor(n_neighbors=min(20, n - 1), contamination=OUTLIER_SHARE)
            flags = lof.fit_predict(Z)
            scores = np.nan_to_num(-lof.negative_outlier_factor_, nan=0.0, posinf=0.0)
            for r, flag, s in zip(kept, flags, scores):
                r["outlier"], r["is_outlier"] = round(float(s), 3), int(flag == -1)
    if not themes:
        themes = [{"label": "all posts (too few for theme detection)", "share": 100.0}]

    # 4. Stance split, samples, statistics
    counts = Counter(r["stance"] for r in kept)
    pct = {k: round(100 * counts.get(k, 0) / n, 1) for k in LABELS}
    ranked = sorted(pct.items(), key=lambda kv: -kv[1])
    top_key, top_pct = ranked[0]
    majority = {"label": LABELS[top_key] + ("" if top_pct >= 50 else " (largest group)"),
                "percent": top_pct}

    samples = []
    for key, _ in ranked:
        group = [r for r in kept if r["stance"] == key]
        group.sort(key=lambda r: (-(r.get("score") or 0), -abs(r["sentiment"])))
        for r in group[:2]:
            samples.append({"source": r["source"], "kind": r["kind"], "community": r.get("community"),
                            "text": snippet(r["_raw"], 280), "score": r.get("score") or 0,
                            "url": r.get("url"), "stance": key})

    flagged = sorted((r for r in kept if r["is_outlier"]), key=lambda r: -r["outlier"])[:5]
    outliers = [{"text": snippet(r["_raw"], 200),
                 "reason": "unusual wording compared with the rest of the discussion "
                           "(outlier score %.2f; typical is about 1.0)" % r["outlier"]}
                for r in flagged]
    if n < 20:
        outliers = [{"text": "Not enough items to detect outliers",
                     "reason": "needs at least 20 analyzed items"}]
    elif not outliers:
        outliers = [{"text": "No clear outliers found", "reason": "nothing stood out from the rest"}]

    by_source = Counter(r["source"] for r in kept)
    by_kind = Counter(r["kind"] for r in kept)
    dates = sorted(r["created"][:10] for r in kept if r.get("created"))
    n_out = sum(r["is_outlier"] for r in kept)
    avg = sum(r["sentiment"] for r in kept) / n

    stats = [
        "Items analyzed: %d (%s)" % (n, ", ".join("%s %d" % (k, v) for k, v in by_source.items())),
        "Types: " + ", ".join("%s %d" % (k, v) for k, v in by_kind.items()),
        "Average sentiment: %+.2f (scale -1 to +1)" % avg,
        "%s group: %s %.1f%%" % ("Majority" if top_pct >= 50 else "Largest", LABELS[top_key], top_pct),
    ]
    if ranked[1][1] > 0:
        stats.append("Largest minority group: %s %.1f%%" % (LABELS[ranked[1][0]], ranked[1][1]))
    stats.append("Themes found: %d; outliers flagged: %d" % (len(themes), n_out))
    if dates:
        stats.append("Posts dated %s to %s" % (dates[0], dates[-1]))
    if skipped:
        stats.append("Skipped (too short, deleted or duplicate): %d" % skipped)

    result = {
        "demo": False,
        "total": n,
        "sources": {"reddit": by_source.get("reddit", 0), "x": by_source.get("x", 0)},
        "majority": majority,
        "stance": pct,
        "themes": themes,
        "outliers": outliers,
        "samples": samples,
        "stats": stats,
    }
    out_rows = [{"id": r["id"], "stance": r["stance"], "sentiment": round(r["sentiment"], 3),
                 "cluster": r["cluster"], "outlier": r["outlier"], "is_outlier": r["is_outlier"]}
                for r in kept]
    with open(sys.argv[2], "w", encoding="utf-8") as f:
        json.dump({"rows": out_rows, "result": result}, f, ensure_ascii=False)
    print("Analyzed %d items: %d themes, %d outliers" % (n, len(themes), n_out))


if __name__ == "__main__":
    main()
EOF

cat > /var/www/private/Analysis.php <<'EOF'
<?php
require_once __DIR__ . '/Database.php';

// Runs the Python analysis for a job whose text is already in the comments table.
// Saves per-row labels and returns the result array for the dashboard.
function run_analysis(int $jobId, string $topic, array $warnings = []): array
{
    $pdo = db();
    $q = $pdo->prepare(
        'SELECT id, source, kind, community, body, score, created_at_src AS created, url
         FROM comments WHERE job_id = ?'
    );
    $q->execute([$jobId]);
    $rows = $q->fetchAll();
    if (!$rows) {
        throw new RuntimeException('No collected text to analyze');
    }

    $in  = __DIR__ . "/tmp/job_{$jobId}_in.json";
    $out = __DIR__ . "/tmp/job_{$jobId}_out.json";
    file_put_contents($in, json_encode(
        ['topic' => $topic, 'rows' => $rows],
        JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_INVALID_UTF8_SUBSTITUTE
    ));

    $cmd = escapeshellarg(__DIR__ . '/python/venv/bin/python') . ' '
         . escapeshellarg(__DIR__ . '/python/analyze.py') . ' '
         . escapeshellarg($in) . ' ' . escapeshellarg($out) . ' 2>&1';
    exec($cmd, $lines, $code);
    echo implode("\n", $lines) . "\n";
    @unlink($in);

    if ($code !== 0 || !is_file($out)) {
        @unlink($out);
        throw new RuntimeException('Analysis failed: ' . substr(implode(' ', $lines), -300));
    }
    $data = json_decode((string) file_get_contents($out), true);
    @unlink($out);
    if (!is_array($data) || !isset($data['result'], $data['rows'])) {
        throw new RuntimeException('Analysis returned unreadable output');
    }

    $upd = $pdo->prepare(
        'UPDATE comments SET stance = ?, sentiment_score = ?, cluster_id = ?, outlier_score = ?, is_outlier = ?
         WHERE id = ?'
    );
    $pdo->beginTransaction();
    foreach ($data['rows'] as $r) {
        $upd->execute([$r['stance'], $r['sentiment'], $r['cluster'], $r['outlier'], $r['is_outlier'], $r['id']]);
    }
    $pdo->commit();

    $result = $data['result'];
    $result['topic']    = $topic;
    $result['warnings'] = $warnings;
    return $result;
}
EOF

cat > /var/www/private/worker.php <<'EOF'
<?php
require __DIR__ . '/Database.php';
require __DIR__ . '/Apify.php';
require __DIR__ . '/Normalize.php';
require __DIR__ . '/Analysis.php';

$jobId = (int) ($argv[1] ?? 0);
if ($jobId < 1) {
    fwrite(STDERR, "Usage: php worker.php JOB_ID\n");
    exit(1);
}

function say(int $id, string $status, string $msg): void
{
    echo date('H:i:s') . " [{$status}] {$msg}\n";
    db()->prepare('UPDATE jobs SET status = ?, message = ? WHERE id = ?')->execute([$status, $msg, $id]);
}

function reddit_input(string $topic, int $limit): array
{
    return [
        'searches'          => [$topic],
        'searchPosts'       => true,
        'searchComments'    => false,
        'searchCommunities' => false,
        'searchUsers'       => false,
        'ignoreStartUrls'   => true,
        'skipComments'      => false,
        'skipUserPosts'     => true,
        'skipCommunity'     => true,
        'includeNSFW'       => false,
        'sort'              => 'relevance',
        'time'              => 'year',
        'maxItems'          => $limit,
        'maxPostCount'      => max(3, (int) ceil($limit / 10)),
        'maxComments'       => 10,
        'scrollTimeout'     => 40,
        'navigationTimeout' => 60,
        'proxy'             => ['useApifyProxy' => true, 'apifyProxyGroups' => ['RESIDENTIAL']],
    ];
}

function x_input(string $topic, int $limit): array
{
    $extra = apify_cfg()['x_extra_input'] ?? [];
    return array_merge(
        ['searchTerms' => [$topic . ' lang:en -filter:retweets'], 'maxItems' => $limit],
        $extra
    );
}

$stmt = db()->prepare('SELECT topic FROM jobs WHERE id = ?');
$stmt->execute([$jobId]);
$topic = $stmt->fetchColumn();
if ($topic === false) {
    fwrite(STDERR, "Job {$jobId} not found\n");
    exit(1);
}

$cfg       = apify_cfg();
$perSource = (int) ($cfg['max_items_per_source'] ?? 30);

$sources = [];
if (!empty($cfg['reddit_actor'])) {
    $sources['reddit'] = [$cfg['reddit_actor'], reddit_input($topic, $perSource), 'normalize_reddit_item'];
}
if (!empty($cfg['x_actor'])) {
    $sources['x'] = [$cfg['x_actor'], x_input($topic, $perSource), 'normalize_x_item'];
}

try {
    $raw      = [];
    $rows     = [];
    $warnings = [];

    foreach ($sources as $name => [$actor, $input, $normalize]) {
        say($jobId, 'collecting', 'Collecting from ' . ucfirst($name) . '...');
        try {
            $items = apify_run_and_collect($actor, $input, $perSource);
        } catch (Throwable $e) {
            $warnings[] = ucfirst($name) . ': ' . $e->getMessage();
            echo 'WARNING ' . end($warnings) . "\n";
            continue;
        }
        $raw[$name] = $items;
        foreach ($items as $item) {
            $row = $normalize($item);
            if ($row !== null) {
                $rows[] = $row;
            }
        }
    }
    if (!$raw) {
        throw new RuntimeException($warnings ? implode(' | ', $warnings) : 'No data source is configured');
    }

    // Raw data, exactly as Apify returned it, compressed
    $file = __DIR__ . "/raw/job_{$jobId}.json.gz";
    file_put_contents($file, gzencode(json_encode($raw, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES), 6));

    // Cleaned rows
    $pdo = db();
    $ins = $pdo->prepare(
        'INSERT IGNORE INTO comments (job_id, source, external_id, kind, community, body, score, created_at_src, url)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)'
    );
    $pdo->beginTransaction();
    foreach ($rows as $r) {
        $ins->execute([$jobId, $r['source'], $r['external_id'], $r['kind'], $r['community'],
                       $r['body'], $r['score'], $r['created'], $r['url']]);
    }
    $pdo->commit();

    $c = $pdo->prepare('SELECT COUNT(*) FROM comments WHERE job_id = ?');
    $c->execute([$jobId]);
    $total = (int) $c->fetchColumn();
    if ($total === 0) {
        throw new RuntimeException('The actors returned no usable posts. Check their input settings.');
    }

    // Python analysis
    say($jobId, 'analyzing', "Analyzing {$total} items...");
    $result = run_analysis($jobId, $topic, $warnings);

    $pdo->prepare("UPDATE jobs SET status = 'done', message = 'Done', result_json = ?, raw_file = ?,
                   item_count = ?, finished_at = NOW() WHERE id = ?")
        ->execute([
            json_encode($result, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_INVALID_UTF8_SUBSTITUTE),
            $file, $total, $jobId,
        ]);
    echo "Done: {$total} items stored and analyzed\n";

} catch (Throwable $e) {
    echo 'FAILED: ' . $e->getMessage() . "\n";
    if (db()->inTransaction()) {
        db()->rollBack();
    }
    db()->prepare("UPDATE jobs SET status = 'failed', error_message = ?, finished_at = NOW() WHERE id = ?")
        ->execute([substr($e->getMessage(), 0, 500), $jobId]);
    exit(1);
}
EOF

sudo mariadb opinionmap -e "SELECT job_id, source, COUNT(*) AS n FROM comments GROUP BY job_id, source;"
php /var/www/private/reanalyze.php 3
ls -l /var/www/private /var/www/private/python /var/www/private/raw; sudo mariadb opinionmap -e "SELECT id, topic, status, item_count, raw_file, created_at FROM jobs ORDER BY id DESC LIMIT 5; SELECT COUNT(*) AS comment_rows FROM comments;"
JOB=$(sudo mariadb -N opinionmap -e "INSERT INTO jobs (topic, status) VALUES ('AI in education', 'queued'); SELECT LAST_INSERT_ID();")
echo "Job number: $JOB"
php /var/www/private/worker.php $JOB
sudo mariadb opinionmap -e "SELECT id, status, message, item_count FROM jobs ORDER BY id DESC LIMIT 1; SELECT source, kind, COUNT(*) AS n FROM comments GROUP BY source, kind; SELECT source, kind, score, LEFT(body, 90) AS text FROM comments ORDER BY id DESC LIMIT 8;"
ls -lh /var/www/private/raw
sudo mariadb -N -r opinionmap -e "SELECT result_json FROM jobs WHERE id = 4;" | python3 -m json.tool | head -100
sudo mariadb opinionmap -e "SELECT source, COUNT(*) AS total, SUM(body REGEXP 'education|school|student|teach|learn|universit|college|artificial intelligence') AS on_topic FROM comments WHERE job_id = 4 GROUP BY source;"
sudo mariadb opinionmap -e "UPDATE jobs SET user_id = (SELECT id FROM users WHERE username = 'testuser') WHERE id = 4;" 
sed -i 's|<h3>Stance distribution</h3>|<h3>Stance distribution <small>(estimated from sentiment)</small></h3>|' /var/www/html/index.html
sed -i 's|<div class="card"><h3>Sample collected posts</h3><ul id="samples"></ul></div>|&\n        <div class="card"><h3>Basic statistics</h3><ul id="stats"></ul></div>|' /var/www/html/index.html
sed -i '/results.).prop(.hidden., false)/i\    var $st = $("#stats").empty(); $.each(d.stats || [], function (i, line) { $st.append($("<li>").text(line)); });' /var/www/html/js/app.js
sed -i "s|where + '] '|where + (s.stance ? ', ' + s.stance : '') + '] '|" /var/www/html/js/app.js
grep -n "stats\|s.stance" /var/www/html/index.html /var/www/html/js/app.js
tail -n 20 /var/www/private/logs/$(ls -t /var/www/private/logs | grep job_ | head -1)
sudo mariadb opinionmap <<'EOF'
ALTER TABLE comments
  ADD COLUMN IF NOT EXISTS on_topic TINYINT(1) NULL,
  ADD COLUMN IF NOT EXISTS topic_reason VARCHAR(12) NULL;
EOF

sudo mariadb opinionmap -e "DESCRIBE comments;"
cat > /var/www/private/python/topic_filter.py <<'EOF'
"""Decides which collected posts are actually about the topic.

Adds r["on_topic"] (True/False) and r["reason"] to every row:
  keywords   - mentions the topic's key terms
  similar    - does not, but reads like the keyword-matched posts
  off_topic  - neither
  unfiltered - the topic had no usable key terms, so nothing was filtered
"""
import math
import re

import numpy as np
from sklearn.feature_extraction.text import TfidfVectorizer

# ---- settings you can tune ----
REQUIRE_SHARE = 0.6        # share of the topic's key terms a post must mention (2 terms = both)
RESCUE = True              # also keep posts that read like the on-topic core (set False to disable)
RESCUE_PERCENTILE = 25     # lower = rescues more posts, higher = stricter
RESCUE_FLOOR = 0.10        # never rescue a post below this similarity
SEED_MIN = 8               # need at least this many keyword matches before trying to rescue

# Extra words that count as a mention of a topic term. Use exact forms (singular and plural).
ALIASES = {
    "ai": ["artificial", "chatgpt", "gpt", "llm", "llms", "openai", "copilot", "gemini",
           "chatbot", "chatbots", "genai"],
    "education": ["school", "schools", "student", "students", "teacher", "teachers",
                  "classroom", "classrooms", "college", "colleges", "university", "universities",
                  "homework", "professor", "professors"],
}
TOPIC_STOP = {"a", "an", "the", "in", "on", "of", "for", "and", "or", "to", "with", "at", "by",
              "from", "about", "is", "are", "vs", "versus", "into", "over", "as", "its", "their",
              "how", "what", "why", "does", "do"}


def term_hit(tok, q):
    """Does word `tok` count as the topic word `q`? Allows endings like education/educational."""
    if len(q) <= 3:
        return tok == q
    if len(q) <= 5:
        return tok == q or (tok.startswith(q) and len(tok) <= len(q) + 2)
    return tok.startswith(q[:5])


def hits(tok, concept):
    term, aliases = concept
    return tok in aliases or term_hit(tok, term)


def mark_topic(rows, topic):
    info = {"keyword_matches": 0, "rescued": 0, "threshold": None}
    terms = [w for w in re.findall(r"[a-z0-9]+", topic.lower())
             if w not in TOPIC_STOP and len(w) >= 2]
    if not terms:
        for r in rows:
            r["on_topic"], r["reason"] = True, "unfiltered"
        return info

    concepts = [(t, set(ALIASES.get(t, []))) for t in terms]
    need = max(1, math.ceil(REQUIRE_SHARE * len(concepts) - 1e-9))

    # Stage 1: keywords
    for r in rows:
        tokens = set(re.findall(r"[a-z0-9]+", r["_clean"]))
        n_hit = sum(1 for c in concepts if any(hits(t, c) for t in tokens))
        r["on_topic"] = n_hit >= need
        r["reason"] = "keywords" if r["on_topic"] else "off_topic"

    seeds = [i for i, r in enumerate(rows) if r["on_topic"]]
    info["keyword_matches"] = len(seeds)
    if not RESCUE or len(seeds) < SEED_MIN or len(seeds) == len(rows):
        return info

    # Stage 2: rescue posts that read like the keyword-matched ones
    vec = TfidfVectorizer(stop_words="english", min_df=2, max_df=0.5,
                          max_features=3000, sublinear_tf=True)
    try:
        X = vec.fit_transform([r["_clean"] for r in rows]).toarray()
    except ValueError:
        return info
    names = vec.get_feature_names_out()
    drop = [j for j, nm in enumerate(names) if any(hits(nm, c) for c in concepts)]
    if drop:
        X[:, drop] = 0          # compare on context words only, not the topic words themselves
    lengths = np.linalg.norm(X, axis=1, keepdims=True)
    lengths[lengths == 0] = 1
    X = X / lengths

    seed_X = X[seeds]
    S = seed_X.sum(axis=0)
    s_len = np.linalg.norm(S)
    if s_len == 0:
        return info
    diff = S - seed_X                                    # centroid without the post itself
    d_len = np.linalg.norm(diff, axis=1)
    ok = d_len > 0
    if ok.sum() < SEED_MIN:
        return info
    own = np.einsum("ij,ij->i", seed_X, diff)[ok] / d_len[ok]
    thr = max(float(np.percentile(own, RESCUE_PERCENTILE)), RESCUE_FLOOR)
    sims = X @ S / s_len
    info["threshold"] = round(thr, 3)

    for i, r in enumerate(rows):
        if not r["on_topic"] and sims[i] >= thr:
            r["on_topic"], r["reason"] = True, "similar"
            info["rescued"] += 1
    return info
EOF

cat > /var/www/private/python/analyze.py <<'EOF'
#!/usr/bin/env python3
"""Usage: python analyze.py INPUT.json OUTPUT.json

Reads collected posts, then:
  1. cleans them and drops junk and duplicates
  2. keeps only on-topic posts
  3. estimates stance from sentiment
  4. finds themes (TF-IDF + clustering) and outliers (Local Outlier Factor)
and writes per-row labels plus the dashboard result as JSON.
"""
import html
import json
import re
import sys
import warnings
from collections import Counter

import numpy as np
from sklearn.cluster import KMeans
from sklearn.decomposition import TruncatedSVD
from sklearn.feature_extraction.text import ENGLISH_STOP_WORDS, TfidfVectorizer
from sklearn.metrics import silhouette_score
from sklearn.neighbors import LocalOutlierFactor
from sklearn.preprocessing import Normalizer
from vaderSentiment.vaderSentiment import SentimentIntensityAnalyzer

from topic_filter import mark_topic

warnings.filterwarnings("ignore")

# ---- settings you can tune ----
POS_T, NEG_T = 0.2, -0.2     # sentiment above/below these counts as supportive/opposed
MIN_WORDS = 4                # shorter texts are skipped
MAX_THEMES = 6
OUTLIER_SHARE = 0.03         # flag roughly the 3% most unusual items
EXTRA_STOP = {
    "like", "just", "people", "think", "really", "would", "could", "also", "one", "get", "got",
    "dont", "don", "doesn", "didn", "isn", "ve", "ll", "re", "https", "http", "www", "com",
    "amp", "gt", "lt", "im", "thats", "use", "even", "much", "make", "know", "going", "yeah",
}
LABELS = {"supportive": "Supportive", "opposed": "Opposed", "neutral": "Neutral or uncertain"}

URL_RE = re.compile(r"https?://\S+|www\.\S+")
MENTION_RE = re.compile(r"(?<!\w)@\w+")


def strip_links(text):
    t = html.unescape(text or "")
    t = URL_RE.sub(" ", t)
    t = MENTION_RE.sub(" ", t)
    return re.sub(r"\s+", " ", t).strip()


def normalize(text):
    t = re.sub(r"[#*_>~`\[\]()]", " ", text.lower())
    return re.sub(r"\s+", " ", t).strip()


def snippet(text, n):
    return text if len(text) <= n else text[:n].rstrip() + "..."


def top_terms(centroid, names, n=3):
    chosen, used = [], set()
    for i in centroid.argsort()[::-1][:40]:
        words = set(names[i].split())
        if words & used:
            continue
        chosen.append(names[i])
        used |= words
        if len(chosen) == n:
            break
    return ", ".join(chosen) if chosen else "miscellaneous"


def choose_k(Z, n):
    max_k = min(8, n // 10)
    if max_k < 3:
        return 2
    best_k, best = 3, -1.0
    for k in range(3, max_k + 1):
        labels = KMeans(n_clusters=k, n_init=5, random_state=42).fit_predict(Z)
        if len(set(labels)) < 2:
            continue
        s = silhouette_score(Z, labels)
        if s > best:
            best_k, best = k, s
    return best_k


def main():
    if len(sys.argv) != 3:
        sys.exit("Usage: python analyze.py INPUT.json OUTPUT.json")
    with open(sys.argv[1], encoding="utf-8") as f:
        data = json.load(f)
    topic = data.get("topic") or ""
    rows = sorted(data.get("rows", []), key=lambda r: -(r.get("score") or 0))
    total_in = len(rows)

    # 1. Clean, skip junk, remove duplicates (keeping the best-scored copy)
    all_kept, junk, seen = [], [], set()
    for r in rows:
        body = (r.get("body") or "").strip()
        if body.lower() in ("[deleted]", "[removed]"):
            junk.append((r, "junk"))
            continue
        raw = strip_links(body)
        clean = normalize(raw)
        if len(clean.split()) < MIN_WORDS:
            junk.append((r, "junk"))
            continue
        if clean in seen:
            junk.append((r, "duplicate"))
            continue
        seen.add(clean)
        r["_raw"], r["_clean"] = raw, clean
        all_kept.append(r)
    if not all_kept:
        sys.exit("No usable text (everything was too short, deleted or duplicated)")

    # 2. On-topic filter: only on-topic posts go on to the analysis
    info = mark_topic(all_kept, topic)
    kept = [r for r in all_kept if r["on_topic"]]
    n = len(kept)
    off_topic = len(all_kept) - n
    if n == 0:
        sys.exit("None of the %d collected items were about '%s'. Try a broader topic." % (total_in, topic))

    # 3. Sentiment -> stance estimate
    vader = SentimentIntensityAnalyzer()
    for r in kept:
        c = vader.polarity_scores(r["_raw"])["compound"]
        r["sentiment"] = c
        r["stance"] = "supportive" if c >= POS_T else ("opposed" if c <= NEG_T else "neutral")
        r["cluster"], r["outlier"], r["is_outlier"] = None, 0.0, 0

    # 4. Themes and outliers
    themes = []
    X = None
    vec = None
    topic_words = set(re.findall(r"[a-z]{2,}", topic.lower()))
    stop = list(ENGLISH_STOP_WORDS | EXTRA_STOP | topic_words)
    if n >= 10:
        vec = TfidfVectorizer(stop_words=stop, ngram_range=(1, 2),
                              min_df=2 if n >= 30 else 1, max_df=0.6,
                              max_features=4000, sublinear_tf=True)
        try:
            X = vec.fit_transform([r["_clean"] for r in kept])
        except ValueError:
            X = None

    if X is not None and X.shape[1] >= 3:
        names = vec.get_feature_names_out()
        comps = min(50, X.shape[1] - 1, n - 1)
        Z = TruncatedSVD(n_components=comps, random_state=42).fit_transform(X)
        Z = Normalizer(copy=False).fit_transform(Z)
        labels = KMeans(n_clusters=choose_k(Z, n), n_init=10, random_state=42).fit_predict(Z)
        for r, c in zip(kept, labels):
            r["cluster"] = int(c)
        for cid, size in Counter(labels.tolist()).most_common(MAX_THEMES):
            centroid = np.asarray(X[np.where(labels == cid)[0]].mean(axis=0)).ravel()
            themes.append({"label": top_terms(centroid, names), "share": round(100 * size / n, 1)})

        if n >= 20:
            lof = LocalOutlierFactor(n_neighbors=min(20, n - 1), contamination=OUTLIER_SHARE)
            flags = lof.fit_predict(Z)
            scores = np.nan_to_num(-lof.negative_outlier_factor_, nan=0.0, posinf=0.0)
            for r, flag, s in zip(kept, flags, scores):
                r["outlier"], r["is_outlier"] = round(float(s), 3), int(flag == -1)
    if not themes:
        themes = [{"label": "all posts (too few for theme detection)", "share": 100.0}]

    # 5. Stance split, samples, statistics
    counts = Counter(r["stance"] for r in kept)
    pct = {k: round(100 * counts.get(k, 0) / n, 1) for k in LABELS}
    ranked = sorted(pct.items(), key=lambda kv: -kv[1])
    top_key, top_pct = ranked[0]
    majority = {"label": LABELS[top_key] + ("" if top_pct >= 50 else " (largest group)"),
                "percent": top_pct}

    samples = []
    for key, _ in ranked:
        group = [r for r in kept if r["stance"] == key]
        group.sort(key=lambda r: (-(r.get("score") or 0), -abs(r["sentiment"])))
        for r in group[:2]:
            samples.append({"source": r["source"], "kind": r["kind"], "community": r.get("community"),
                            "text": snippet(r["_raw"], 280), "score": r.get("score") or 0,
                            "url": r.get("url"), "stance": key})

    flagged = sorted((r for r in kept if r["is_outlier"]), key=lambda r: -r["outlier"])[:5]
    outliers = [{"text": snippet(r["_raw"], 200),
                 "reason": "unusual wording compared with the rest of the discussion "
                           "(outlier score %.2f; typical is about 1.0)" % r["outlier"]}
                for r in flagged]
    if n < 20:
        outliers = [{"text": "Not enough items to detect outliers",
                     "reason": "needs at least 20 analyzed items"}]
    elif not outliers:
        outliers = [{"text": "No clear outliers found", "reason": "nothing stood out from the rest"}]

    collected = Counter(r["source"] for r in rows)
    on_topic = Counter(r["source"] for r in kept)
    by_kind = Counter(r["kind"] for r in kept)
    dates = sorted(r["created"][:10] for r in kept if r.get("created"))
    n_out = sum(r["is_outlier"] for r in kept)
    avg = sum(r["sentiment"] for r in kept) / n

    stats = [
        "On-topic: " + ", ".join("%s %d of %d" % (s, on_topic.get(s, 0), c) for s, c in collected.items()),
        "Filtered out: %d off-topic, %d too short, deleted or duplicate" % (off_topic, len(junk)),
        "Items analyzed: %d" % n,
        "Types: " + ", ".join("%s %d" % (k, v) for k, v in by_kind.items()),
        "Average sentiment: %+.2f (scale -1 to +1)" % avg,
        "%s group: %s %.1f%%" % ("Majority" if top_pct >= 50 else "Largest", LABELS[top_key], top_pct),
    ]
    if ranked[1][1] > 0:
        stats.append("Largest minority group: %s %.1f%%" % (LABELS[ranked[1][0]], ranked[1][1]))
    stats.append("Themes found: %d; outliers flagged: %d" % (len(themes), n_out))
    if dates:
        stats.append("Posts dated %s to %s" % (dates[0], dates[-1]))

    result = {
        "demo": False,
        "total": n,
        "sources": {"reddit": on_topic.get("reddit", 0), "x": on_topic.get("x", 0)},
        "majority": majority,
        "stance": pct,
        "themes": themes,
        "outliers": outliers,
        "samples": samples,
        "stats": stats,
        "filter": {"collected": total_in, "on_topic": n, "off_topic": off_topic,
                   "junk": len(junk), "rescued": info["rescued"]},
    }

    out_rows = []
    for r in all_kept:
        out_rows.append({
            "id": r["id"], "on_topic": int(r["on_topic"]), "topic_reason": r["reason"],
            "stance": r.get("stance"),
            "sentiment": round(r["sentiment"], 3) if "sentiment" in r else None,
            "cluster": r.get("cluster"), "outlier": r.get("outlier"), "is_outlier": r.get("is_outlier", 0),
        })
    for r, why in junk:
        out_rows.append({"id": r["id"], "on_topic": 0, "topic_reason": why, "stance": None,
                         "sentiment": None, "cluster": None, "outlier": None, "is_outlier": 0})

    with open(sys.argv[2], "w", encoding="utf-8") as f:
        json.dump({"rows": out_rows, "result": result}, f, ensure_ascii=False)
    print("On topic: %d of %d collected (%d off-topic, %d junk; %d rescued by similarity, threshold %s)"
          % (n, total_in, off_topic, len(junk), info["rescued"], info["threshold"]))
    print("Analyzed %d items: %d themes, %d outliers" % (n, len(themes), n_out))


if __name__ == "__main__":
    main()
EOF

cat > /var/www/private/Analysis.php <<'EOF'
<?php
require_once __DIR__ . '/Database.php';

// Runs the Python analysis for a job whose text is already in the comments table.
// Saves per-row labels and returns the result array for the dashboard.
function run_analysis(int $jobId, string $topic, array $warnings = []): array
{
    $pdo = db();
    $q = $pdo->prepare(
        'SELECT id, source, kind, community, body, score, created_at_src AS created, url
         FROM comments WHERE job_id = ?'
    );
    $q->execute([$jobId]);
    $rows = $q->fetchAll();
    if (!$rows) {
        throw new RuntimeException('No collected text to analyze');
    }

    $in  = __DIR__ . "/tmp/job_{$jobId}_in.json";
    $out = __DIR__ . "/tmp/job_{$jobId}_out.json";
    file_put_contents($in, json_encode(
        ['topic' => $topic, 'rows' => $rows],
        JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_INVALID_UTF8_SUBSTITUTE
    ));

    $cmd = escapeshellarg(__DIR__ . '/python/venv/bin/python') . ' '
         . escapeshellarg(__DIR__ . '/python/analyze.py') . ' '
         . escapeshellarg($in) . ' ' . escapeshellarg($out) . ' 2>&1';
    exec($cmd, $lines, $code);
    echo implode("\n", $lines) . "\n";
    @unlink($in);

    if ($code !== 0 || !is_file($out)) {
        @unlink($out);
        throw new RuntimeException('Analysis failed: ' . substr(implode(' ', $lines), -300));
    }
    $data = json_decode((string) file_get_contents($out), true);
    @unlink($out);
    if (!is_array($data) || !isset($data['result'], $data['rows'])) {
        throw new RuntimeException('Analysis returned unreadable output');
    }

    $upd = $pdo->prepare(
        'UPDATE comments
         SET on_topic = ?, topic_reason = ?, stance = ?, sentiment_score = ?, cluster_id = ?,
             outlier_score = ?, is_outlier = ?
         WHERE id = ?'
    );
    $pdo->beginTransaction();
    foreach ($data['rows'] as $r) {
        $upd->execute([
            $r['on_topic'], $r['topic_reason'], $r['stance'] ?? null, $r['sentiment'] ?? null,
            $r['cluster'] ?? null, $r['outlier'] ?? null, $r['is_outlier'] ?? 0, $r['id'],
        ]);
    }
    $pdo->commit();

    $result = $data['result'];
    $result['topic']    = $topic;
    $result['warnings'] = $warnings;
    return $result;
}
EOF

php /var/www/private/reanalyze.php 4
cd /var/www/private; echo "=== Analysis.php ==="; cat Analysis.php; echo "=== worker.php analysis lines ==="; grep -n -i -E "analy|python" worker.php; echo "=== analyze.py entry points ==="; grep -n -E "argv|argparse|stdin|stdout|json\.(load|dump)|def |^import|^from" python/analyze.py; echo "=== repeated openings ==="; sudo mariadb opinionmap -e "SELECT LEFT(body, 45) AS opening, source, COUNT(*) AS n FROM comments WHERE job_id = 4 GROUP BY opening, source HAVING n > 2 ORDER BY n DESC LIMIT 10;"
cat > /var/www/private/Analysis.php <<'EOF'
<?php
require_once __DIR__ . '/Database.php';

// Runs the Python analysis for a job whose text is already in the comments table.
// Saves per-row labels and returns the result array for the dashboard.
function run_analysis(int $jobId, string $topic, array $warnings = []): array
{
    $pdo = db();
    $q = $pdo->prepare(
        'SELECT id, source, kind, community, body, score, created_at_src AS created, url
         FROM comments WHERE job_id = ?'
    );
    $q->execute([$jobId]);
    $rows = $q->fetchAll();

    // NEW: drop deleted placeholders and repeated (spam or bot) texts before analysis
    $seen = [];
    $kept = [];
    foreach ($rows as $r) {
        $t = trim((string) $r['body']);
        if ($t === '' || preg_match('/^\[(deleted|removed)\]$/i', $t)) {
            continue;
        }
        if (mb_strlen($t) >= 40) {
            $key = md5(mb_strtolower(mb_substr(preg_replace('/\s+/u', ' ', $t), 0, 40)));
            $seen[$key] = ($seen[$key] ?? 0) + 1;
            if ($seen[$key] > 2) {
                continue;               // keep at most 2 copies of the same opening
            }
        }
        $kept[] = $r;
    }
    echo 'Removed ' . (count($rows) - count($kept)) . ' deleted or repeated rows' . "\n";
    $rows = $kept;

    if (!$rows) {
        throw new RuntimeException('No collected text to analyze');
    }

    $in  = __DIR__ . "/tmp/job_{$jobId}_in.json";
    $out = __DIR__ . "/tmp/job_{$jobId}_out.json";
    file_put_contents($in, json_encode(
        ['topic' => $topic, 'rows' => $rows],
        JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_INVALID_UTF8_SUBSTITUTE
    ));

    $cmd = escapeshellarg(__DIR__ . '/python/venv/bin/python') . ' '
         . escapeshellarg(__DIR__ . '/python/analyze.py') . ' '
         . escapeshellarg($in) . ' ' . escapeshellarg($out) . ' 2>&1';
    exec($cmd, $lines, $code);
    echo implode("\n", $lines) . "\n";
    @unlink($in);

    if ($code !== 0 || !is_file($out)) {
        @unlink($out);
        throw new RuntimeException('Analysis failed: ' . substr(implode(' ', $lines), -300));
    }
    $data = json_decode((string) file_get_contents($out), true);
    @unlink($out);
    if (!is_array($data) || !isset($data['result'], $data['rows'])) {
        throw new RuntimeException('Analysis returned unreadable output');
    }

    $upd = $pdo->prepare(
        'UPDATE comments
         SET on_topic = ?, topic_reason = ?, stance = ?, sentiment_score = ?, cluster_id = ?,
             outlier_score = ?, is_outlier = ?
         WHERE id = ?'
    );
    $pdo->beginTransaction();
    foreach ($data['rows'] as $r) {
        $upd->execute([
            $r['on_topic'], $r['topic_reason'], $r['stance'] ?? null, $r['sentiment'] ?? null,
            $r['cluster'] ?? null, $r['outlier'] ?? null, $r['is_outlier'] ?? 0, $r['id'],
        ]);
    }
    $pdo->commit();

    $result = $data['result'];
    $result['topic']    = $topic;
    $result['warnings'] = $warnings;
    return $result;
}
EOF

php -l /var/www/private/Analysis.php
cat > /var/www/private/reanalyze.php <<'EOF'
<?php
// Usage: php reanalyze.php JOB_ID
// Re-runs the analysis on rows already stored for a job. Costs no Apify credit.
require __DIR__ . '/Database.php';
require __DIR__ . '/Analysis.php';

$jobId = (int) ($argv[1] ?? 0);
if ($jobId < 1) {
    fwrite(STDERR, "Usage: php reanalyze.php JOB_ID\n");
    exit(1);
}

$stmt = db()->prepare('SELECT topic FROM jobs WHERE id = ?');
$stmt->execute([$jobId]);
$topic = $stmt->fetchColumn();
if ($topic === false) {
    fwrite(STDERR, "Job {$jobId} not found\n");
    exit(1);
}

try {
    $result = run_analysis($jobId, $topic, []);
    db()->prepare("UPDATE jobs SET result_json = ?, status = 'done', message = 'Done' WHERE id = ?")
        ->execute([json_encode($result, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES), $jobId]);
    echo "Re-analysis finished for job {$jobId}\n";
} catch (Throwable $e) {
    echo 'FAILED: ' . $e->getMessage() . "\n";
    exit(1);
}
EOF

php -l /var/www/private/reanalyze.php
php /var/www/private/reanalyze.php 4
sudo mariadb -N -r opinionmap -e "SELECT result_json FROM jobs WHERE id = 4;" | python3 -c "import sys,json; d=json.load(sys.stdin); print('total:', d['total'], d['sources']); print('stance:', d['stance']); print('--- themes'); [print(t['share'], t['label']) for t in d['themes']]; print('--- outliers'); [print('-', o['text'][:110]) for o in d['outliers']]"
cat /var/www/private/python/analyze.py; echo "=== topic_filter.py ==="; cat /var/www/private/python/topic_filter.py
cp /var/www/private/python/analyze.py /var/www/private/python/analyze.py.bak
cat > /var/www/private/tmp/patch_analyze.py <<'EOF'
import sys

path = "/var/www/private/python/analyze.py"
src = open(path, encoding="utf-8").read()


def swap(old, new):
    global src
    n = src.count(old)
    if n != 1:
        sys.exit("Patch NOT applied: expected 1 match but found %d for: %s" % (n, old.strip()[:70]))
    src = src.replace(old, new)


# 1. Bot and template removal: new helper code placed just before main()
swap(
    "def main():\n    if len(sys.argv) != 3:",
    r'''BOILERPLATE_RE = re.compile(
    r"made it to /r/all|your post made it|mods have pinned a comment|i am a bot|"
    r"this action was performed automatically|automoderator", re.I)


def drop_near_duplicates(rows, threshold=0.5, max_copies=2, min_words=12):
    """Keeps at most max_copies of any group of near-identical long texts (spam, bots, templates)."""
    long_idx = [i for i, r in enumerate(rows) if len(r["_clean"].split()) >= min_words]
    if len(long_idx) < 3:
        return rows, []
    vec = TfidfVectorizer(ngram_range=(1, 2), sublinear_tf=True)
    try:
        X = vec.fit_transform([rows[i]["_clean"] for i in long_idx])
    except ValueError:
        return rows, []
    reps, copies, drop = [], {}, set()
    for pos, i in enumerate(long_idx):
        if reps:
            sims = X[pos].dot(X[reps].T).toarray().ravel()
            best = int(sims.argmax())
            if sims[best] >= threshold:
                copies[reps[best]] += 1
                if copies[reps[best]] > max_copies:
                    drop.add(i)
                continue
        reps.append(pos)
        copies[pos] = 1
    kept = [r for i, r in enumerate(rows) if i not in drop]
    return kept, [rows[i] for i in sorted(drop)]


def main():
    if len(sys.argv) != 3:''',
)

# 2. Treat bot comments as junk
swap(
    '        if body.lower() in ("[deleted]", "[removed]"):',
    '        if body.lower() in ("[deleted]", "[removed]") or BOILERPLATE_RE.search(body):',
)

# 3. Run the near-duplicate removal right after the first cleaning pass
swap(
    "    if not all_kept:\n",
    "    all_kept, near_dups = drop_near_duplicates(all_kept)\n"
    "    for r in near_dups:\n"
    "        junk.append((r, \"duplicate\"))\n"
    "    if not all_kept:\n",
)

# 4. Honest wording: this measures tone, not position on the topic
swap(
    'LABELS = {"supportive": "Supportive", "opposed": "Opposed", "neutral": "Neutral or uncertain"}',
    'LABELS = {"supportive": "Positive tone", "opposed": "Negative tone", "neutral": "Neutral or mixed tone"}',
)

# 5. More filler words, and no numbers in theme labels
swap(
    '    "amp", "gt", "lt", "im", "thats", "use", "even", "much", "make", "know", "going", "yeah",',
    '    "amp", "gt", "lt", "im", "thats", "use", "even", "much", "make", "know", "going", "yeah",\n'
    '    "want", "things", "thing", "life", "built", "lol", "need", "time", "way", "good", "lot", "new",\n'
    '    "said", "say", "let", "see", "every", "still", "back", "right", "well", "first", "many", "look",\n'
    '    "come", "take", "year", "years", "day", "something", "anything", "everything", "someone",\n'
    '    "post", "posts", "comment", "comments", "did", "does", "doing", "done", "using", "used",',
)
swap(
    "        vec = TfidfVectorizer(stop_words=stop, ngram_range=(1, 2),",
    '        vec = TfidfVectorizer(stop_words=stop, ngram_range=(1, 2),\n'
    '                              token_pattern=r"(?u)\\b[a-zA-Z][a-zA-Z]+\\b",',
)

# 6. Give every theme an example post
swap(
    '            themes.append({"label": top_terms(centroid, names), "share": round(100 * size / n, 1)})',
    '            members = np.where(labels == cid)[0]\n'
    '            best = members[int(np.argmax(Z[members] @ Z[members].mean(axis=0)))]\n'
    '            themes.append({"label": top_terms(centroid, names), "share": round(100 * size / n, 1),\n'
    '                           "example": snippet(kept[int(best)]["_raw"], 160)})',
)

open(path, "w", encoding="utf-8").write(src)
print("analyze.py updated: 6 changes applied")
EOF

python3 /var/www/private/tmp/patch_analyze.py
/var/www/private/python/venv/bin/python -m py_compile /var/www/private/python/analyze.py && echo "analyze.py looks valid"
php /var/www/private/reanalyze.php 4
sudo mariadb -N -r opinionmap -e "SELECT result_json FROM jobs WHERE id = 4;" | python3 -c "import sys,json; d=json.load(sys.stdin); print('total:', d['total'], d['sources']); print('tone:', d['stance']); print('--- themes'); [print(t['share'], t['label'], '|', t.get('example','')[:90]) for t in d['themes']]; print('--- outliers'); [print('-', o['text'][:110]) for o in d['outliers']]"
sudo mariadb opinionmap -e "SELECT source, COUNT(*) AS total, SUM(on_topic) AS on_topic FROM comments WHERE job_id = 5 GROUP BY source;"
sudo mariadb opinionmap -e "SELECT source, topic_reason, COUNT(*) AS n FROM comments WHERE job_id = 5 GROUP BY source, topic_reason ORDER BY source, n DESC;"
sudo mariadb opinionmap -e "SELECT source, LEFT(body, 110) AS text FROM comments WHERE job_id = 5 AND topic_reason = 'off_topic' ORDER BY RAND() LIMIT 8;"
sudo mariadb opinionmap -e "SELECT source, LEFT(body, 110) AS text FROM comments WHERE job_id = 5 AND topic_reason = 'similar' ORDER BY RAND() LIMIT 8;"
