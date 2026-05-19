const router   = require('express').Router();
const { supabase } = require('../config/supabase');
const { logAdminAction } = require('../middleware/admin');
const {
  getProgram, getKeypair,
  getMerchantPDA, getConfigPDA,
} = require('../config/anchor');
const { PublicKey } = require('@solana/web3.js');

// ═══════════════════════════════════════════════════════════
// OVERVIEW — platform-wide stats
// ═══════════════════════════════════════════════════════════

// ── GET /api/admin/overview ───────────────────────────────
router.get('/overview', async (req, res, next) => {
  try {
    // All counts in parallel
    const [
      { count: totalMerchants },
      { count: activeMerchants },
      { count: totalUsers },
      { count: totalSessions },
      { count: confirmedSessions },
      { data: volumeData },
      { data: feeData },
      { data: recentSessions },
    ] = await Promise.all([
      supabase.from('merchants').select('*', { count: 'exact', head: true }),
      supabase.from('merchants').select('*', { count: 'exact', head: true }).eq('is_active', true),
      supabase.from('users').select('*', { count: 'exact', head: true }),
      supabase.from('payment_sessions').select('*', { count: 'exact', head: true }),
      supabase.from('payment_sessions').select('*', { count: 'exact', head: true }).eq('status', 'confirmed'),
      // Total AUDD volume from confirmed deposits
      supabase.from('transactions')
        .select('amount')
        .eq('type', 'deposit')
        .eq('status', 'confirmed'),
      // Total fees collected
      supabase.from('transactions')
        .select('amount')
        .eq('type', 'fee')
        .eq('status', 'confirmed'),
      // Recent 5 confirmed sessions
      supabase.from('payment_sessions')
        .select('*, merchants(name, merchant_id)')
        .eq('status', 'confirmed')
        .order('confirmed_at', { ascending: false })
        .limit(5),
    ]);

    const totalVolume = (volumeData || []).reduce((s, t) => s + Number(t.amount || 0), 0);
    const totalFees   = (feeData   || []).reduce((s, t) => s + Number(t.amount || 0), 0);

    // Conversion rate
    const conversionRate = totalSessions > 0
      ? ((confirmedSessions / totalSessions) * 100).toFixed(1)
      : '0.0';

    res.json({
      merchants: {
        total:  totalMerchants  || 0,
        active: activeMerchants || 0,
      },
      users: {
        total: totalUsers || 0,
      },
      payments: {
        total_sessions:     totalSessions     || 0,
        confirmed_sessions: confirmedSessions || 0,
        conversion_rate:    parseFloat(conversionRate),
      },
      financials: {
        total_volume_audd: parseFloat(totalVolume.toFixed(6)),
        total_fees_audd:   parseFloat(totalFees.toFixed(6)),
      },
      recent_payments: recentSessions || [],
    });
  } catch (err) { next(err); }
});

// ═══════════════════════════════════════════════════════════
// MERCHANTS — view and manage all merchants
// ═══════════════════════════════════════════════════════════

// ── GET /api/admin/merchants ──────────────────────────────
router.get('/merchants', async (req, res, next) => {
  try {
    const limit  = Math.min(parseInt(req.query.limit  || '50'), 100);
    const offset = parseInt(req.query.offset || '0');
    const search = req.query.search || '';
    const status = req.query.status || ''; // 'active' | 'inactive' | ''

    let query = supabase
      .from('merchants')
      .select(`
        *,
        users!merchants_user_id_fkey(email, full_name),
        escrows(pending_balance, total_payments, last_released_at)
      `, { count: 'exact' })
      .order('created_at', { ascending: false })
      .range(offset, offset + limit - 1);

    if (search) {
      query = query.or(`merchant_id.ilike.%${search}%,name.ilike.%${search}%,email.ilike.%${search}%`);
    }
    if (status === 'active')   query = query.eq('is_active', true);
    if (status === 'inactive') query = query.eq('is_active', false);

    const { data, error, count } = await query;
    if (error) throw error;

    res.json({ merchants: data || [], total: count || 0, limit, offset });
  } catch (err) { next(err); }
});

