const router     = require('express').Router();
const { supabase } = require('../config/supabase');
const solanaPay  = require('../services/solanaPay');

// ── POST /api/payments/session ────────────────────────────
// Create a Solana Pay session + URL for a payment QR
router.post('/session', async (req, res, next) => {
  try {
    const { merchant_id, amount, label, message, memo } = req.body;
    if (!merchant_id) return res.status(400).json({ error: 'merchant_id required' });
    const session = await solanaPay.createPaymentSession({
      merchantId: merchant_id, amountAudd: amount || null, label, message, memo,
    });
    res.json(session);
  } catch (err) { next(err); }
});

// ── GET /api/payments/poll/:reference ─────────────────────
// Frontend polls this every 250ms to check if payment confirmed
router.get('/poll/:reference', async (req, res, next) => {
  try {
    const result = await solanaPay.pollPaymentSession(req.params.reference);
    res.json(result);
  } catch (err) { next(err); }
});

// ── GET /api/payments/history ─────────────────────────────
router.get('/history', async (req, res, next) => {
  try {
    const limit  = parseInt(req.query.limit  || '50');
    const offset = parseInt(req.query.offset || '0');
    const { data, error, count } = await supabase
      .from('transactions')
      .select('*', { count: 'exact' })
      .order('created_at', { ascending: false })
      .range(offset, offset + limit - 1);
    if (error) throw error;
    res.json({ transactions: data, total: count });
  } catch (err) { next(err); }
});

module.exports = router;
