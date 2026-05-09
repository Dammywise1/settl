const router     = require('express').Router();
const { supabase } = require('../config/supabase');
const { releaseMerchant, releaseAll } = require('../services/release');

router.post('/all',           async (req, res, next) => { try { res.json(await releaseAll('manual'));           } catch (err) { next(err); } });
router.post('/:merchantId',   async (req, res, next) => { try { res.json(await releaseMerchant(req.params.merchantId)); } catch (err) { next(err); } });

router.get('/logs', async (req, res, next) => {
  try {
    const { data, error } = await supabase.from('cron_logs').select('*').order('started_at', { ascending: false }).limit(30);
    if (error) throw error;
    res.json({ logs: data });
  } catch (err) { next(err); }
});

router.get('/merchant-logs/:id', async (req, res, next) => {
  try {
    const { data, error } = await supabase.from('release_logs').select('*').eq('merchant_id', req.params.id).order('released_at', { ascending: false }).limit(50);
    if (error) throw error;
    res.json({ logs: data });
  } catch (err) { next(err); }
});

module.exports = router;