// ── GET /api/admin/merchants/:id ──────────────────────────
// Full merchant detail for support view
router.get('/merchants/:id', async (req, res, next) => {
  try {
    const { data: merchant, error } = await supabase
      .from('merchants')
      .select(`
        *,
        users!merchants_user_id_fkey(email, full_name, created_at),
        escrows(*),
        merchant_branding(*)
      `)
      .eq('merchant_id', req.params.id)
      .maybeSingle();

    if (error || !merchant) {
      return res.status(404).json({ error: 'Merchant not found' });
    }

    // Recent sessions
    const { data: sessions } = await supabase
      .from('payment_sessions')
      .select('*')
      .eq('merchant_id', req.params.id)
      .order('created_at', { ascending: false })
      .limit(10);

    // Recent releases
    const { data: releases } = await supabase
      .from('release_logs')
      .select('*')
      .eq('merchant_id', req.params.id)
      .order('released_at', { ascending: false })
      .limit(10);

    // Volume stats
    const { data: txData } = await supabase
      .from('transactions')
      .select('type, amount')
      .eq('merchant_id', req.params.id)
      .eq('status', 'confirmed');

    const deposits = (txData || []).filter(t => t.type === 'deposit');
    const releases_ = (txData || []).filter(t => t.type === 'release');
    const fees      = (txData || []).filter(t => t.type === 'fee');

    const stats = {
      total_deposited: deposits.reduce((s, t)  => s + Number(t.amount || 0), 0),
      total_released:  releases_.reduce((s, t) => s + Number(t.amount || 0), 0),
      total_fees_paid: fees.reduce((s, t)      => s + Number(t.amount || 0), 0),
      deposit_count:   deposits.length,
    };

    await logAdminAction(req.admin, 'view_merchant', req.params.id, null);

    res.json({ merchant, sessions: sessions || [], releases: releases || [], stats });
  } catch (err) { next(err); }
});

// ── POST /api/admin/merchants/:id/deactivate ──────────────
// Deactivate merchant on-chain + in DB
router.post('/merchants/:id/deactivate', async (req, res, next) => {
  try {
    const merchantId = req.params.id;
    const { reason } = req.body;

    // Verify merchant exists
    const { data: merchant } = await supabase
      .from('merchants')
      .select('merchant_id, name, is_active')
      .eq('merchant_id', merchantId)
      .maybeSingle();

    if (!merchant) return res.status(404).json({ error: 'Merchant not found' });
    if (!merchant.is_active) return res.status(400).json({ error: 'Merchant is already inactive' });

    // Call on-chain deactivate_merchant instruction
    const program   = getProgram();
    const authority = getKeypair();
    const [merchantPDA] = getMerchantPDA(merchantId);

    const tx = await program.methods
      .deactivateMerchant()
      .accounts({ merchant: merchantPDA, authority: authority.publicKey })
      .signers([authority])
      .rpc();

    // Update DB
    await supabase.from('merchants')
      .update({ is_active: false })
      .eq('merchant_id', merchantId);

    await logAdminAction(req.admin, 'deactivate_merchant', merchantId, {
      reason: reason || null,
      tx,
      merchant_name: merchant.name,
    });

    res.json({
      message: `Merchant ${merchantId} deactivated on-chain`,
      tx,
    });
  } catch (err) { next(err); }
});

// ── POST /api/admin/merchants/:id/reactivate ─────────────
// Reactivate a merchant in DB only (contract has no reactivate)
// To fully reactivate on-chain requires re-registration
router.post('/merchants/:id/reactivate', async (req, res, next) => {
  try {
    const merchantId = req.params.id;

    await supabase.from('merchants')
      .update({ is_active: true })
      .eq('merchant_id', merchantId);

    await logAdminAction(req.admin, 'reactivate_merchant', merchantId, null);

    res.json({ message: `Merchant ${merchantId} reactivated in DB` });
  } catch (err) { next(err); }
});

// ═══════════════════════════════════════════════════════════
// FEE MANAGEMENT
// ═══════════════════════════════════════════════════════════

// ── GET /api/admin/fee ────────────────────────────────────
// Read current fee from on-chain config
router.get('/fee', async (req, res, next) => {
  try {
    const program     = getProgram();
    const [configPDA] = getConfigPDA();

    try {
      const config = await program.account.settlConfig.fetch(configPDA);
      res.json({
        fee_basis_points:     config.feeBasisPoints,
        fee_percent:          (config.feeBasisPoints / 100).toFixed(2),
        total_fees_collected: config.totalFeesCollected.toNumber() / 1_000_000,
        treasury_wallet:      config.treasuryWallet.toBase58(),
        authority:            config.authority.toBase58(),
      });
    } catch {
      // Config not initialized yet — return defaults
      res.json({
        fee_basis_points:     150,
        fee_percent:          '1.50',
        total_fees_collected: 0,
        treasury_wallet:      process.env.TREASURY_WALLET || null,
        note:                 'Config PDA not found on-chain — initialize_config may not have been called',
      });
    }
  } catch (err) { next(err); }
});

