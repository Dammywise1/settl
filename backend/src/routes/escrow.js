const router       = require('express').Router();
const { supabase } = require('../config/supabase');
const contract     = require('../services/contract');

// ── GET /api/escrow/:merchantId ───────────────────────────
// Returns DB + live chain balance merged
router.get('/:merchantId', async (req, res, next) => {
  try {
    const { merchantId } = req.params;

    const [dbEscrow, chainEscrow] = await Promise.all([
      supabase
        .from('escrows')
        .select('*')
        .eq('merchant_id', merchantId)
        .single()
        .then(r => r.data),
      contract.fetchEscrowOnChain(merchantId),
    ]);

    if (!dbEscrow && !chainEscrow) {
      return res.status(404).json({ error: 'Escrow not found' });
    }

    // Prefer live chain data for balance, fall back to DB
    res.json({
      merchantId,
      pendingBalance:  chainEscrow?.pendingBalance  ?? dbEscrow?.pending_balance  ?? 0,
      totalPayments:   chainEscrow?.totalPayments   ?? dbEscrow?.total_payments   ?? 0,
      lastReleasedAt:  chainEscrow?.lastReleasedAt  ? new Date(chainEscrow.lastReleasedAt * 1000).toISOString() : dbEscrow?.last_released_at,
      merchantWallet:  chainEscrow?.merchantWallet  ?? null,
      vaultAddress:    dbEscrow?.vault_address      ?? null,
      source:          chainEscrow ? 'chain' : 'db',
    });
  } catch (err) { next(err); }
});

// ── GET /api/escrow/:merchantId/history ──────────────────
// Transaction history for an escrow from DB
router.get('/:merchantId/history', async (req, res, next) => {
  try {
    const { merchantId } = req.params;
    const limit  = parseInt(req.query.limit  || '50');
    const offset = parseInt(req.query.offset || '0');

    const { data, error, count } = await supabase
      .from('transactions')
      .select('*', { count: 'exact' })
      .eq('merchant_id', merchantId)
      .order('created_at', { ascending: false })
      .range(offset, offset + limit - 1);

    if (error) throw error;
    res.json({ transactions: data, total: count, limit, offset });
  } catch (err) { next(err); }
});

module.exports = router;
