// ── SETTL API client — Phase 2 ────────────────────────────
const API_BASE = 'http://localhost:3000/api';

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

  const res  = await fetch(`${API_BASE}${path}`, { ...options, headers });
  const data = await res.json();

  if (!res.ok) {
    const err = new Error(data.error || 'Request failed');
    err.status = res.status;
    throw err;
  }
  return data;
}

const api = {
  get:    (path, opts)        => request(path, { ...opts, method: 'GET'    }),
  post:   (path, body, opts)  => request(path, { ...opts, method: 'POST',   body: JSON.stringify(body) }),
  patch:  (path, body, opts)  => request(path, { ...opts, method: 'PATCH',  body: JSON.stringify(body) }),
  delete: (path, opts)        => request(path, { ...opts, method: 'DELETE' }),

  auth: {
    login:  (email) => api.post('/auth/login', { email }),
    me:     ()      => api.get('/auth/me'),
    logout: ()      => api.post('/auth/logout', {}),
  },

  merchants: {
    list:               ()                      => api.get('/merchants'),
    get:                (id)                    => api.get(`/merchants/${id}`),
    create:             (body)                  => api.post('/merchants', body),
    getChainState:      (id)                    => api.get(`/merchants/${id}/chain`),
    deactivate:         (id)                    => api.post(`/merchants/${id}/deactivate`, {}),
    sync:               (id)                    => api.post(`/merchants/${id}/sync`, {}),
    requestWalletUpdate: (id, newWallet)        => api.post(`/merchants/${id}/wallet-update/request`, { new_wallet: newWallet }),
    confirmWalletUpdate: (id)                   => api.post(`/merchants/${id}/wallet-update/confirm`, {}),
  },

  escrow: {
    get:     (merchantId)          => api.get(`/escrow/${merchantId}`),
    history: (merchantId, params)  => api.get(`/escrow/${merchantId}/history?${new URLSearchParams(params || {})}`),
  },
};

window.api = api;
