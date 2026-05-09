const router = require('express').Router();
const { supabase } = require('../config/supabase');

router.get('/', async (req, res) => {
  let db = 'ok';
  try { const { error } = await supabase.from('users').select('count').limit(1); if (error) db = error.message; }
  catch { db = 'unreachable'; }
  res.json({ status: 'ok', env: process.env.NODE_ENV, db, ts: new Date().toISOString() });
});

module.exports = router;
