// ── Sidebar navigation builder ────────────────────────────
const NAV = {
  operator: [
    { label: 'Overview',        href: '/pages/dashboard.html',           icon: '◈' },
    { label: 'Payments',        href: '/pages/operator/payments.html',    icon: '↑' },
    { label: 'Balance',         href: '/pages/operator/balance.html',     icon: '$' },
    { label: 'Payment link',    href: '/pages/operator/paylink.html',     icon: '⊕' },
    { label: 'Settings',        href: '/pages/operator/settings.html',    icon: '⚙' },
  ],
  developer: [
    { label: 'Overview',        href: '/pages/dashboard.html',            icon: '◈' },
    { label: 'Merchants',       href: '/pages/developer/merchants.html',  icon: '⊞' },
    { label: 'Escrow viewer',   href: '/pages/developer/escrow.html',     icon: '⬡' },
    { label: 'Transactions',    href: '/pages/developer/transactions.html',icon: '≡' },
    { label: 'API keys',        href: '/pages/developer/apikeys.html',    icon: '⌘' },
    { label: 'Webhooks',        href: '/pages/developer/webhooks.html',   icon: '⌁' },
    { label: 'Cron monitor',    href: '/pages/developer/cron.html',       icon: '◷' },
  ],
};

function buildSidebar(mode) {
  const profile = window.auth?.getProfile();
  const role    = profile?.role || 'operator';
  const items   = NAV[mode] || NAV.operator;
  const current = window.location.pathname;

  return `
    <div class="sidebar-logo">SETTL</div>
    <div style="padding: 12px 8px 4px;">
      <div class="mode-switch" style="width:100%;">
        <button class="mode-btn ${mode === 'operator'  ? 'active' : ''}" onclick="switchMode('operator')">Operator</button>
        ${role === 'developer' ? `<button class="mode-btn ${mode === 'developer' ? 'active' : ''}" onclick="switchMode('developer')">Developer</button>` : ''}
      </div>
    </div>
    <div class="sidebar-section">${mode === 'developer' ? 'Developer' : 'Business'}</div>
    ${items.map(item => `
      <a href="${item.href}" class="nav-item ${current.includes(item.href.split('/').pop().replace('.html','')) ? 'active' : ''}">
        <span style="font-size:16px;">${item.icon}</span> ${item.label}
      </a>`).join('')}
    <div class="sidebar-footer">
      <div style="font-weight:500; font-size:13px; margin-bottom:4px;">${profile?.full_name || profile?.email || 'User'}</div>
      <a href="#" onclick="handleLogout()" style="font-size:12px; color:var(--text-hint);">Sign out</a>
    </div>
  `;
}

function switchMode(mode) {
  window.auth.setMode(mode);
  const sidebar = document.getElementById('sidebar');
  if (sidebar) sidebar.innerHTML = buildSidebar(mode);
}

async function handleLogout() {
  try { await window.api.auth.logout(); } catch {}
  window.auth.clear();
  window.location.href = '/pages/auth/login.html';
}

window.buildSidebar = buildSidebar;
window.switchMode   = switchMode;
window.handleLogout = handleLogout;
