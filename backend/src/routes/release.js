const router     = require('express').Router();
const { supabase } = require('../config/supabase');
const { releaseMerchant, releaseAll } = require('../services/release');

router.post('/all',         async (req, res, next) => { try { res.json(await releaseAll('manual')); } catch(err) { next(err); } });
router.post('/:merchantId', async (req, res, next) => { try { res.json(await releaseMerchant(req.params.merchantId)); } catch(err) { next(err); } });
router.get('/logs',         async (req, res, next) => {
  try {
    const { data } = await supabase.from('cron_logs').select('*').order('started_at', { ascending: false }).limit(30);
    res.json({ logs: data || [] });
  } catch(err) { next(err); }
});
router.get('/me', async (req, res, next) => {
  try {
    const { data: merchant } = await supabase.from('merchants').select('merchant_id').eq('user_id', req.user.id).maybeSingle();
    if (!merchant) return res.json({ result: null });
    const result = await releaseMerchant(merchant.merchant_id);
    res.json(result);
  } catch(err) { next(err); }
});
module.exports = router;
