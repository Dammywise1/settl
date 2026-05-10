const router     = require('express').Router();
const { supabase } = require('../config/supabase');
const { releaseMerchant, releaseAll } = require('../services/release');

// ── POST /api/release/me — release for logged-in merchant ─
router.post('/me', async (req, res, next) => {
  try {
    const { data: merchant } = await supabase
      .from('merchants')
      .select('merchant_id, is_active, vault_address')
      .eq('user_id', req.user.id)
      .maybeSingle();

    if (!merchant) {
      return res.status(404).json({ error: 'No merchant found for your account' });
    }
    if (!merchant.is_active) {
      return res.status(400).json({ error: 'Merchant is not active yet' });
    }
    if (!merchant.vault_address) {
      return res.status(400).json({ error: 'Vault not initialised yet' });
    }

    const result = await releaseMerchant(merchant.merchant_id);
    res.json(result);
  } catch (err) { next(err); }
});

// ── POST /api/release/all — release all active merchants ──
router.post('/all', async (req, res, next) => {
  try {
    const result = await releaseAll('manual');
    res.json(result);
  } catch (err) { next(err); }
});

// ── POST /api/release/:merchantId — release specific merchant
router.post('/:merchantId', async (req, res, next) => {
  try {
    const result = await releaseMerchant(req.params.merchantId);
    res.json(result);
  } catch (err) { next(err); }
});

// ── GET /api/release/logs — cron run history ──────────────
router.get('/logs', async (req, res, next) => {
  try {
    const { data } = await supabase
      .from('cron_logs')
      .select('*')
      .order('started_at', { ascending: false })
      .limit(30);
    res.json({ logs: data || [] });
  } catch (err) { next(err); }
});

// ── GET /api/release/merchant-logs/:id ───────────────────
router.get('/merchant-logs/:id', async (req, res, next) => {
  try {
    const { data } = await supabase
      .from('release_logs')
      .select('*')
      .eq('merchant_id', req.params.id)
      .order('released_at', { ascending: false })
      .limit(50);
    res.json({ logs: data || [] });
  } catch (err) { next(err); }
});

module.exports = router;
