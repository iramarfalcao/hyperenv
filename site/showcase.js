// Native image viewer: keyboard support and focus restoration are provided by dialog.
(() => {
  const pt = document.documentElement.lang.startsWith('pt');
  const images = document.querySelectorAll('[data-zoom]');
  if (images.length && typeof HTMLDialogElement !== 'undefined') {
    const dialog = document.createElement('dialog');
    dialog.className = 'image-viewer';
    dialog.setAttribute('aria-label', pt ? 'Imagem ampliada do aplicativo' : 'Enlarged app screenshot');
    const close = document.createElement('button');
    close.type = 'button';
    close.className = 'viewer-close';
    close.textContent = pt ? 'Fechar ×' : 'Close ×';
    const full = document.createElement('img');
    const caption = document.createElement('p');
    dialog.append(close, full, caption);
    document.body.append(dialog);
    close.addEventListener('click', () => dialog.close());
    dialog.addEventListener('click', event => { if (event.target === dialog) dialog.close(); });
    images.forEach(img => {
      if (img.closest('a, button')) return;
      const button = document.createElement('button');
      button.type = 'button';
      button.className = 'zoom-trigger';
      button.setAttribute('aria-label', (pt ? 'Ampliar: ' : 'Enlarge: ') + img.alt);
      button.title = pt ? 'Clique para ampliar' : 'Click to enlarge';
      const target = img.closest('picture') || img;
      target.before(button);
      button.append(target);
      button.addEventListener('click', () => {
        full.src = img.currentSrc || img.src;
        full.alt = img.alt;
        caption.textContent = img.alt;
        dialog.showModal();
      });
    });
  }
  if (!window.matchMedia('(prefers-reduced-motion: reduce)').matches && 'IntersectionObserver' in window) {
    const observer = new IntersectionObserver((entries, current) => {
      entries.forEach((entry, index) => {
        if (!entry.isIntersecting) return;
        entry.target.style.animationDelay = `${Math.min(index, 3) * 60}ms`;
        entry.target.classList.add('showcase-visible');
        current.unobserve(entry.target);
      });
    }, { threshold: 0.1 });
    document.querySelectorAll('[data-motion]').forEach(el => observer.observe(el));
  }
})();
