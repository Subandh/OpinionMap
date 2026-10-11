$(function () {
  'use strict';

  var S = { mode: 'login', pollId: 0, jobId: null, topic: '', data: null, tick: null };
  var STANCE = {
    supportive: { name: 'Supportive', cls: 'pos' },
    opposed:    { name: 'Opposed',    cls: 'neg' },
    neutral:    { name: 'Neutral',    cls: 'neu' }
  };
  var KEYS = ['supportive', 'opposed', 'neutral'];
  var reduceMotion = window.matchMedia && matchMedia('(prefers-reduced-motion: reduce)').matches;
  var ESC = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' };

  /* ---------- helpers ---------- */
  function esc(s) { return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) { return ESC[c]; }); }
  function safeUrl(u) { return /^https?:\/\//i.test(u || '') ? u : ''; }
  function ico(n) { return '<svg class="ico" aria-hidden="true"><use href="#i-' + n + '"/></svg>'; }
  function errMsg(xhr, fallback) { return (xhr && xhr.responseJSON && xhr.responseJSON.error) || fallback; }
  function tone(label) {
    var l = String(label || '').toLowerCase();
    return /support|positive/.test(l) ? 'pos' : (/oppos|negative/.test(l) ? 'neg' : 'neu');
  }
  function toast(msg, type) {
    var $t = $('<div class="toast toast-' + (type || 'info') + '" role="status">' + ico(type === 'error' ? 'alert' : 'check') + '<span></span></div>');
    $t.find('span').text(msg);
    $('#toasts').append($t);
    setTimeout(function () { $t.fadeOut(200, function () { $t.remove(); }); }, 5000);
  }
  function setBusy($btn, on) { $btn.prop('disabled', on).find('.spinner').prop('hidden', !on); }
  function parseTime(s) { return new Date(String(s).replace(' ', 'T') + 'Z'); }
  function minutesAgo(s) { var t = parseTime(s); return isNaN(t) ? 9999 : (Date.now() - t) / 60000; }
  function ago(s) {
    var m = Math.round(minutesAgo(s));
    if (m >= 9999) { return s; }
    if (m < 1) { return 'just now'; }
    if (m < 60) { return m + ' min ago'; }
    if (m < 1440) { return Math.round(m / 60) + ' h ago'; }
    return parseTime(s).toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
  }
  function view(name) {
    $('#empty').prop('hidden', name !== 'idle');
    $('#progress').prop('hidden', name !== 'working');
    $('#skeleton').prop('hidden', name !== 'loading');
    $('#results').prop('hidden', name !== 'results');
  }

  /* ---------- theme ---------- */
  $('#themeBtn').on('click', function () {
    var el = document.documentElement;
    var t = el.getAttribute('data-theme') === 'dark' ? 'light' : 'dark';
    el.setAttribute('data-theme', t);
    try { localStorage.setItem('om-theme', t); } catch (e) {}
  });

  /* ---------- screens ---------- */
  function showAuth() {
    S.pollId++; stopTick();
    S.data = null; S.jobId = null;
    $('#appView, #userMenu').prop('hidden', true);
    $('#authView').prop('hidden', false);
    $('#authPass').val('');
    $('#history').empty();
    $('#httpNote').prop('hidden', location.protocol !== 'http:');
    setBusy($('#analyzeBtn'), false);
    view('idle');
  }
  function showApp(name) {
    $('#authView').prop('hidden', true);
    $('#appView, #userMenu').prop('hidden', false);
    $('#userName').text(name);
    $('#avatar').text(name.charAt(0).toUpperCase());
    view('idle');
    loadHistory(true);
  }

  /* ---------- login / sign up ---------- */
  function setMode(m) {
    S.mode = m;
    var login = m === 'login';
    $('#tabLogin').attr('aria-selected', login);
    $('#tabRegister').attr('aria-selected', !login);
    $('#authBtn .btn-label').text(login ? 'Log in' : 'Create account');
    $('#authPass').attr('autocomplete', login ? 'current-password' : 'new-password');
    $('#strength').prop('hidden', login);
    $('#authMsg').text('');
  }
  $('#tabLogin').on('click', function () { setMode('login'); });
  $('#tabRegister').on('click', function () { setMode('register'); });

  $('#pwToggle').on('click', function () {
    var $i = $('#authPass'), show = $i.attr('type') === 'password';
    $i.attr('type', show ? 'text' : 'password');
    $(this).attr('aria-label', show ? 'Hide password' : 'Show password').html(ico(show ? 'eyeoff' : 'eye'));
  });

  function strength(p) {
    var s = 0;
    if (p.length >= 8) { s++; }
    if (p.length >= 12) { s++; }
    if (/[a-z]/.test(p) && /[A-Z]/.test(p)) { s++; }
    if (/\d/.test(p) && /[^A-Za-z0-9]/.test(p)) { s++; }
    return s;
  }
  $('#authPass').on('input', function () {
    if (S.mode !== 'register') { return; }
    var s = strength(this.value);
    var names = ['Too weak', 'Weak', 'Okay', 'Good', 'Strong'];
    var cols = ['var(--neg)', 'var(--neg)', 'var(--warn)', 'var(--pos)', 'var(--pos)'];
    $('#strengthBar').css({ width: this.value ? (Math.max(s, 1) * 25) + '%' : '0%', background: cols[s] });
    $('#strengthText').text(this.value ? names[s] : '');
  });

  $('#authForm').on('submit', function (e) {
    e.preventDefault();
    var u = $.trim($('#authUser').val()), p = $('#authPass').val(), $m = $('#authMsg').text('');
    if (!/^[A-Za-z0-9_]{3,30}$/.test(u)) { $m.text('Username: 3 to 30 letters, numbers or underscores.'); return; }
    if (!p) { $m.text('Enter your password.'); return; }
    if (S.mode === 'register' && (p.length < 8 || p.length > 72)) { $m.text('Password must be 8 to 72 characters.'); return; }
    var registering = S.mode === 'register';
    setBusy($('#authBtn'), true);
    $.ajax({ url: 'api/' + (registering ? 'register.php' : 'login.php'), method: 'POST', data: { username: u, password: p }, dataType: 'json' })
      .done(function (d) {
        showApp(d.username);
        toast(registering ? 'Account created. Welcome, ' + d.username + '!' : 'Welcome back, ' + d.username, 'ok');
      })
      .fail(function (xhr) { $m.text(errMsg(xhr, 'Something went wrong. Please try again.')); })
      .always(function () { setBusy($('#authBtn'), false); });
  });

  $('#logoutBtn').on('click', function () {
    $.post('api/logout.php').always(function () {
      showAuth();
      toast('Logged out. Your collected raw data was deleted.', 'ok');
    });
  });

  /* ---------- progress ---------- */
  function startTick() {
    stopTick();
    var t0 = Date.now();
    $('#elapsed').text('0:00');
    S.tick = setInterval(function () {
      var s = Math.floor((Date.now() - t0) / 1000);
      $('#elapsed').text(Math.floor(s / 60) + ':' + ('0' + (s % 60)).slice(-2));
    }, 1000);
  }
  function stopTick() { clearInterval(S.tick); }
  function setStep(idx) {
    $('#steps .step').each(function (i) {
      $(this).toggleClass('is-done', i < idx).toggleClass('is-active', i === idx);
      $(this).find('.num').html(i < idx ? ico('check') : String(i + 1));
    });
  }
  function showWorking() {
    if (!$('#progress').prop('hidden')) { return; }
    view('working'); startTick(); setBusy($('#analyzeBtn'), true);
    $('#progTopic').text(S.topic ? '"' + S.topic + '"' : 'your search');
  }

  /* ---------- run + poll ---------- */
  function run(topic) {
    topic = $.trim(topic);
    if ($('#analyzeBtn').prop('disabled')) { return; }
    if (!topic) { toast('Type a topic first.', 'error'); $('#topic').trigger('focus'); return; }
    $('#topic').val(topic);
    S.topic = topic;
    view('idle'); showWorking(); setStep(0); $('#progMsg').text('Starting...');
    $.ajax({ url: 'api/analyze.php', method: 'POST', data: { topic: topic }, dataType: 'json' })
      .done(function (d) { S.jobId = d.job_id; poll(d.job_id); loadHistory(); })
      .fail(function (xhr) {
        if (xhr.status === 401) { showAuth(); return; }
        stopTick(); setBusy($('#analyzeBtn'), false); view('idle');
        toast(errMsg(xhr, 'Could not start the analysis.'), 'error');
      });
  }

  function poll(jobId) {
    var id = ++S.pollId;
    (function step() {
      $.getJSON('api/status.php', { job_id: jobId }).done(function (s) {
        if (id !== S.pollId) { return; }
        if (s.status === 'done') { finishJob(jobId, id); return; }
        if (s.status === 'failed') { failJob(s.error || 'unknown error'); return; }
        showWorking();
        setStep(s.status === 'analyzing' ? 1 : 0);
        $('#progMsg').text(s.message || 'Working...');
        setTimeout(step, 2500);
      }).fail(function (xhr) {
        if (id !== S.pollId) { return; }
        if (xhr.status === 401) { showAuth(); return; }
        stopTick(); setBusy($('#analyzeBtn'), false); view('idle');
        toast('Lost connection to the server.', 'error');
      });
    })();
  }

  function finishJob(jobId, id) {
    $.getJSON('api/results.php', { job_id: jobId }).done(function (d) {
      if (id !== S.pollId) { return; }
      stopTick(); setBusy($('#analyzeBtn'), false);
      S.data = d; S.jobId = jobId;
      render(d); view('results'); animate(); loadHistory();
      $('html,body').animate({ scrollTop: Math.max(0, $('#results').offset().top - 90) }, reduceMotion ? 0 : 350);
    }).fail(function () {
      stopTick(); setBusy($('#analyzeBtn'), false); view('idle');
      toast('Could not load the results.', 'error');
    });
  }
  function failJob(msg) {
    stopTick(); setBusy($('#analyzeBtn'), false); view('idle');
    toast('Analysis failed: ' + msg, 'error');
    loadHistory();
  }

  /* ---------- history ---------- */
  function renderHistory(jobs) {
    var $h = $('#history').empty();
    if (!jobs.length) { $h.html('<p class="muted small">Your searches will appear here.</p>'); return; }
    $.each(jobs, function (i, j) {
      var cls = j.status === 'done' ? 'ok' : (j.status === 'failed' ? 'bad' : 'run');
      var lab = j.status === 'done' ? 'Done' : (j.status === 'failed' ? 'Failed' : 'Running');
      $h.append('<button type="button" class="h-item' + (j.id == S.jobId ? ' is-on' : '') + '" data-id="' + Number(j.id) + '">' +
        '<span class="h-topic">' + esc(j.topic) + '</span>' +
        '<span class="h-meta"><span class="dot ' + cls + '"></span>' + lab + ' &middot; ' + esc(ago(j.created_at)) +
        (j.item_count > 0 ? ' &middot; ' + Number(j.item_count) + ' items' : '') + '</span></button>');
    });
  }
  function loadHistory(first) {
    $.getJSON('api/history.php').done(function (r) {
      var jobs = r.jobs || [];
      renderHistory(jobs);
      var j = jobs[0];
      if (first && j && /^(queued|collecting|analyzing)$/.test(j.status) && minutesAgo(j.created_at) < 20) {
        S.topic = j.topic; S.jobId = j.id; poll(j.id);
      }
    }).fail(function (xhr) { if (xhr.status === 401) { showAuth(); } });
  }
  $('#history').on('click', '.h-item', function () {
    S.topic = $(this).find('.h-topic').text();
    S.jobId = $(this).data('id');
    $('.h-item').removeClass('is-on'); $(this).addClass('is-on');
    $('#progress').prop('hidden', true);
    view('loading'); poll(S.jobId);
    if (window.innerWidth <= 960) { $('html,body').animate({ scrollTop: 0 }, 200); }
  });

  /* ---------- rendering ---------- */
  function kpi(label, value, sub) {
    return '<div class="kpi"><p class="kpi-label">' + esc(label) + '</p><p class="kpi-value">' + value +
           '</p><p class="kpi-sub">' + esc(sub || '') + '</p></div>';
  }
  function counter(n, suffix) {
    return '<span data-count="' + Number(n) + '" data-suffix="' + (suffix || '') + '">0' + (suffix || '') + '</span>';
  }
  function postsHtml(filter) {
    var list = ((S.data && S.data.samples) || []).filter(function (p) { return filter === 'all' || p.stance === filter; });
    if (!list.length) { return '<li class="muted small post">No posts in this group.</li>'; }
    return list.map(function (p) {
      var st = STANCE[p.stance] || STANCE.neutral, url = safeUrl(p.url), isX = p.source === 'x';
      return '<li class="post"><div class="post-meta"><span class="badge ' + (isX ? 'src-x' : 'src-reddit') + '">' + (isX ? 'X' : 'Reddit') + '</span>' +
        (p.community ? '<span class="muted small">r/' + esc(p.community) + '</span>' : '') +
        '<span class="pill ' + st.cls + '">' + st.name + '</span>' +
        '<span class="score" title="Score">' + ico('up') + (Number(p.score) || 0) + '</span></div>' +
        '<p class="post-text">' + esc(p.text) + '</p>' +
        (url ? '<a class="link" href="' + esc(url) + '" target="_blank" rel="noopener noreferrer">Open original ' + ico('external') + '</a>' : '') +
        '</li>';
    }).join('');
  }

  function render(d) {
    var st = d.stance || {}, src = d.sources || {}, f = d.filter || null, total = d.total || 0;
    var maj = d.majority || { label: 'n/a', percent: 0 };
    var h = '';

    h += '<div class="res-head"><div><p class="eyebrow">Results</p><h2>' + esc(d.topic) + '</h2>' +
         '<p class="muted">' + total + ' on-topic posts analyzed</p></div>' +
         '<button class="btn btn-ghost" id="dlBtn" type="button">' + ico('download') + '<span>Download JSON</span></button></div>';

    if (d.demo) {
      h += '<div class="alert warn" role="alert">' + ico('alert') + '<div><strong>Demo values</strong><span>This is an older search that used placeholder analysis.</span></div></div>';
    }
    $.each(d.warnings || [], function (i, w) {
      h += '<div class="alert warn" role="alert">' + ico('alert') + '<div><strong>Heads up</strong><span>' + esc(w) + '</span></div></div>';
    });

    h += '<div class="kpis">' +
      kpi('Posts analyzed', counter(total), f ? f.collected + ' collected' : '') +
      (f && f.collected ? kpi('On-topic rate', counter(Math.round(100 * f.on_topic / f.collected), '%'), f.off_topic + ' filtered out') : '') +
      kpi('Majority view', '<span class="t-' + tone(maj.label) + '">' + esc(maj.percent) + '%</span>', maj.label) +
      kpi('Themes found', counter((d.themes || []).length), 'topics people discuss') +
      '</div>';

    var legend = KEYS.map(function (k) {
      return '<li><span class="dot ' + STANCE[k].cls + '"></span>' + STANCE[k].name + '<b>' + (Number(st[k]) || 0) + '%</b></li>';
    }).join('');
    var rd = Number(src.reddit) || 0, xx = Number(src.x) || 0, sum = (rd + xx) || 1;
    var facts = f
      ? '<ul class="facts"><li><span>Collected</span><b>' + f.collected + '</b></li><li><span>On topic</span><b>' + f.on_topic +
        '</b></li><li><span>Filtered out (off-topic)</span><b>' + f.off_topic + '</b></li><li><span>Too short or duplicate</span><b>' + f.junk + '</b></li></ul>'
      : '';
    h += '<div class="grid-2">' +
      '<section class="card"><h3>Stance distribution</h3><p class="muted small">Estimated from the tone of each post, not a verdict on what the writer believes.</p>' +
      '<div class="donut-wrap"><div class="donut" id="donut"><div class="donut-center"><strong>' + esc(maj.percent) + '%</strong><span>' + esc(maj.label) + '</span></div></div>' +
      '<ul class="legend">' + legend + '</ul></div></section>' +
      '<section class="card"><h3>Where the data came from</h3><p class="muted small">Posts that passed the on-topic filter.</p>' +
      '<div class="split" aria-hidden="true"><span class="s-reddit" data-w="' + (100 * rd / sum) + '"></span><span class="s-x" data-w="' + (100 * xx / sum) + '"></span></div>' +
      '<ul class="legend"><li><span class="dot s-reddit"></span>Reddit<b>' + rd + '</b></li><li><span class="dot s-x"></span>X<b>' + xx + '</b></li></ul>' +
      facts + '</section></div>';

    h += '<section class="card"><h3>Major themes</h3><p class="muted small">Groups of posts that talk about similar things. Small groups are minority views.</p><ul>' +
      ($.map(d.themes || [], function (t) {
        var share = Number(t.share) || 0;
        return '<li class="theme"><div class="theme-top"><span class="theme-name">' + esc(t.label) +
          (share < 15 ? ' <span class="pill">Minority</span>' : '') + '</span><span class="theme-pct">' + share + '%</span></div>' +
          '<div class="track"><div class="fill" data-w="' + share + '"></div></div></li>';
      }).join('') || '<li class="muted small">No themes found.</li>') + '</ul></section>';

    h += '<section class="card"><h3>Potential outliers</h3><p class="muted small">A minority opinion is unpopular. An outlier is statistically unlike everything else in the discussion.</p><ul>' +
      ($.map(d.outliers || [], function (o) {
        return '<li class="outlier"><span class="badge badge-warn">Outlier</span><p>' + esc(o.text) + '</p><p class="muted small">' + esc(o.reason) + '</p></li>';
      }).join('') || '<li class="muted small">No outliers flagged.</li>') + '</ul></section>';

    h += '<section class="card"><h3>Supporting posts</h3><p class="muted small">Highest-scoring examples from each group.</p>' +
      '<div class="chip-row" role="group" aria-label="Filter posts by stance">' +
      ['all'].concat(KEYS).map(function (k, i) {
        return '<button type="button" class="chip' + (i === 0 ? ' is-on' : '') + '" data-f="' + k + '">' + (k === 'all' ? 'All' : STANCE[k].name) + '</button>';
      }).join('') + '</div><ul class="posts" id="posts">' + postsHtml('all') + '</ul></section>';

    if ((d.stats || []).length) {
      h += '<details class="card"><summary>Full statistics</summary><ul class="facts">' +
        $.map(d.stats, function (s) { return '<li><span>' + esc(s) + '</span></li>'; }).join('') + '</ul></details>';
    }
    $('#results').html(h);
  }

  $('#results').on('click', '.chip', function () {
    $('#results .chip').removeClass('is-on'); $(this).addClass('is-on');
    $('#posts').html(postsHtml($(this).data('f')));
  });
  $('#results').on('click', '#dlBtn', function () {
    var blob = new Blob([JSON.stringify(S.data, null, 2)], { type: 'application/json' });
    var a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = 'opinionmap-' + (String(S.data.topic || 'results').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '') || 'results') + '.json';
    document.body.appendChild(a); a.click(); a.remove();
    setTimeout(function () { URL.revokeObjectURL(a.href); }, 1000);
  });

  /* ---------- animations ---------- */
  function count($el) {
    var to = Number($el.data('count')) || 0, suf = $el.data('suffix') || '', t0 = null;
    if (reduceMotion) { $el.text(to + suf); return; }
    function frame(ts) {
      if (!t0) { t0 = ts; }
      var p = Math.min(1, (ts - t0) / 900);
      $el.text(Math.round(to * (1 - Math.pow(1 - p, 3))) + suf);
      if (p < 1) { requestAnimationFrame(frame); }
    }
    requestAnimationFrame(frame);
  }
  function drawDonut() {
    var el = document.getElementById('donut');
    if (!el) { return; }
    var st = (S.data && S.data.stance) || {}, NS = 'http://www.w3.org/2000/svg';
    var svg = document.createElementNS(NS, 'svg');
    svg.setAttribute('viewBox', '0 0 42 42');
    svg.setAttribute('role', 'img');
    svg.setAttribute('aria-label', 'Stance distribution: ' + KEYS.map(function (k) { return STANCE[k].name + ' ' + (Number(st[k]) || 0) + '%'; }).join(', '));
    function circle(cls) {
      var c = document.createElementNS(NS, 'circle');
      c.setAttribute('class', cls); c.setAttribute('cx', 21); c.setAttribute('cy', 21); c.setAttribute('r', 15.9155);
      return c;
    }
    svg.appendChild(circle('track-c'));
    var acc = 0;
    KEYS.forEach(function (k) {
      var v = Math.max(0, Number(st[k]) || 0);
      if (!v) { return; }
      var c = circle('seg seg-' + k);
      c.style.strokeDasharray = '0 100';
      c.style.strokeDashoffset = String(25 - acc);
      svg.appendChild(c);
      requestAnimationFrame(function () { requestAnimationFrame(function () { c.style.strokeDasharray = v + ' ' + (100 - v); }); });
      acc += v;
    });
    el.insertBefore(svg, el.firstChild);
  }
  function animate() {
    function go() {
      $('#results [data-w]').each(function () { $(this).css('width', Math.min(100, Number($(this).data('w')) || 0) + '%'); });
      $('#results [data-count]').each(function () { count($(this)); });
    }
    drawDonut();
    if (reduceMotion) { go(); } else { requestAnimationFrame(function () { requestAnimationFrame(go); }); }
  }

  /* ---------- search form, examples, shortcuts ---------- */
  $('#searchForm').on('submit', function (e) { e.preventDefault(); run($('#topic').val()); });
  $('#examples').on('click', '.chip', function () { run($(this).text()); });
  $(document).on('keydown', function (e) {
    if (e.key === '/' && !/^(INPUT|TEXTAREA|SELECT)$/.test(e.target.tagName) && !$('#appView').prop('hidden')) {
      e.preventDefault(); $('#topic').trigger('focus');
    }
  });

  /* ---------- start ---------- */
  $('#year').text(new Date().getFullYear());
  setMode(location.hash === '#signup' ? 'register' : 'login');
  $.getJSON('api/me.php').done(function (d) { showApp(d.username); }).fail(function () { showAuth(); });
});