// ── POST /api/admin/fee ───────────────────────────────────
// Update fee basis points via update_fee instruction
// Max 1000 basis points (10%)
router.post('/fee', async (req, res, next) => {
  try {
    const { fee_basis_points } = req.body;

    if (fee_basis_points === undefined || fee_basis_points === null) {
      return res.status(400).json({ error: 'fee_basis_points is required' });
    }
    if (fee_basis_points < 0 || fee_basis_points > 1000) {
      return res.status(400).json({ error: 'fee_basis_points must be between 0 and 1000 (0%–10%)' });
    }

    const program     = getProgram();
    const authority   = getKeypair();
    const [configPDA] = getConfigPDA();

    // update_fee instruction — ManageConfig context
    // Requires a new_treasury account even when not changing it
    const config = await program.account.settlConfig.fetch(configPDA);

    const tx = await program.methods
      .updateFee(fee_basis_points)
      .accounts({
        config:      configPDA,
        newTreasury: config.treasuryWallet, // keep current treasury
        authority:   authority.publicKey,
      })
      .signers([authority])
      .rpc();

    const oldFee = config.feeBasisPoints;
    const newFee = fee_basis_points;

    await logAdminAction(req.admin, 'update_fee', null, {
      old_fee_bps: oldFee,
      new_fee_bps: newFee,
      old_percent: (oldFee / 100).toFixed(2) + '%',
      new_percent: (newFee / 100).toFixed(2) + '%',
      tx,
    });

    res.json({
      message:             'Fee updated on-chain',
      old_fee_basis_points: oldFee,
      new_fee_basis_points: newFee,
      new_fee_percent:      (newFee / 100).toFixed(2) + '%',
      tx,
    });
  } catch (err) { next(err); }
});

// ═══════════════════════════════════════════════════════════
// TREASURY MANAGEMENT
// ═══════════════════════════════════════════════════════════

// ── POST /api/admin/treasury ──────────────────────────────
// Update treasury wallet via update_treasury instruction
router.post('/treasury', async (req, res, next) => {
  try {
    const { new_treasury_wallet } = req.body;
    if (!new_treasury_wallet) {
      return res.status(400).json({ error: 'new_treasury_wallet is required' });
    }

    let newTreasuryPubkey;
    try {
      newTreasuryPubkey = new PublicKey(new_treasury_wallet);
    } catch {
      return res.status(400).json({ error: 'Invalid Solana wallet address' });
    }

    const program     = getProgram();
    const authority   = getKeypair();
    const [configPDA] = getConfigPDA();

    const tx = await program.methods
      .updateTreasury()
      .accounts({
        config:      configPDA,
        newTreasury: newTreasuryPubkey,
        authority:   authority.publicKey,
      })
      .signers([authority])
      .rpc();

    const config = await program.account.settlConfig.fetch(configPDA);

    await logAdminAction(req.admin, 'update_treasury', null, {
      new_treasury: new_treasury_wallet,
      tx,
    });

    res.json({
      message:         'Treasury wallet updated on-chain',
      new_treasury:    config.treasuryWallet.toBase58(),
      tx,
    });
  } catch (err) { next(err); }
});

// ═══════════════════════════════════════════════════════════
// ANALYTICS
// ═══════════════════════════════════════════════════════════

// ── GET /api/admin/analytics/volume ──────────────────────
// AUDD volume by day for the last N days
router.get('/analytics/volume', async (req, res, next) => {
  try {
    const days = Math.min(parseInt(req.query.days || '30'), 90);

    const since = new Date();
    since.setDate(since.getDate() - days);

    const { data: transactions } = await supabase
      .from('transactions')
      .select('amount, created_at, type')
      .eq('status', 'confirmed')
      .gte('created_at', since.toISOString())
      .order('created_at', { ascending: true });

    // Group by day
    const byDay = {};
    (transactions || []).forEach(tx => {
      const day = tx.created_at.slice(0, 10); // YYYY-MM-DD
      if (!byDay[day]) byDay[day] = { date: day, deposits: 0, releases: 0, fees: 0 };
      if (tx.type === 'deposit') byDay[day].deposits += Number(tx.amount || 0);
      if (tx.type === 'release') byDay[day].releases += Number(tx.amount || 0);
      if (tx.type === 'fee')     byDay[day].fees     += Number(tx.amount || 0);
    });

    // Fill in missing days with zeros
    const result = [];
    for (let i = days - 1; i >= 0; i--) {
      const d   = new Date();
      d.setDate(d.getDate() - i);
      const day = d.toISOString().slice(0, 10);
      result.push(byDay[day] || { date: day, deposits: 0, releases: 0, fees: 0 });
    }

    res.json({ days: result, period_days: days });
  } catch (err) { next(err); }
});

