const router   = require('express').Router();
const { supabase } = require('../config/supabase');

router.get('/', async (req, res) => {
  let db = 'ok';
  try {
    const { error } = await supabase.from('merchants').select('count').limit(1);
    if (error) db = 'error: ' + error.message;
  } catch (e) {
    db = 'unreachable';
  }

  res.json({
    status: 'ok',
    timestamp: new Date().toISOString(),
    env: process.env.NODE_ENV,
    db,
  });
});

module.exports = router;
