const router     = require('express').Router();
const { supabase } = require('../config/supabase');
const contract   = require('../services/contract');

router.get('/:merchantId', async (req, res, next) => {
  try {
    const { merchantId } = req.params;
    const [db, chain] = await Promise.all([
      supabase.from('escrows').select('*').eq('merchant_id', merchantId).single().then(r => r.data),
      contract.fetchEscrowOnChain(merchantId),
    ]);
    if (!db && !chain) return res.status(404).json({ error: 'Escrow not found' });
    res.json({
      merchantId,
      pendingBalance:  chain?.pendingBalance  ?? db?.pending_balance  ?? 0,
      totalPayments:   chain?.totalPayments   ?? db?.total_payments   ?? 0,
      lastReleasedAt:  chain?.lastReleasedAt  ? new Date(chain.lastReleasedAt * 1000).toISOString() : db?.last_released_at,
      merchantWallet:  chain?.merchantWallet  ?? null,
      vaultAddress:    db?.vault_address      ?? null,
      source:          chain ? 'chain' : 'db',
    });
  } catch (err) { next(err); }
});

router.get('/:merchantId/history', async (req, res, next) => {
  try {
    const { data, error, count } = await supabase
      .from('transactions')
      .select('*', { count: 'exact' })
      .eq('merchant_id', req.params.merchantId)
      .order('created_at', { ascending: false })
      .range(0, 49);
    if (error) throw error;
    res.json({ transactions: data, total: count });
  } catch (err) { next(err); }
});

module.exports = router;
