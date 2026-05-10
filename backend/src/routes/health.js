const router = require('express').Router();
const { supabase } = require('../config/supabase');

router.get('/', async (req, res) => {
  let db = 'ok';
  try {
    const { error } = await supabase.from('users').select('count').limit(1);
    if (error) db = error.message;
  } catch { db = 'unreachable'; }

  res.json({
    status: 'ok',
    db,
    ts: new Date().toISOString(),
    // Public config for frontend Realtime (anon key is safe to expose)
    config: {
      supabase_url:      process.env.SUPABASE_URL || '',
      supabase_anon_key: process.env.SUPABASE_ANON_KEY || '',
    },
  });
});

module.exports = router;
