const { supabase } = require('../config/supabase');

// Admin middleware — must be used AFTER authMiddleware
// authMiddleware sets req.user, this checks is_admin flag
async function adminMiddleware(req, res, next) {
  if (!req.user) {
    return res.status(401).json({ error: 'Authentication required' });
  }

  // Re-fetch from DB to get is_admin (not stored in JWT)
  const { data: user } = await supabase
    .from('users')
    .select('id, email, is_admin')
    .eq('id', req.user.id)
    .maybeSingle();

  if (!user?.is_admin) {
    return res.status(403).json({ error: 'Admin access required' });
  }

  req.admin = user;
  next();
}

// Log every admin action for audit trail
async function logAdminAction(adminUser, action, targetId, details) {
  try {
    await supabase.from('admin_logs').insert({
      admin_id:    adminUser.id,
      admin_email: adminUser.email,
      action,
      target_id:   targetId || null,
      details:     details  || null,
    });
  } catch (e) {
    console.warn('[admin] Failed to log action:', e.message);
  }
}

module.exports = { adminMiddleware, logAdminAction };
