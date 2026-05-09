const KEY_TOKEN   = 'settl_token';
const KEY_USER    = 'settl_user';
const KEY_MODE    = 'settl_mode';

const auth = {
  getToken()   { return localStorage.getItem(KEY_TOKEN); },
  getUser()    { try { return JSON.parse(localStorage.getItem(KEY_USER)); } catch { return null; } },
  getMode()    { return localStorage.getItem(KEY_MODE) || 'operator'; },
  setMode(m)   { localStorage.setItem(KEY_MODE, m); },

  save(token, user) {
    localStorage.setItem(KEY_TOKEN, token);
    localStorage.setItem(KEY_USER, JSON.stringify(user));
  },

  clear() {
    localStorage.removeItem(KEY_TOKEN);
    localStorage.removeItem(KEY_USER);
    localStorage.removeItem(KEY_MODE);
  },

  isLoggedIn() { return !!this.getToken(); },

  requireAuth() {
    if (!this.isLoggedIn()) { window.location.href = '/pages/auth/login.html'; return false; }
    return true;
  },

  getRole() { return this.getUser()?.role || 'operator'; },
};

window.auth = auth;
