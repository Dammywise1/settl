require('../config/env');
const cron                      = require('node-cron');
const { releaseAllMerchants }   = require('../services/release');
const { supabase }              = require('../config/supabase');

// Default: 6am every day. Override via RELEASE_CRON in .env
const SCHEDULE = process.env.RELEASE_CRON || '0 6 * * *';

let lastRunAt     = null;
let lastRunStatus = 'never';
let lastRunResult = null;
let isRunning     = false;

async function runRelease() {
  if (isRunning) {
    console.warn('[cron] Release already running — skipping this tick');
    return;
  }

  isRunning     = true;
  lastRunAt     = new Date().toISOString();
  lastRunStatus = 'running';

  try {
    const results = await releaseAllMerchants();
    lastRunStatus = 'success';
    lastRunResult = results;

    // Record cron run in Supabase for the UI
    await supabase.from('cron_runs').insert({
      ran_at:    lastRunAt,
      status:    'success',
      success:   results?.success  ?? 0,
      skipped:   results?.skipped  ?? 0,
      failed:    results?.failed   ?? 0,
    });
  } catch (err) {
    console.error('[cron] Release run failed:', err.message);
    lastRunStatus = 'failed';
    lastRunResult = { error: err.message };

    await supabase.from('cron_runs').insert({
      ran_at:  lastRunAt,
      status:  'failed',
      error:   err.message,
    }).catch(() => {});
  } finally {
    isRunning = false;
  }
}

// Schedule
cron.schedule(SCHEDULE, runRelease, { timezone: 'Australia/Sydney' });
console.log(`[cron] Daily release scheduled: "${SCHEDULE}" (Australia/Sydney)`);

// Export status for the /api/releases/cron-status endpoint
module.exports = {
  getStatus: () => ({ schedule: SCHEDULE, lastRunAt, lastRunStatus, lastRunResult, isRunning }),
  runNow:    runRelease,
};
