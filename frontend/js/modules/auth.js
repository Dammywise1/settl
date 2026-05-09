const SESSION_KEY = 'settl_session';
const USER_KEY = 'settl_user';

const auth = {
  getSession() {
    try { return JSON.parse(localStorage.getItem(SESSION_KEY)); } catch { return null; }
  },

  getUser() {
    try { return JSON.parse(localStorage.getItem(USER_KEY)); } catch { return null; }
  },

  setSession(session, user) {
    localStorage.setItem(SESSION_KEY, JSON.stringify(session));
    if (user) localStorage.setItem(USER_KEY, JSON.stringify(user));
  },

  clear() {
    localStorage.removeItem(SESSION_KEY);
    localStorage.removeItem(USER_KEY);
    localStorage.removeItem('settl_mode');
  },

  isLoggedIn() {
    const s = this.getSession();
    if (!s?.token) return false;
    if (s.expires_at && new Date(s.expires_at) < new Date()) {
      this.clear();
      return false;
    }
    return true;
  },

  requireAuth() {
    if (!this.isLoggedIn()) {
      window.location.href = '/pages/auth/login.html';
      return false;
    }
    return true;
  },

  getMode() { return localStorage.getItem('settl_mode') || 'operator'; },
  setMode(mode) { localStorage.setItem('settl_mode', mode); },
  getRole() { return this.getUser()?.role || 'operator'; },
};

window.auth = auth;
