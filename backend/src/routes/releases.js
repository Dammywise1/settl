require('../config/env');
const router         = require('express').Router();
const { supabase }   = require('../config/supabase');
const releaseService = require('../services/release');
const cronJob        = require('../cron/dailyRelease');

// ── GET /api/releases  ────────────────────────────────────
// Release history from DB (all or by merchant)
router.get('/', async (req, res, next) => {
  try {
    const { merchant_id, status, limit = 50, offset = 0 } = req.query;

    let query = supabase
      .from('release_logs')
      .select('*', { count: 'exact' })
      .order('released_at', { ascending: false })
      .range(Number(offset), Number(offset) + Number(limit) - 1);

    if (merchant_id) query = query.eq('merchant_id', merchant_id);
    if (status)      query = query.eq('status', status);

    const { data, error, count } = await query;
    if (error) throw error;

    res.json({ releases: data, total: count, limit: Number(limit), offset: Number(offset) });
  } catch (err) { next(err); }
});

// ── GET /api/releases/cron-status  ────────────────────────
router.get('/cron-status', (req, res) => {
  res.json(cronJob.getStatus());
});

// ── GET /api/releases/cron-runs  ──────────────────────────
// Historical cron run log from DB
router.get('/cron-runs', async (req, res, next) => {
  try {
    const { data, error } = await supabase
      .from('cron_runs')
      .select('*')
      .order('ran_at', { ascending: false })
      .limit(50);

    if (error) throw error;
    res.json({ runs: data });
  } catch (err) { next(err); }
});

// ── POST /api/releases/trigger  ───────────────────────────
// Manual release trigger — runs the full cron loop immediately
router.post('/trigger', async (req, res, next) => {
  try {
    const { merchant_id } = req.body;

    let result;
    if (merchant_id) {
      // Release a single merchant
      result = await releaseService.releaseMerchant(merchant_id);
    } else {
      // Release all active merchants
      result = await cronJob.runNow();
    }

    res.json({ message: 'Release triggered', result });
  } catch (err) { next(err); }
});

module.exports = router;
