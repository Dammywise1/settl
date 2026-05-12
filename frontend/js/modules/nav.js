const NAV = [
  { label: 'Dashboard',       href: '/pages/dashboard.html',               icon: '◈' },
  { label: 'Create payment',  href: '/pages/merchant/paylink.html',        icon: '⊕' },
  { label: 'Payment links',   href: '/pages/merchant/links.html',          icon: '🔗' },
  { label: 'Payments',        href: '/pages/merchant/payments.html',       icon: '↑' },
  { label: 'Transactions',    href: '/pages/merchant/transactions.html',   icon: '≡' },
  { label: 'Balance',         href: '/pages/merchant/balance.html',        icon: '$' },
  { label: 'Webhooks',        href: '/pages/merchant/webhooks.html',       icon: '⌁' },
  { label: 'API keys',        href: '/pages/merchant/apikeys.html',        icon: '⌘' },
  { label: 'Docs',            href: '/pages/docs/index.html',              icon: '?' },
  { label: 'Settings',        href: '/pages/merchant/settings.html',       icon: '⚙' },
];

function initSidebar() {
  const sidebar = document.getElementById('sidebar');
  const overlay = document.getElementById('sidebar-overlay');
  if (!sidebar) return;

  const user     = window.auth?.getUser();
  const merchant = window.auth?.getMerchant();
  const current  = window.location.pathname;

  sidebar.innerHTML = `
    <div class="sidebar-logo">
      <span>SETTL</span>
      <button class="modal-close" onclick="closeSidebar()" style="font-size:22px;">×</button>
    </div>
    <div class="sidebar-section">Merchant</div>
    ${NAV.map(item => {
      const page   = item.href.split('/').pop();
      const active = current.endsWith(page);
      return `<a href="${item.href}" class="nav-item ${active?'active':''}" onclick="closeSidebar()">
        <span class="nav-icon">${item.icon}</span>${item.label}
      </a>`;
    }).join('')}
    <div class="sidebar-footer">
      <div class="sidebar-user-name">${user?.full_name||user?.email||''}</div>
      <div class="sidebar-user-email">${user?.email||''}</div>
      ${merchant?`<div style="margin:6px 0;"><span class="badge ${merchant.is_active?'badge-success':'badge-pending'}">${merchant.is_active?'Active':'Setting up…'}</span></div>`:''}
      <br/>
      <a href="#" onclick="handleLogout()" style="font-size:12px;color:var(--text-hint);">Sign out</a>
    </div>`;

  if (overlay) overlay.onclick = closeSidebar;
  fetch('/api/health').then(r=>r.json()).then(d=>{
    if(d.config?.supabase_url)      window.__SUPABASE_URL__      = d.config.supabase_url;
    if(d.config?.supabase_anon_key) window.__SUPABASE_ANON_KEY__ = d.config.supabase_anon_key;
  }).catch(()=>{});
}

function openSidebar()  { document.getElementById('sidebar')?.classList.add('open');    document.getElementById('sidebar-overlay')?.classList.add('show'); }
function closeSidebar() { document.getElementById('sidebar')?.classList.remove('open'); document.getElementById('sidebar-overlay')?.classList.remove('show'); }

async function handleLogout() {
  try { await window.api.auth.logout(); } catch {}
  window.auth.clear();
  window.location.href = '/pages/auth/login.html';
}

window.initSidebar=initSidebar; window.openSidebar=openSidebar;
window.closeSidebar=closeSidebar; window.handleLogout=handleLogout;
