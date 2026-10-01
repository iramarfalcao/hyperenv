// Revelação ao rolar e fio sob o cabeçalho. Sem isto a página continua legível:
// .reveal só fica invisível quando há IntersectionObserver para trazê-la de volta.
(function () {
  var reduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  var top = document.querySelector('.top');
  if (top) {
    var sync = function () { top.classList.toggle('scrolled', window.scrollY > 8); };
    sync();
    window.addEventListener('scroll', sync, { passive: true });
  }

  var items = document.querySelectorAll('.reveal');
  if (reduced || !('IntersectionObserver' in window)) {
    items.forEach(function (el) { el.classList.add('visible'); });
    return;
  }
  var io = new IntersectionObserver(function (entries, obs) {
    entries.forEach(function (entry, i) {
      if (!entry.isIntersecting) return;
      entry.target.style.animationDelay = Math.min(i, 4) * 65 + 'ms';
      entry.target.classList.add('visible');
      obs.unobserve(entry.target);
    });
  }, { threshold: 0.1, rootMargin: '0px 0px -40px 0px' });
  items.forEach(function (el) { io.observe(el); });
})();
