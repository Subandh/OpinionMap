(function () {
  'use strict';
  var doc = document;
  var reduce = window.matchMedia && matchMedia('(prefers-reduced-motion: reduce)').matches;

  /* dark / light mode */
  doc.getElementById('themeBtn').addEventListener('click', function () {
    var el = doc.documentElement;
    var t = el.getAttribute('data-theme') === 'dark' ? 'light' : 'dark';
    el.setAttribute('data-theme', t);
    try { localStorage.setItem('om-theme', t); } catch (e) {}
  });

  /* mobile menu */
  var menuBtn = doc.getElementById('menuBtn');
  var nav = doc.getElementById('nav');
  function setMenu(open) {
    nav.classList.toggle('is-open', open);
    menuBtn.setAttribute('aria-expanded', open ? 'true' : 'false');
    menuBtn.setAttribute('aria-label', open ? 'Close menu' : 'Open menu');
  }
  menuBtn.addEventListener('click', function () { setMenu(!nav.classList.contains('is-open')); });
  nav.addEventListener('click', function (e) { if (e.target.tagName === 'A') { setMenu(false); } });
  doc.addEventListener('keydown', function (e) { if (e.key === 'Escape') { setMenu(false); } });

  /* top bar shadow and back-to-top button */
  var topbar = doc.querySelector('.topbar');
  var toTop = doc.getElementById('toTop');
  function onScroll() {
    var y = window.scrollY || doc.documentElement.scrollTop;
    topbar.classList.toggle('is-scrolled', y > 8);
    toTop.hidden = y < 700;
  }
  window.addEventListener('scroll', onScroll, { passive: true });
  onScroll();
  toTop.addEventListener('click', function () {
    window.scrollTo({ top: 0, behavior: reduce ? 'auto' : 'smooth' });
  });

  /* fade-in on scroll */
  var items = doc.querySelectorAll('.reveal');
  if ('IntersectionObserver' in window && !reduce) {
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (en) {
        if (en.isIntersecting) { en.target.classList.add('is-in'); io.unobserve(en.target); }
      });
    }, { threshold: 0.12 });
    items.forEach(function (el) { io.observe(el); });
  } else {
    items.forEach(function (el) { el.classList.add('is-in'); });
  }

  /* highlight the nav link for the section on screen */
  var links = [].slice.call(doc.querySelectorAll('.nav a[href^="#"]'));
  var byId = {};
  links.forEach(function (a) { byId[a.getAttribute('href').slice(1)] = a; });
  if ('IntersectionObserver' in window) {
    var spy = new IntersectionObserver(function (entries) {
      entries.forEach(function (en) {
        var a = byId[en.target.id];
        if (a && en.isIntersecting) {
          links.forEach(function (l) { l.classList.remove('is-active'); });
          a.classList.add('is-active');
        }
      });
    }, { rootMargin: '-40% 0px -55% 0px' });
    Object.keys(byId).forEach(function (id) {
      var s = doc.getElementById(id);
      if (s) { spy.observe(s); }
    });
  }

  /* if the visitor is already logged in, offer the dashboard instead of sign-up */
  if (window.fetch) {
    fetch('api/session.php', { credentials: 'same-origin', cache: 'no-store' })
      .then(function (r) { return r.ok ? r.json() : null; })
      .then(function (d) {
        if (!d || !d.loggedIn) { return; }
        doc.querySelectorAll('.js-guest').forEach(function (el) { el.hidden = true; });
        doc.querySelectorAll('.js-user').forEach(function (el) { el.hidden = false; });
        doc.querySelectorAll('[data-cta]').forEach(function (a) {
          a.setAttribute('href', 'app.html');
          var t = a.querySelector('.cta-text');
          if (t) { t.textContent = 'Open your dashboard'; }
        });
      })
      .catch(function () {});
  }

  doc.getElementById('year').textContent = new Date().getFullYear();
})();
