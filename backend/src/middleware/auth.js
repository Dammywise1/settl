const jwt      = require('jsonwebtoken');
const { supabase } = require('../config/supabase');

async function authMiddleware(req, res, next) {
  const header = req.headers.authorization;
  if (!header?.startsWith('Bearer '))
    return res.status(401).json({ error: 'Missing Authorization header' });

  try {
    const payload = jwt.verify(header.split(' ')[1], process.env.JWT_SECRET);
    const { data: user } = await supabase.from('users')
      .select('id, email, full_name, is_active')
      .eq('id', payload.sub).maybeSingle();
    if (!user || !user.is_active) return res.status(401).json({ error: 'Invalid token' });
    req.user = user;
    next();
  } catch {
    return res.status(401).json({ error: 'Invalid or expired token' });
  }
}
module.exports = authMiddleware;
