const router     = require('express').Router();
const { supabase } = require('../config/supabase');
const { v4: uuid } = require('uuid');

async function getMerchantId(userId) {
  const { data } = await supabase.from('merchants').select('merchant_id').eq('user_id', userId).maybeSingle();
  return data?.merchant_id;
}

// Generate a short slug: 8 random alphanumeric chars
function generateSlug() {
  return Math.random().toString(36).slice(2, 10);
}

// ── GET /api/links ────────────────────────────────────────
router.get('/', async (req, res, next) => {
  try {
    const mid = await getMerchantId(req.user.id);
    if (!mid) return res.json({ links: [] });
    const { data } = await supabase.from('payment_links').select('*')
      .eq('merchant_id', mid).order('created_at', { ascending: false });
    res.json({ links: data || [] });
  } catch (err) { next(err); }
});

// ── POST /api/links ───────────────────────────────────────
router.post('/', async (req, res, next) => {
  try {
    const mid = await getMerchantId(req.user.id);
    if (!mid) return res.status(404).json({ error: 'No merchant found' });

    const {
      title, description, amount, is_reusable,
      expiry_minutes, success_url,
    } = req.body;

    if (!title) return res.status(400).json({ error: 'title is required' });

    // Generate a unique slug
    let slug = generateSlug();
    let attempts = 0;
    while (attempts < 5) {
      const { data: existing } = await supabase
        .from('payment_links').select('id').eq('slug', slug).maybeSingle();
      if (!existing) break;
      slug = generateSlug();
      attempts++;
    }

    const { data, error } = await supabase.from('payment_links').insert({
      merchant_id:    mid,
      slug,
      title:          title.trim(),
      description:    description || null,
      amount:         amount      || null,
      is_reusable:    is_reusable !== false, // default true
      expiry_minutes: is_reusable ? null : (expiry_minutes || 30),
      success_url:    success_url || null,
    }).select().single();

    if (error) throw error;

    const proto   = req.headers['x-forwarded-proto'] || req.protocol || 'https';
    const host    = req.headers['x-forwarded-host']  || req.headers.host;
    const baseUrl = `${proto}://${host}`;

    res.status(201).json({
      link:      data,
      share_url: `${baseUrl}/pay/${slug}`,
    });
  } catch (err) { next(err); }
});

// ── PATCH /api/links/:id ──────────────────────────────────
router.patch('/:id', async (req, res, next) => {
  try {
    const mid = await getMerchantId(req.user.id);
    const { title, description, amount, is_active, success_url, expiry_minutes } = req.body;
    const updates = {};
    if (title         !== undefined) updates.title          = title;
    if (description   !== undefined) updates.description    = description;
    if (amount        !== undefined) updates.amount         = amount;
    if (is_active     !== undefined) updates.is_active      = is_active;
    if (success_url   !== undefined) updates.success_url    = success_url;
    if (expiry_minutes!== undefined) updates.expiry_minutes = expiry_minutes;

    const { data, error } = await supabase.from('payment_links')
      .update(updates).eq('id', req.params.id).eq('merchant_id', mid).select().single();
    if (error) throw error;
    res.json({ link: data });
  } catch (err) { next(err); }
});

// ── DELETE /api/links/:id ─────────────────────────────────
router.delete('/:id', async (req, res, next) => {
  try {
    const mid = await getMerchantId(req.user.id);
    await supabase.from('payment_links').delete().eq('id', req.params.id).eq('merchant_id', mid);
    res.json({ message: 'Link deleted' });
  } catch (err) { next(err); }
});

// ── GET /api/links/:id/sessions ───────────────────────────
router.get('/:id/sessions', async (req, res, next) => {
  try {
    const mid = await getMerchantId(req.user.id);
    const { data } = await supabase.from('payment_sessions').select('*')
      .eq('payment_link_id', req.params.id)
      .order('created_at', { ascending: false }).limit(50);
    res.json({ sessions: data || [] });
  } catch (err) { next(err); }
});

module.exports = router;