// ── GET /api/admin/analytics/top-merchants ────────────────
// Top merchants by AUDD volume
router.get('/analytics/top-merchants', async (req, res, next) => {
  try {
    const limit = Math.min(parseInt(req.query.limit || '10'), 50);

    const { data: merchants } = await supabase
      .from('merchants')
      .select('merchant_id, name, email, is_active, registered_at');

    if (!merchants?.length) return res.json({ merchants: [] });

    // Get volume per merchant
    const { data: txData } = await supabase
      .from('transactions')
      .select('merchant_id, amount, type')
      .eq('status', 'confirmed')
      .eq('type', 'deposit');

    const volumeMap = {};
    (txData || []).forEach(tx => {
      if (!volumeMap[tx.merchant_id]) volumeMap[tx.merchant_id] = 0;
      volumeMap[tx.merchant_id] += Number(tx.amount || 0);
    });

    // Get payment count per merchant
    const { data: countData } = await supabase
      .from('payment_sessions')
      .select('merchant_id')
      .eq('status', 'confirmed');

    const countMap = {};
    (countData || []).forEach(s => {
      countMap[s.merchant_id] = (countMap[s.merchant_id] || 0) + 1;
    });

    const ranked = merchants
      .map(m => ({
        ...m,
        total_volume:   parseFloat((volumeMap[m.merchant_id] || 0).toFixed(4)),
        payment_count:  countMap[m.merchant_id] || 0,
      }))
      .sort((a, b) => b.total_volume - a.total_volume)
      .slice(0, limit);

    res.json({ merchants: ranked });
  } catch (err) { next(err); }
});

// ── GET /api/admin/analytics/conversion ──────────────────
// Payment conversion rates overall and by merchant
router.get('/analytics/conversion', async (req, res, next) => {
  try {
    const { data: sessions } = await supabase
      .from('payment_sessions')
      .select('merchant_id, status');

    const total     = sessions?.length || 0;
    const confirmed = sessions?.filter(s => s.status === 'confirmed').length || 0;
    const expired   = sessions?.filter(s => s.status === 'expired').length   || 0;
    const pending   = sessions?.filter(s => s.status === 'pending').length   || 0;

    // Per merchant
    const merchantMap = {};
    (sessions || []).forEach(s => {
      if (!merchantMap[s.merchant_id]) {
        merchantMap[s.merchant_id] = { total: 0, confirmed: 0 };
      }
      merchantMap[s.merchant_id].total++;
      if (s.status === 'confirmed') merchantMap[s.merchant_id].confirmed++;
    });

    const perMerchant = Object.entries(merchantMap).map(([id, d]) => ({
      merchant_id:     id,
      total:           d.total,
      confirmed:       d.confirmed,
      conversion_rate: d.total > 0 ? parseFloat(((d.confirmed / d.total) * 100).toFixed(1)) : 0,
    })).sort((a, b) => b.confirmed - a.confirmed);

    res.json({
      overall: {
        total,
        confirmed,
        expired,
        pending,
        conversion_rate: total > 0
          ? parseFloat(((confirmed / total) * 100).toFixed(1))
          : 0,
      },
      per_merchant: perMerchant,
    });
  } catch (err) { next(err); }
});

// ── GET /api/admin/releases ───────────────────────────────
// All release logs across all merchants
router.get('/releases', async (req, res, next) => {
  try {
    const limit  = Math.min(parseInt(req.query.limit || '50'), 100);
    const offset = parseInt(req.query.offset || '0');

    const { data, error, count } = await supabase
      .from('release_logs')
      .select('*, merchants(name)', { count: 'exact' })
      .order('released_at', { ascending: false })
      .range(offset, offset + limit - 1);

    if (error) throw error;
    res.json({ releases: data || [], total: count || 0 });
  } catch (err) { next(err); }
});

// ── GET /api/admin/cron-logs ──────────────────────────────
router.get('/cron-logs', async (req, res, next) => {
  try {
    const { data, error } = await supabase
      .from('cron_logs')
      .select('*')
      .order('started_at', { ascending: false })
      .limit(30);
    if (error) throw error;
    res.json({ logs: data || [] });
  } catch (err) { next(err); }
});

// ── GET /api/admin/users ──────────────────────────────────
router.get('/users', async (req, res, next) => {
  try {
    const limit  = Math.min(parseInt(req.query.limit || '50'), 100);
    const offset = parseInt(req.query.offset || '0');

    const { data, error, count } = await supabase
      .from('users')
      .select('id, email, full_name, is_admin, is_active, created_at, merchants(merchant_id, name, is_active)', { count: 'exact' })
      .order('created_at', { ascending: false })
      .range(offset, offset + limit - 1);

    if (error) throw error;
    res.json({ users: data || [], total: count || 0 });
  } catch (err) { next(err); }
});

// ── GET /api/admin/logs ───────────────────────────────────
router.get('/logs', async (req, res, next) => {
  try {
    const { data } = await supabase
      .from('admin_logs')
      .select('*')
      .order('created_at', { ascending: false })
      .limit(50);
    res.json({ logs: data || [] });
  } catch (err) { next(err); }
});

module.exports = router;
