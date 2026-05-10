const auth = {
  getToken()  { return localStorage.getItem('settl_token'); },
  getUser()   { try { return JSON.parse(localStorage.getItem('settl_user')); } catch { return null; } },
  getMerchant(){ try { return JSON.parse(localStorage.getItem('settl_merchant')); } catch { return null; } },

  save(token, user, merchant) {
    localStorage.setItem('settl_token',    token);
    localStorage.setItem('settl_user',     JSON.stringify(user));
    if (merchant) localStorage.setItem('settl_merchant', JSON.stringify(merchant));
  },

  updateMerchant(merchant) {
    localStorage.setItem('settl_merchant', JSON.stringify(merchant));
  },

  clear() {
    ['settl_token','settl_user','settl_merchant'].forEach(k => localStorage.removeItem(k));
  },

  isLoggedIn() { return !!this.getToken(); },

  requireAuth() {
    if (!this.isLoggedIn()) { window.location.href = '/pages/auth/login.html'; return false; }
    return true;
  },
};
window.auth = auth;
