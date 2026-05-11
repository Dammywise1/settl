const router     = require('express').Router();
const { supabase } = require('../config/supabase');
const { getVaultTokenBalance, getEscrowOnChain } = require('../config/anchor');

// ── GET /api/merchants/me ─────────────────────────────────
router.get('/me', async (req, res, next) => {
  try {
    const { data: merchant, error } = await supabase
      .from('merchants')
      .select('*, escrows(*)')
      .eq('user_id', req.user.id)
      .maybeSingle();

    if (error || !merchant) {
      return res.status(404).json({ error: 'No merchant found for this account' });
    }

    let liveBalance = null;

    if (merchant.is_active && merchant.vault_address) {
      // Read live vault token account balance
      // This is the real AUDD held in the vault PDA
      const vaultBal = await getVaultTokenBalance(merchant.vault_address);
      liveBalance = vaultBal.uiAmount || 0;

      // If live balance differs from DB, sync it
      const dbBalance = parseFloat(merchant.escrows?.[0]?.pending_balance || 0);
      if (Math.abs(liveBalance - dbBalance) > 0.0001) {
        // Count confirmed payments
        const { count } = await supabase
          .from('payment_sessions')
          .select('id', { count: 'exact', head: true })
          .eq('merchant_id', merchant.merchant_id)
          .eq('status', 'confirmed');

        await supabase
          .from('escrows')
          .update({ pending_balance: liveBalance, total_payments: count || 0 })
          .eq('merchant_id', merchant.merchant_id);

        // Update the escrow object in memory for the response
        if (merchant.escrows?.[0]) {
          merchant.escrows[0].pending_balance = liveBalance;
          merchant.escrows[0].total_payments  = count || 0;
        }
        console.log(`[merchants/me] Synced balance: ${liveBalance} AUDD`);
      }
    }

    // No-cache headers so dashboard always gets fresh data
    res.set('Cache-Control', 'no-store');

    res.json({
      merchant,
      // pendingBalance in AUDD — use live if available, fall back to DB
      pendingBalance: liveBalance ?? parseFloat(merchant.escrows?.[0]?.pending_balance || 0),
      totalPayments:  merchant.escrows?.[0]?.total_payments || 0,
      lastReleasedAt: merchant.escrows?.[0]?.last_released_at || null,
    });
  } catch (err) { next(err); }
});

// ── GET /api/merchants/me/sessions ────────────────────────
router.get('/me/sessions', async (req, res, next) => {
  try {
    const { data: merchant } = await supabase
      .from('merchants')
      .select('merchant_id')
      .eq('user_id', req.user.id)
      .maybeSingle();

    if (!merchant) return res.json({ sessions: [] });

    const { data } = await supabase
      .from('payment_sessions')
      .select('*')
      .eq('merchant_id', merchant.merchant_id)
      .order('created_at', { ascending: false })
      .limit(50);

    res.set('Cache-Control', 'no-store');
    res.json({ sessions: data || [] });
  } catch (err) { next(err); }
});

// ── GET /api/merchants/me/releases ────────────────────────
router.get('/me/releases', async (req, res, next) => {
  try {
    const { data: merchant } = await supabase
      .from('merchants')
      .select('merchant_id')
      .eq('user_id', req.user.id)
      .maybeSingle();

    if (!merchant) return res.json({ logs: [] });

    const { data } = await supabase
      .from('release_logs')
      .select('*')
      .eq('merchant_id', merchant.merchant_id)
      .order('released_at', { ascending: false })
      .limit(50);

    res.set('Cache-Control', 'no-store');
    res.json({ logs: data || [] });
  } catch (err) { next(err); }
});

module.exports = router;

// ── GET /api/merchants/me/transactions ────────────────────
router.get('/me/transactions', async (req, res, next) => {
  try {
    const { data: merchant } = await supabase
      .from('merchants').select('merchant_id').eq('user_id', req.user.id).maybeSingle();
    if (!merchant) return res.json({ transactions: [], total: 0 });

    const limit  = Math.min(parseInt(req.query.limit  || '50'), 100);
    const offset = parseInt(req.query.offset || '0');
    const type   = req.query.type;   // 'deposit' | 'release' | 'fee'
    const status = req.query.status; // 'confirmed' | 'pending' | 'failed'

    let query = supabase
      .from('transactions')
      .select('*', { count: 'exact' })
      .eq('merchant_id', merchant.merchant_id)
      .order('created_at', { ascending: false })
      .range(offset, offset + limit - 1);

    if (type)   query = query.eq('type',   type);
    if (status) query = query.eq('status', status);

    const { data, error, count } = await query;
    if (error) throw error;

    res.set('Cache-Control', 'no-store');
    res.json({ transactions: data || [], total: count || 0, limit, offset });
  } catch (err) { next(err); }
});

// ── GET /api/merchants/me/transactions ────────────────────
router.get('/me/transactions', async (req, res, next) => {
  try {
    const { data: merchant } = await supabase
      .from('merchants').select('merchant_id').eq('user_id', req.user.id).maybeSingle();
    if (!merchant) return res.json({ transactions: [], total: 0 });

    const limit  = Math.min(parseInt(req.query.limit  || '50'), 100);
    const offset = parseInt(req.query.offset || '0');
    const type   = req.query.type;   // 'deposit' | 'release' | 'fee'
    const status = req.query.status; // 'confirmed' | 'pending' | 'failed'

    let query = supabase
      .from('transactions')
      .select('*', { count: 'exact' })
      .eq('merchant_id', merchant.merchant_id)
      .order('created_at', { ascending: false })
      .range(offset, offset + limit - 1);

    if (type)   query = query.eq('type',   type);
    if (status) query = query.eq('status', status);

    const { data, error, count } = await query;
    if (error) throw error;

    res.set('Cache-Control', 'no-store');
    res.json({ transactions: data || [], total: count || 0, limit, offset });
  } catch (err) { next(err); }
});
