const NAV = {
  operator: [
    { label: 'Overview',     href: '/pages/dashboard.html',         icon: '◈' },
    { label: 'Payments',     href: '/pages/operator/payments.html', icon: '↑' },
    { label: 'Balance',      href: '/pages/operator/balance.html',  icon: '$' },
    { label: 'Payment link', href: '/pages/operator/paylink.html',  icon: '⊕' },
    { label: 'Settings',     href: '/pages/operator/settings.html', icon: '⚙' },
  ],
  developer: [
    { label: 'Overview',      href: '/pages/dashboard.html',                  icon: '◈' },
    { label: 'Merchants',     href: '/pages/developer/merchants.html',         icon: '⊞' },
    { label: 'Escrow viewer', href: '/pages/developer/escrow.html',            icon: '⬡' },
    { label: 'Transactions',  href: '/pages/developer/transactions.html',      icon: '≡' },
    { label: 'Cron monitor',  href: '/pages/developer/cron.html',              icon: '◷' },
  ],
};

function buildSidebar(mode) {
  const user    = window.auth?.getUser();
  const role    = user?.role || 'operator';
  const items   = NAV[mode] || NAV.operator;
  const current = window.location.pathname;

  return `
    <div class="sidebar-logo">
      <span>SETTL</span>
      <button class="modal-close" onclick="closeSidebar()" style="display:none;" id="sidebar-close-btn">×</button>
    </div>
    <div style="padding:10px 8px 4px;">
      <div class="mode-switch" style="width:100%;">
        <button class="mode-btn ${mode==='operator'?'active':''}"  onclick="switchMode('operator')">Operator</button>
        ${role==='developer' ? `<button class="mode-btn ${mode==='developer'?'active':''}" onclick="switchMode('developer')">Developer</button>` : ''}
      </div>
    </div>
    <div class="sidebar-section">${mode==='developer'?'Developer':'Business'}</div>
    ${items.map(item => {
      const page   = item.href.split('/').pop();
      const active = current.endsWith(page);
      return `<a href="${item.href}" class="nav-item ${active?'active':''}" onclick="closeSidebar()">
        <span class="nav-icon">${item.icon}</span>${item.label}
      </a>`;
    }).join('')}
    <div class="sidebar-footer">
      <div class="sidebar-user-name">${user?.full_name || user?.email || 'User'}</div>
      <div class="sidebar-user-email">${user?.email || ''}</div>
      <span class="badge ${role==='developer'?'badge-info':'badge-success'}">${role}</span><br/><br/>
      <a href="#" onclick="handleLogout()" style="font-size:12px;color:var(--text-hint);">Sign out</a>
    </div>`;
}

function initSidebar(mode) {
  const sidebar  = document.getElementById('sidebar');
  const overlay  = document.getElementById('sidebar-overlay');
  const closeBtn = document.getElementById('sidebar-close-btn');
  if (sidebar) {
    sidebar.innerHTML = buildSidebar(mode);
    // Show close button inside sidebar on mobile
    const cb = sidebar.querySelector('#sidebar-close-btn');
    if (cb) cb.style.display = '';
  }
  if (overlay) overlay.onclick = closeSidebar;
}

function openSidebar() {
  document.getElementById('sidebar')?.classList.add('open');
  document.getElementById('sidebar-overlay')?.classList.add('show');
}
function closeSidebar() {
  document.getElementById('sidebar')?.classList.remove('open');
  document.getElementById('sidebar-overlay')?.classList.remove('show');
}

function switchMode(mode) {
  auth.setMode(mode);
  initSidebar(mode);
}

async function handleLogout() {
  try { await api.auth.logout(); } catch {}
  auth.clear();
  window.location.href = '/pages/auth/login.html';
}

window.buildSidebar = buildSidebar;
window.initSidebar  = initSidebar;
window.openSidebar  = openSidebar;
window.closeSidebar = closeSidebar;
window.switchMode   = switchMode;
window.handleLogout = handleLogout;
