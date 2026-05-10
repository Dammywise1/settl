const router   = require('express').Router();
const { supabase } = require('../config/supabase');
const { generateKey, listKeys, revokeKey } = require('../services/apiKey');

async function getMerchantId(userId) {
  const { data } = await supabase.from('merchants').select('merchant_id').eq('user_id', userId).maybeSingle();
  return data?.merchant_id;
}

// ── GET /api/apikeys ──────────────────────────────────────
router.get('/', async (req, res, next) => {
  try {
    const mid = await getMerchantId(req.user.id);
    if (!mid) return res.json({ keys: [] });
    const keys = await listKeys(mid);
    res.json({ keys });
  } catch (err) { next(err); }
});

// ── POST /api/apikeys ─────────────────────────────────────
router.post('/', async (req, res, next) => {
  try {
    const mid = await getMerchantId(req.user.id);
    if (!mid) return res.status(404).json({ error: 'No merchant found' });

    const { name } = req.body;
    if (!name) return res.status(400).json({ error: 'name is required' });

    // Max 5 active keys per merchant
    const existing = await listKeys(mid);
    const active   = existing.filter(k => k.is_active);
    if (active.length >= 5) {
      return res.status(400).json({ error: 'Maximum 5 active API keys per merchant. Revoke one first.' });
    }

    const result = await generateKey(mid, name);
    res.status(201).json(result);
  } catch (err) { next(err); }
});

// ── DELETE /api/apikeys/:id ───────────────────────────────
router.delete('/:id', async (req, res, next) => {
  try {
    const mid = await getMerchantId(req.user.id);
    if (!mid) return res.status(404).json({ error: 'No merchant found' });
    await revokeKey(req.params.id, mid);
    res.json({ message: 'API key revoked' });
  } catch (err) { next(err); }
});

module.exports = router;
