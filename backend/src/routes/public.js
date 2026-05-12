const router     = require('express').Router();
const { supabase } = require('../config/supabase');

// ── GET /api/public/poll/:ref ─────────────────────────────
router.get('/poll/:ref', async (req, res) => {
  try {
    const { pollPaymentSession } = require('../services/solanaPay');
    const result = await pollPaymentSession(req.params.ref);
    res.json(result);
  } catch (err) {
    console.error('[public/poll]', err.message);
    res.json({ status: 'pending' });
  }
});

// ── GET /api/public/session/:ref ──────────────────────────
router.get('/session/:ref', async (req, res) => {
  try {
    const { getSessionByRef } = require('../services/solanaPay');
    const session = await getSessionByRef(req.params.ref);
    if (!session) return res.status(404).json({ error: 'Session not found' });

    function buildSolanaUrl(s) {
      if (!s.merchants?.vault_address) return null;
      const p = new URLSearchParams();
      if (process.env.AUDD_MINT) p.set('spl-token', process.env.AUDD_MINT);
      p.set('reference', s.reference_key);
      if (s.label)   p.set('label',   s.label);
      if (s.message) p.set('message', s.message);
      if (s.memo)    p.set('memo',    s.memo);
      if (s.amount)  p.set('amount',  s.amount.toString());
      return `solana:${s.merchants.vault_address}?${p.toString()}`;
    }

    res.json({
      reference_key:  session.reference_key,
      amount:         session.amount,
      label:          session.label,
      message:        session.message,
      status:         session.status,
      tx_signature:   session.tx_signature,
      expires_at:     session.expires_at,
      success_url:    session.success_url || session.merchants?.success_url || null,
      merchant_name:  session.merchants?.brand_name || session.merchants?.name || '',
      brand_logo:     session.merchants?.brand_logo_url || null,
      vault_address:  session.merchants?.vault_address || '',
      spl_token:      process.env.AUDD_MINT || '',
      solana_pay_url: buildSolanaUrl(session),
      // Payment status flags
      is_overpaid:     session.is_overpaid     || false,
      is_underpaid:    session.is_underpaid    || false,
      amount_received: session.amount_received || null,
      overpay_amount:  session.overpay_amount  || null,
      underpay_amount: session.underpay_amount || null,
    });
  } catch (err) {
    res.status(500).json({ error: 'Failed to load session' });
  }
});

// ── POST /api/public/note/:ref ────────────────────────────
// Customer submits a note on the checkout page (no auth needed)
router.post('/note/:ref', async (req, res) => {
  try {
    const { note } = req.body;
    if (!note || note.trim().length === 0) return res.status(400).json({ error: 'Note is empty' });
    if (note.length > 500) return res.status(400).json({ error: 'Note too long (max 500 chars)' });

    const { data: session } = await supabase
      .from('payment_sessions')
      .select('id, status')
      .eq('reference_key', req.params.ref)
      .maybeSingle();

    if (!session) return res.status(404).json({ error: 'Session not found' });
    if (session.status !== 'pending') return res.status(400).json({ error: 'Session is not pending' });

    await supabase.from('payment_sessions')
      .update({ customer_note: note.trim() })
      .eq('reference_key', req.params.ref);

    res.json({ message: 'Note saved' });
  } catch (err) {
    res.status(500).json({ error: 'Failed to save note' });
  }
});

// ── GET /api/public/link/:slug ────────────────────────────
// Load a reusable payment link and create a fresh session
router.get('/link/:slug', async (req, res) => {
  try {
    const { createSessionFromLink } = require('../services/solanaPay');
    const proto = req.headers['x-forwarded-proto'] || req.protocol || 'https';
    const host  = req.headers['x-forwarded-host']  || req.headers.host;
    const baseUrl = `${proto}://${host}`;

    const session = await createSessionFromLink(req.params.slug, baseUrl);
    res.json(session);
  } catch (err) {
    res.status(err.message.includes('not found') ? 404 : 500).json({ error: err.message });
  }
});

module.exports = router;
