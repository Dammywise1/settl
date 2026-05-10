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
  if (!res.ok) { const e = new Error(data.error || `HTTP ${res.status}`); e.status = res.status; throw e; }
  return data;
}

const api = {
  get:    (p, o)    => req(p, { ...o, method: 'GET' }),
  post:   (p, b, o) => req(p, { ...o, method: 'POST',  body: JSON.stringify(b) }),
  patch:  (p, b, o) => req(p, { ...o, method: 'PATCH', body: JSON.stringify(b) }),

  auth: {
    signup:  (b)              => api.post('/auth/signup', b),
    login:   (email, password)=> api.post('/auth/login', { email, password }),
    logout:  ()               => api.post('/auth/logout', {}),
    me:      ()               => api.get('/auth/me'),
    status:  ()               => api.get('/auth/status'),
  },

  merchant: {
    me:       ()  => api.get('/merchants/me'),
    sessions: ()  => api.get('/merchants/me/sessions'),
    releases: ()  => api.get('/merchants/me/releases'),
    releaseNow: ()=> api.post('/release/me', {}),
  },

  payments: {
    session:      (b)   => api.post('/payments/session', b),
    pollPublic:   (ref) => fetch(`${API}/payments/poll/${ref}`).then(r=>r.json()),
    sessionInfo:  (ref) => fetch(`${API}/payments/session/${ref}`).then(r=>r.json()),
    history:      ()    => api.get('/payments/history'),
  },
};

window.api = api;
