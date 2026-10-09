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
      $samples.append($('<li>').text('[' + s.source + where + (s.stance ? ', ' + s.stance : '') + '] ' + s.text + ' (score ' + s.score + ')'));
    });

    var $st = $("#stats").empty(); $.each(d.stats || [], function (i, line) { $st.append($("<li>").text(line)); });
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
