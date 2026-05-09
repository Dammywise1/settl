// ── SETTL session manager ─────────────────────────────────
const SESSION_KEY = 'settl_session';
const PROFILE_KEY = 'settl_profile';

const auth = {
  getSession() {
    try { return JSON.parse(localStorage.getItem(SESSION_KEY)); } catch { return null; }
  },

  getProfile() {
    try { return JSON.parse(localStorage.getItem(PROFILE_KEY)); } catch { return null; }
  },

  setSession(session, profile) {
    localStorage.setItem(SESSION_KEY, JSON.stringify(session));
    if (profile) localStorage.setItem(PROFILE_KEY, JSON.stringify(profile));
  },

  clear() {
    localStorage.removeItem(SESSION_KEY);
    localStorage.removeItem(PROFILE_KEY);
    localStorage.removeItem('settl_mode');
  },

  isLoggedIn() {
    const s = this.getSession();
    if (!s?.access_token) return false;
    // Supabase sessions have expires_at in seconds
    if (s.expires_at && Math.floor(Date.now() / 1000) > s.expires_at) {
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

  getMode()        { return localStorage.getItem('settl_mode') || 'operator'; },
  setMode(mode)    { localStorage.setItem('settl_mode', mode); },
  getRole()        { return this.getProfile()?.role || 'operator'; },
};

window.auth = auth;
