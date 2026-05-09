require('../config/env');
const router         = require('express').Router();
const authMiddleware = require('../middleware/auth');
const paymentService = require('../services/payment');
const { supabase }   = require('../config/supabase');

// ── POST /api/payments/link  (auth required) ──────────────
// Developer/operator generates a payment link for a merchant
router.post('/link', authMiddleware, async (req, res, next) => {
  try {
    const { merchant_id, amount, description, expires_in_hours } = req.body;
    if (!merchant_id) return res.status(400).json({ error: 'merchant_id is required' });

    const result = await paymentService.createPaymentLink({
      merchantId:     merchant_id,
      amount,
      description,
      expiresInHours: expires_in_hours || 24,
    });

    res.status(201).json(result);
  } catch (err) { next(err); }
});

// ── GET /api/payments/link/:token  (public) ───────────────
// Customer (or frontend) reads the payment link details
router.get('/link/:token', async (req, res, next) => {
  try {
    const link = await paymentService.getPaymentLink(req.params.token);
    res.json(link);
  } catch (err) {
    res.status(404).json({ error: err.message });
  }
});

// ── POST /api/payments/confirm  (public) ──────────────────
// Customer's browser calls this after completing the on-chain deposit
router.post('/confirm', async (req, res, next) => {
  try {
    const { token, tx_signature, amount, customer_wallet } = req.body;
    if (!token || !tx_signature || !amount) {
      return res.status(400).json({ error: 'token, tx_signature, and amount are required' });
    }

    const tx = await paymentService.confirmDeposit({
      token,
      txSignature:    tx_signature,
      amount,
      customerWallet: customer_wallet,
    });

    res.json({ message: 'Payment confirmed', transaction: tx });
  } catch (err) { next(err); }
});

// ── GET /api/payments/merchant/:id  (auth required) ───────
// List all payment links for a merchant
router.get('/merchant/:id', authMiddleware, async (req, res, next) => {
  try {
    const limit  = parseInt(req.query.limit  || '50');
    const offset = parseInt(req.query.offset || '0');

    const { data, error, count } = await supabase
      .from('payment_links')
      .select('*', { count: 'exact' })
      .eq('merchant_id', req.params.id)
      .order('created_at', { ascending: false })
      .range(offset, offset + limit - 1);

    if (error) throw error;
    res.json({ links: data, total: count, limit, offset });
  } catch (err) { next(err); }
});

module.exports = router;
