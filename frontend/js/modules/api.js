const API = '/api';

function getToken() {
  try { return localStorage.getItem('settl_token'); } catch { return null; }
}

async function req(path, opts = {}) {
  const token = getToken();
  const headers = { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}), ...opts.headers };
  const res  = await fetch(`${API}${path}`, { ...opts, headers });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) { const e = new Error(data.error || `HTTP ${res.status}`); e.status = res.status; throw e; }
  return data;
}

const api = {
  get:    (p, o)    => req(p, { ...o, method: 'GET' }),
  post:   (p, b, o) => req(p, { ...o, method: 'POST',  body: JSON.stringify(b) }),
  patch:  (p, b, o) => req(p, { ...o, method: 'PATCH', body: JSON.stringify(b) }),
  delete: (p, o)    => req(p, { ...o, method: 'DELETE' }),

  auth: {
    signup:  (email, password, full_name) => api.post('/auth/signup', { email, password, full_name }),
    login:   (email, password)            => api.post('/auth/login',  { email, password }),
    logout:  ()                           => api.post('/auth/logout', {}),
    me:      ()                           => api.get('/auth/me'),
    profile: (u)                          => api.patch('/auth/profile', u),
  },

  merchants: {
    list:                ()               => api.get('/merchants'),
    get:                 (id)             => api.get(`/merchants/${id}`),
    create:              (b)              => api.post('/merchants', b),
    getChainState:       (id)             => api.get(`/merchants/${id}/chain`),
    deactivate:          (id)             => api.post(`/merchants/${id}/deactivate`, {}),
    requestWalletUpdate: (id, w)          => api.post(`/merchants/${id}/wallet-update/request`, { new_wallet: w }),
    confirmWalletUpdate: (id)             => api.post(`/merchants/${id}/wallet-update/confirm`, {}),
  },

  escrow: {
    get:     (id)     => api.get(`/escrow/${id}`),
    history: (id)     => api.get(`/escrow/${id}/history`),
  },

  payments: {
    session: (b)    => api.post('/payments/session', b),
    poll:    (ref)  => fetch(`${API}/payments/poll/${ref}`).then(r => r.json()),
    history: ()     => api.get('/payments/history'),
  },

  release: {
    all:          ()   => api.post('/release/all', {}),
    one:          (id) => api.post(`/release/${id}`, {}),
    logs:         ()   => api.get('/release/logs'),
    merchantLogs: (id) => api.get(`/release/merchant-logs/${id}`),
  },
};

window.api = api;
