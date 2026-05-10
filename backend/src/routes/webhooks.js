const router   = require('express').Router();
const crypto   = require('crypto');
const { supabase } = require('../config/supabase');
const { verifySignature } = require('../services/webhook');

// Helper: get merchant_id for the logged-in user
async function getMerchantId(userId) {
  const { data } = await supabase
    .from('merchants').select('merchant_id').eq('user_id', userId).maybeSingle();
  return data?.merchant_id;
}

// ── GET /api/webhooks ─────────────────────────────────────
router.get('/', async (req, res, next) => {
  try {
    const mid = await getMerchantId(req.user.id);
    if (!mid) return res.json({ webhooks: [] });

    const { data } = await supabase
      .from('webhook_configs')
      .select('id, url, description, events, is_active, created_at')
      .eq('merchant_id', mid)
      .order('created_at', { ascending: false });

    res.json({ webhooks: data || [] });
  } catch (err) { next(err); }
});

// ── POST /api/webhooks ────────────────────────────────────
router.post('/', async (req, res, next) => {
  try {
    const mid = await getMerchantId(req.user.id);
    if (!mid) return res.status(404).json({ error: 'No merchant found' });

    const { url, description, events } = req.body;
    if (!url) return res.status(400).json({ error: 'url is required' });

    // Validate URL format
    try { new URL(url); } catch {
      return res.status(400).json({ error: 'Invalid URL format' });
    }

    // Generate a unique signing secret for this webhook
    const secret = crypto.randomBytes(24).toString('hex');

    const validEvents = ['deposit.confirmed', 'release.completed'];
    const chosenEvents = Array.isArray(events)
      ? events.filter(e => validEvents.includes(e))
      : validEvents;

    const { data, error } = await supabase
      .from('webhook_configs')
      .insert({ merchant_id: mid, url, description: description || null, events: chosenEvents, secret })
      .select()
      .single();

    if (error) throw error;

    res.status(201).json({
      webhook: { ...data },
      signing_secret: secret,
      note: 'Save the signing_secret — it will not be shown again. Use it to verify webhook signatures.',
    });
  } catch (err) { next(err); }
});

// ── PATCH /api/webhooks/:id ───────────────────────────────
router.patch('/:id', async (req, res, next) => {
  try {
    const mid = await getMerchantId(req.user.id);
    const { url, description, events, is_active } = req.body;
    const updates = {};
    if (url         !== undefined) updates.url         = url;
    if (description !== undefined) updates.description = description;
    if (events      !== undefined) updates.events      = events;
    if (is_active   !== undefined) updates.is_active   = is_active;

    const { data, error } = await supabase
      .from('webhook_configs')
      .update(updates)
      .eq('id', req.params.id)
      .eq('merchant_id', mid)
      .select()
      .single();

    if (error) throw error;
    res.json({ webhook: data });
  } catch (err) { next(err); }
});

// ── DELETE /api/webhooks/:id ──────────────────────────────
router.delete('/:id', async (req, res, next) => {
  try {
    const mid = await getMerchantId(req.user.id);
    await supabase.from('webhook_configs').delete()
      .eq('id', req.params.id).eq('merchant_id', mid);
    res.json({ message: 'Webhook deleted' });
  } catch (err) { next(err); }
});

// ── GET /api/webhooks/deliveries ──────────────────────────
router.get('/deliveries', async (req, res, next) => {
  try {
    const mid = await getMerchantId(req.user.id);
    if (!mid) return res.json({ deliveries: [] });

    const { data } = await supabase
      .from('webhook_deliveries')
      .select('id, event, status, response_code, attempt, error, delivered_at, created_at, webhook_configs(url)')
      .eq('merchant_id', mid)
      .order('created_at', { ascending: false })
      .limit(50);

    res.json({ deliveries: data || [] });
  } catch (err) { next(err); }
});

// ── POST /api/webhooks/test ───────────────────────────────
// Sends a test event to all active webhooks
router.post('/test', async (req, res, next) => {
  try {
    const mid = await getMerchantId(req.user.id);
    if (!mid) return res.status(404).json({ error: 'No merchant found' });

    const { dispatch } = require('../services/webhook');
    await dispatch(mid, 'deposit.confirmed', {
      test:          true,
      reference_key: 'test-reference',
      amount:        1.00,
      tx_signature:  'test-tx-signature',
      timestamp:     new Date().toISOString(),
    });

    res.json({ message: 'Test event dispatched to all active webhooks' });
  } catch (err) { next(err); }
});

module.exports = router;
