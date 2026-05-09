// ── SETTL API client — Phase 3 ────────────────────────────
const API_BASE = '';   // same origin — served by Express

function getToken() {
  try { return JSON.parse(localStorage.getItem('settl_session'))?.access_token; }
  catch { return null; }
}

async function request(path, options = {}) {
  const token = getToken();
  const headers = {
    'Content-Type': 'application/json',
    ...(token ? { Authorization: `Bearer ${token}` } : {}),
    ...options.headers,
  };

  const res  = await fetch(`${API_BASE}/api${path}`, { ...options, headers });
  const data = await res.json();

  if (!res.ok) {
    const err = new Error(data.error || 'Request failed');
    err.status = res.status;
    throw err;
  }
  return data;
}

const api = {
  get:    (path, opts)       => request(path, { ...opts, method: 'GET' }),
  post:   (path, body, opts) => request(path, { ...opts, method: 'POST',   body: JSON.stringify(body) }),
  patch:  (path, body, opts) => request(path, { ...opts, method: 'PATCH',  body: JSON.stringify(body) }),
  delete: (path, opts)       => request(path, { ...opts, method: 'DELETE' }),

  auth: {
    register:       (email, password, full_name) => api.post('/auth/register', { email, password, full_name }),
    login:          (email, password)            => api.post('/auth/login',    { email, password }),
    logout:         ()                           => api.post('/auth/logout',   {}),
    me:             ()                           => api.get('/auth/me'),
    forgotPassword: (email)                      => api.post('/auth/forgot-password', { email }),
    resetPassword:  (new_password)               => api.post('/auth/reset-password',  { new_password }),
  },

  merchants: {
    list:                ()              => api.get('/merchants'),
    get:                 (id)            => api.get(`/merchants/${id}`),
    create:              (body)          => api.post('/merchants', body),
    getChainState:       (id)            => api.get(`/merchants/${id}/chain`),
    deactivate:          (id)            => api.post(`/merchants/${id}/deactivate`, {}),
    sync:                (id)            => api.post(`/merchants/${id}/sync`, {}),
    requestWalletUpdate: (id, newWallet) => api.post(`/merchants/${id}/wallet-update/request`, { new_wallet: newWallet }),
    confirmWalletUpdate: (id)            => api.post(`/merchants/${id}/wallet-update/confirm`, {}),
  },

  escrow: {
    get:     (merchantId)           => api.get(`/escrow/${merchantId}`),
    history: (merchantId, params)   => api.get(`/escrow/${merchantId}/history?${new URLSearchParams(params || {})}`),
  },

  payments: {
    createLink:      (body)      => api.post('/payments/link', body),
    getLink:         (token)     => api.get(`/payments/link/${token}`),
    confirmDeposit:  (body)      => api.post('/payments/confirm', body),
    listForMerchant: (id, p)     => api.get(`/payments/merchant/${id}?${new URLSearchParams(p || {})}`),
  },

  releases: {
    list:          (params)      => api.get(`/releases?${new URLSearchParams(params || {})}`),
    triggerManual: (merchantId)  => api.post('/releases/trigger', { merchant_id: merchantId }),
    cronStatus:    ()            => api.get('/releases/cron-status'),
  },
};

window.api = api;
