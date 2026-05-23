const router     = require('express').Router();
const { supabase } = require('../config/supabase');
const { getVaultTokenBalance } = require('../config/anchor');

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
      const vaultBal = await getVaultTokenBalance(merchant.vault_address);
      liveBalance = vaultBal.uiAmount || 0;

      const dbBalance = parseFloat(merchant.escrows?.[0]?.pending_balance || 0);
      if (Math.abs(liveBalance - dbBalance) > 0.0001) {
        const { count } = await supabase
          .from('payment_sessions')
          .select('id', { count: 'exact', head: true })
          .eq('merchant_id', merchant.merchant_id)
          .eq('status', 'confirmed');

        await supabase
          .from('escrows')
          .update({ pending_balance: liveBalance, total_payments: count || 0 })
          .eq('merchant_id', merchant.merchant_id);

        if (merchant.escrows?.[0]) {
          merchant.escrows[0].pending_balance = liveBalance;
          merchant.escrows[0].total_payments  = count || 0;
        }
        console.log(`[merchants/me] Synced balance: ${liveBalance} AUDD`);
      }
    }

    res.set('Cache-Control', 'no-store');
    res.json({
      merchant,
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

// ── GET /api/merchants/me/transactions ────────────────────
// NOTE: this MUST be before module.exports
router.get('/me/transactions', async (req, res, next) => {
  try {
    const { data: merchant } = await supabase
      .from('merchants').select('merchant_id').eq('user_id', req.user.id).maybeSingle();
    if (!merchant) return res.json({ transactions: [], total: 0 });

    const limit  = Math.min(parseInt(req.query.limit  || '50'), 100);
    const offset = parseInt(req.query.offset || '0');
    const type   = req.query.type;
    const status = req.query.status;

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

    // Enrich deposits with amount_received from payment_sessions
    // For open payments, transactions.amount = session.amount (null→0)
    // but amount_received IS stored on the transaction row already.
    // This handles the display correctly for all cases.
    const refs = (data || [])
      .filter(t => t.type === 'deposit' && !t.amount_received && t.reference_key)
      .map(t => t.reference_key);

    let sessionMap = {};
    if (refs.length > 0) {
      const { data: sessions } = await supabase
        .from('payment_sessions')
        .select('reference_key, amount_received, amount')
        .in('reference_key', refs);

      (sessions || []).forEach(s => {
        sessionMap[s.reference_key] = s.amount_received || s.amount || null;
      });
    }

    const enriched = (data || []).map(tx => {
      if (tx.type === 'deposit' && !tx.amount_received && tx.reference_key && sessionMap[tx.reference_key]) {
        return { ...tx, amount_received: sessionMap[tx.reference_key] };
      }
      return tx;
    });

    res.set('Cache-Control', 'no-store');
    res.json({ transactions: enriched, total: count || 0, limit, offset });
  } catch (err) { next(err); }
});

// ── PATCH /api/merchants/me/branding ─────────────────────
router.patch('/me/branding', async (req, res, next) => {
  try {
    const { brand_name, brand_logo_url, success_url, support_email } = req.body;
    const { data: merchant } = await supabase
      .from('merchants').select('merchant_id').eq('user_id', req.user.id).maybeSingle();
    if (!merchant) return res.status(404).json({ error: 'No merchant found' });

    const updates = {};
    if (brand_name     !== undefined) updates.brand_name     = brand_name;
    if (brand_logo_url !== undefined) updates.brand_logo_url = brand_logo_url;
    if (success_url    !== undefined) updates.success_url    = success_url;
    if (support_email  !== undefined) updates.support_email  = support_email;

    const { data } = await supabase.from('merchants')
      .update(updates).eq('merchant_id', merchant.merchant_id).select().single();
    res.json({ merchant: data });
  } catch (err) { next(err); }
});

// module.exports MUST be last — after all routes are defined
module.exports = router;
