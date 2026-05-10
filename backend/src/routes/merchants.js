const router     = require('express').Router();
const { supabase } = require('../config/supabase');
const { getProgram, getEscrowPDA } = require('../config/anchor');

// ── GET /api/merchants/me — own merchant record ───────────
router.get('/me', async (req, res, next) => {
  try {
    const { data: merchant } = await supabase
      .from('merchants').select('*, escrows(*)')
      .eq('user_id', req.user.id).maybeSingle();

    if (!merchant) return res.status(404).json({ error: 'No merchant found for this account' });

    // Try to fetch live chain data
    let chainEscrow = null;
    if (merchant.is_active && merchant.merchant_id) {
      try {
        const program     = getProgram();
        const [escrowPDA] = getEscrowPDA(merchant.merchant_id);
        const acc         = await program.account.escrowAccount.fetch(escrowPDA);
        chainEscrow = {
          pendingBalance: acc.pendingBalance.toNumber(),
          totalPayments:  acc.totalPayments.toNumber(),
          lastReleasedAt: acc.lastReleasedAt.toNumber(),
        };
        // Sync to DB
        await supabase.from('escrows').update({
          pending_balance: chainEscrow.pendingBalance / 1_000_000,
          total_payments:  chainEscrow.totalPayments,
        }).eq('merchant_id', merchant.merchant_id);
      } catch { /* chain not reachable, use DB values */ }
    }

    res.json({ merchant, chainEscrow });
  } catch (err) { next(err); }
});

// ── GET /api/merchants/me/sessions — own payment sessions ─
router.get('/me/sessions', async (req, res, next) => {
  try {
    const { data: merchant } = await supabase.from('merchants').select('merchant_id').eq('user_id', req.user.id).maybeSingle();
    if (!merchant) return res.json({ sessions: [] });
    const { data } = await supabase.from('payment_sessions').select('*')
      .eq('merchant_id', merchant.merchant_id).order('created_at', { ascending: false }).limit(50);
    res.json({ sessions: data || [] });
  } catch (err) { next(err); }
});

// ── GET /api/merchants/me/releases — release history ──────
router.get('/me/releases', async (req, res, next) => {
  try {
    const { data: merchant } = await supabase.from('merchants').select('merchant_id').eq('user_id', req.user.id).maybeSingle();
    if (!merchant) return res.json({ logs: [] });
    const { data } = await supabase.from('release_logs').select('*')
      .eq('merchant_id', merchant.merchant_id).order('released_at', { ascending: false }).limit(50);
    res.json({ logs: data || [] });
  } catch (err) { next(err); }
});

module.exports = router;
