(function () {
  var t = null;
  try { t = localStorage.getItem('om-theme'); } catch (e) {}
  if (!t) {
    t = (window.matchMedia && matchMedia('(prefers-color-scheme: dark)').matches) ? 'dark' : 'light';
  }
  document.documentElement.setAttribute('data-theme', t);
})();
document.documentElement.classList.add('js');
