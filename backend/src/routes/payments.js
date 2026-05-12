const router     = require('express').Router();
const { supabase } = require('../config/supabase');
const { createPaymentSession } = require('../services/solanaPay');

function getBaseUrl(req) {
  const proto = req.headers['x-forwarded-proto'] || req.protocol || 'https';
  const host  = req.headers['x-forwarded-host']  || req.headers.host || 'localhost:3000';
  return `${proto}://${host}`;
}

// ── POST /api/payments/session ────────────────────────────
router.post('/session', async (req, res, next) => {
  try {
    const { merchant_id, amount, message, memo, expiry_minutes, success_url } = req.body;
    if (!merchant_id) return res.status(400).json({ error: 'merchant_id required' });

    const session = await createPaymentSession({
      merchantId:    merchant_id,
      amountAudd:    amount        || null,
      message,
      memo,
      expiryMinutes: expiry_minutes !== undefined ? expiry_minutes : 30,
      successUrl:    success_url   || null,
    }, getBaseUrl(req));

    res.json(session);
  } catch (err) { next(err); }
});

// ── GET /api/payments/history ─────────────────────────────
router.get('/history', async (req, res, next) => {
  try {
    const { data: merchant } = await supabase
      .from('merchants').select('merchant_id').eq('user_id', req.user.id).maybeSingle();
    if (!merchant) return res.json({ transactions: [] });
    const { data } = await supabase.from('transactions').select('*')
      .eq('merchant_id', merchant.merchant_id)
      .order('created_at', { ascending: false }).limit(100);
    res.json({ transactions: data || [] });
  } catch (err) { next(err); }
});

module.exports = router;
