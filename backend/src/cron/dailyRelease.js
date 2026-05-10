const cron           = require('node-cron');
const { releaseAll } = require('../services/release');
let job = null;
function startCron() {
  if (job) return;
  job = cron.schedule('0 0 6 * * *', async () => {
    console.log('[cron] 6am release...');
    try { const r = await releaseAll('cron'); console.log('[cron]', r.summary); }
    catch(e) { console.error('[cron]', e.message); }
  }, { scheduled: true, timezone: 'UTC' });
  console.log('[SETTL] 6am cron scheduled');
}
module.exports = { startCron, triggerNow: () => releaseAll('manual') };
