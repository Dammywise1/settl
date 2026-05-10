const router         = require('express').Router();
const apiKeyMiddleware = require('../middleware/apiKey');
const { createPaymentSession } = require('../services/solanaPay');

// ── POST /api/pay/charge ───────────────────────────────────
// Used by merchants from their own server backend.
// Requires: x-api-key header with a valid sk_live_... key
//
// Body:
//   amount   {number}  — AUDD amount (e.g. 25.00). Optional for open.
//   message  {string}  — order reference shown on checkout. Optional.
//   memo     {string}  — on-chain memo. Optional.
//
// Returns:
//   url          — Solana Pay URL (solana:...)
//   checkout_url — shareable checkout link
//   reference    — unique reference key for polling
//   session_id   — DB session ID
//
// Example:
//   curl -X POST https://your-settl.com/api/pay/charge \
//     -H "x-api-key: sk_live_..." \
//     -H "Content-Type: application/json" \
//     -d '{"amount": 25.00, "message": "Order #1234"}'
router.post('/charge', apiKeyMiddleware, async (req, res, next) => {
  try {
    const { amount, message, memo } = req.body;
    const merchantId = req.merchant.merchant_id;

    function getBaseUrl(req) {
      const proto = req.headers['x-forwarded-proto'] || req.protocol || 'https';
      const host  = req.headers['x-forwarded-host']  || req.headers.host || 'localhost:3000';
      return `${proto}://${host}`;
    }

    const session = await createPaymentSession(
      { merchantId, amountAudd: amount || null, message, memo },
      getBaseUrl(req)
    );

    res.json(session);
  } catch (err) { next(err); }
});

// ── GET /api/pay/status/:ref ───────────────────────────────
// Check payment status programmatically (no auth needed)
router.get('/status/:ref', async (req, res, next) => {
  try {
    const { pollPaymentSession } = require('../services/solanaPay');
    const result = await pollPaymentSession(req.params.ref);
    res.json(result);
  } catch (err) { next(err); }
});

module.exports = router;
