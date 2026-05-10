(function () {
  const c = document.createElement('div');
  c.id = 'toast-container';
  document.body.appendChild(c);
  function show(msg, type='info', ms=4000) {
    const t = document.createElement('div');
    t.className = `toast ${type}`;
    t.textContent = msg;
    c.appendChild(t);
    setTimeout(() => { t.style.transition='opacity .3s'; t.style.opacity='0'; setTimeout(()=>t.remove(),320); }, ms);
  }
  window.toast = { success: m=>show(m,'success'), error: m=>show(m,'error',6000), info: m=>show(m,'info') };
})();
