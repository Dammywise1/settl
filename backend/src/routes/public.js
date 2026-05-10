/**
 * Public routes — NO auth middleware, NO rate limit.
 * Mounted at /api/public in server.js.
 *
 * These endpoints are called by:
 *   - The merchant's own paylink page (poll every 2s)
 *   - The customer's checkout page (poll every 2s)
 *   - Anyone with a checkout link (session info)
 *
 * There is intentionally no authentication on these routes.
 * The reference key is a 32-byte random public key that acts
 * as an unguessable identifier — no auth needed.
 */
const router     = require('express').Router();
const { supabase } = require('../config/supabase');

// ── GET /api/public/poll/:ref ─────────────────────────────
// Poll payment status. Called every 2s by frontend.
// Returns: { status: 'pending' | 'confirmed' | 'expired' | 'failed', tx? }
router.get('/poll/:ref', async (req, res) => {
  try {
    const { pollPaymentSession } = require('../services/solanaPay');
    const result = await pollPaymentSession(req.params.ref);
    // Never return an error status code — frontend must keep polling
    res.json(result);
  } catch (err) {
    console.error('[public/poll]', err.message);
    // Return pending so frontend keeps trying
    res.json({ status: 'pending' });
  }
});

// ── GET /api/public/session/:ref ──────────────────────────
// Load payment session info for the checkout page.
// Returns enough info to render the QR and payment details.
router.get('/session/:ref', async (req, res) => {
  try {
    const { getSessionByRef } = require('../services/solanaPay');
    const session = await getSessionByRef(req.params.ref);

    if (!session) {
      return res.status(404).json({ error: 'Payment session not found' });
    }

    // Build Solana Pay URL server-side so checkout doesn't need to reconstruct it
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
      merchant_name:  session.merchants?.name || '',
      vault_address:  session.merchants?.vault_address || '',
      spl_token:      process.env.AUDD_MINT || '',
      solana_pay_url: buildSolanaUrl(session),
    });
  } catch (err) {
    console.error('[public/session]', err.message);
    res.status(500).json({ error: 'Failed to load session' });
  }
});

module.exports = router;
