const API = '/api';

function getToken() {
  try { return localStorage.getItem('settl_token'); } catch { return null; }
}

async function req(path, opts = {}) {
  const token = getToken();
  const headers = {
    'Content-Type': 'application/json',
    ...(token ? { Authorization: `Bearer ${token}` } : {}),
    ...opts.headers,
  };
  const res  = await fetch(`${API}${path}`, { ...opts, headers });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    const e = new Error(data.error || `HTTP ${res.status}`);
    e.status = res.status;
    throw e;
  }
  return data;
}

async function publicGet(path) {
  const res  = await fetch(path);
  const data = await res.json().catch(() => ({}));
  return data;
}

const api = {
  get:    (p, o)    => req(p, { ...o, method: 'GET' }),
  post:   (p, b, o) => req(p, { ...o, method: 'POST',   body: JSON.stringify(b) }),
  patch:  (p, b, o) => req(p, { ...o, method: 'PATCH',  body: JSON.stringify(b) }),
  delete: (p, o)    => req(p, { ...o, method: 'DELETE' }),

  auth: {
    signup:  (b)               => api.post('/auth/signup', b),
    login:   (email, password) => api.post('/auth/login', { email, password }),
    logout:  ()                => api.post('/auth/logout', {}),
    me:      ()                => api.get('/auth/me'),
    status:  ()                => api.get('/auth/status'),
    profile: (u)               => api.patch('/auth/profile', u),
  },

  merchant: {
    me:           () => api.get('/merchants/me'),
    sessions:     () => api.get('/merchants/me/sessions'),
    releases:     () => api.get('/merchants/me/releases'),
    transactions: (p) => api.get('/merchants/me/transactions?' + new URLSearchParams(p||{})),
    releaseNow:   () => api.post('/release/me', {}),
  },

  payments: {
    session:     (b)   => api.post('/payments/session', b),
    pollPublic:  (ref) => publicGet(`/api/public/poll/${ref}`),
    sessionInfo: (ref) => publicGet(`/api/public/session/${ref}`),
    linkInfo:    (slug)=> publicGet(`/api/public/link/${slug}`),
    saveNote:    (ref, note) => fetch(`/api/public/note/${ref}`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ note }),
    }).then(r => r.json()),
    history:     ()    => api.get('/payments/history'),
  },

  links: {
    list:     ()       => api.get('/links'),
    create:   (b)      => api.post('/links', b),
    update:   (id, b)  => api.patch(`/links/${id}`, b),
    delete:   (id)     => api.delete(`/links/${id}`),
    sessions: (id)     => api.get(`/links/${id}/sessions`),
  },

  webhooks: {
    list:       ()      => api.get('/webhooks'),
    create:     (b)     => api.post('/webhooks', b),
    update:     (id, b) => api.patch(`/webhooks/${id}`, b),
    delete:     (id)    => api.delete(`/webhooks/${id}`),
    test:       ()      => api.post('/webhooks/test', {}),
    deliveries: ()      => api.get('/webhooks/deliveries'),
  },

  apikeys: {
    list:   ()     => api.get('/apikeys'),
    create: (name) => api.post('/apikeys', { name }),
    revoke: (id)   => api.delete(`/apikeys/${id}`),
  },
};

window.api = api;
