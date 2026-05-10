const cron           = require('node-cron');
const { releaseAll } = require('../services/release');
const { supabase }   = require('../config/supabase');

let releaseJob = null;
let cleanupJob = null;

function startCron() {
  if (releaseJob) return;

  // ── 6am daily release ─────────────────────────────────
  releaseJob = cron.schedule('0 0 6 * * *', async () => {
    console.log('[cron] 6am release starting...');
    try {
      const r = await releaseAll('cron');
      console.log('[cron] Release done:', r.summary);
    } catch (err) {
      console.error('[cron] Release error:', err.message);
    }
  }, { scheduled: true, timezone: 'UTC' });

  // ── Hourly session expiry cleanup ─────────────────────
  cleanupJob = cron.schedule('0 0 * * * *', async () => {
    try {
      const { data, error } = await supabase
        .from('payment_sessions')
        .update({ status: 'expired' })
        .eq('status', 'pending')
        .lt('expires_at', new Date().toISOString())
        .select('id');

      if (!error && data?.length > 0) {
        console.log(`[cron] Expired ${data.length} stale payment session(s)`);
      }
    } catch (err) {
      console.error('[cron] Session cleanup error:', err.message);
    }
  }, { scheduled: true, timezone: 'UTC' });

  console.log('[SETTL] Crons scheduled: 6am release + hourly session cleanup');
}

module.exports = {
  startCron,
  triggerNow: () => releaseAll('manual'),
};
