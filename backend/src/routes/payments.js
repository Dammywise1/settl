const router     = require('express').Router();
const { supabase } = require('../config/supabase');
const { createPaymentSession, pollPaymentSession, getSessionByRef } = require('../services/solanaPay');

// ── POST /api/payments/session — create QR + shareable link
router.post('/session', async (req, res, next) => {
  try {
    const { merchant_id, amount, message, memo } = req.body;
    if (!merchant_id) return res.status(400).json({ error: 'merchant_id required' });
    const session = await createPaymentSession({ merchantId: merchant_id, amountAudd: amount || null, message, memo });
    res.json(session);
  } catch (err) { next(err); }
});

// ── GET /api/payments/poll/:ref — PUBLIC — customer + merchant poll this
router.get('/poll/:ref', async (req, res, next) => {
  try {
    const result = await pollPaymentSession(req.params.ref);
    res.json(result);
  } catch (err) { next(err); }
});

// ── GET /api/payments/session/:ref — PUBLIC — checkout page loads info
router.get('/session/:ref', async (req, res, next) => {
  try {
    const session = await getSessionByRef(req.params.ref);
    if (!session) return res.status(404).json({ error: 'Session not found' });
    // Don't expose sensitive merchant details, only what checkout needs
    res.json({
      reference_key:  session.reference_key,
      amount:         session.amount,
      label:          session.label,
      message:        session.message,
      status:         session.status,
      expires_at:     session.expires_at,
      merchant_name:  session.merchants?.name || session.merchant_id,
      vault_address:  session.merchants?.vault_address,
      spl_token:      process.env.AUDD_MINT,
    });
  } catch (err) { next(err); }
});

// ── GET /api/payments/history — merchant's own history (protected by authMiddleware in server.js)
router.get('/history', async (req, res, next) => {
  try {
    const { data: merchant } = await supabase.from('merchants').select('merchant_id').eq('user_id', req.user.id).maybeSingle();
    if (!merchant) return res.json({ transactions: [] });
    const { data, error } = await supabase.from('transactions').select('*')
      .eq('merchant_id', merchant.merchant_id).order('created_at', { ascending: false }).limit(100);
    if (error) throw error;
    res.json({ transactions: data });
  } catch (err) { next(err); }
});

module.exports = router;
