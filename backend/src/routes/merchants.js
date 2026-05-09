const router          = require('express').Router();
const { supabase }    = require('../config/supabase');
const merchantService = require('../services/merchant');
const contract        = require('../services/contract');

router.get('/', async (req, res, next) => {
  try {
    const { data, error } = await supabase
      .from('merchants')
      .select('*, escrows(pending_balance, total_payments, last_released_at, vault_address)')
      .order('created_at', { ascending: false });
    if (error) throw error;
    res.json({ merchants: data });
  } catch (err) { next(err); }
});

router.get('/:id', async (req, res, next) => {
  try {
    const { data, error } = await supabase
      .from('merchants').select('*, escrows(*)').eq('merchant_id', req.params.id).single();
    if (error || !data) return res.status(404).json({ error: 'Merchant not found' });
    const [onChain, escrowChain] = await Promise.all([
      contract.fetchMerchantOnChain(req.params.id),
      contract.fetchEscrowOnChain(req.params.id),
    ]);
    res.json({ merchant: data, onChain, escrowChain });
  } catch (err) { next(err); }
});

router.post('/', async (req, res, next) => {
  try {
    const { merchant_id, wallet_address, name, email } = req.body;
    if (!merchant_id || !wallet_address) {
      return res.status(400).json({ error: 'merchant_id and wallet_address are required' });
    }
    const result = await merchantService.createMerchant({
      merchantId: merchant_id, walletAddress: wallet_address,
      name, email, createdBy: req.user.id,
    });
    res.status(201).json(result);
  } catch (err) { next(err); }
});

router.get('/:id/chain', async (req, res, next) => {
  try {
    const [merchant, escrow] = await Promise.all([
      contract.fetchMerchantOnChain(req.params.id),
      contract.fetchEscrowOnChain(req.params.id),
    ]);
    if (!merchant) return res.status(404).json({ error: 'Not found on-chain' });
    res.json({ merchant, escrow });
  } catch (err) { next(err); }
});

router.post('/:id/deactivate', async (req, res, next) => {
  try {
    const tx = await contract.deactivateMerchant(req.params.id);
    await supabase.from('merchants').update({ is_active: false }).eq('merchant_id', req.params.id);
    res.json({ message: 'Deactivated', tx });
  } catch (err) { next(err); }
});

router.post('/:id/wallet-update/request', async (req, res, next) => {
  try {
    const { new_wallet } = req.body;
    if (!new_wallet) return res.status(400).json({ error: 'new_wallet required' });
    const tx = await contract.requestWalletUpdate(req.params.id, new_wallet);
    const unlockAt = new Date(Date.now() + 86_400_000).toISOString();
    await supabase.from('wallet_update_requests').upsert({
      merchant_id: req.params.id, new_wallet, tx_signature: tx,
      unlocks_at: unlockAt, status: 'pending',
    }, { onConflict: 'merchant_id' });
    res.json({ message: 'Staged — confirm after 24h', tx, unlockAt });
  } catch (err) { next(err); }
});

router.post('/:id/wallet-update/confirm', async (req, res, next) => {
  try {
    const tx = await contract.confirmWalletUpdate(req.params.id);
    const chainState = await contract.fetchMerchantOnChain(req.params.id);
    if (chainState) {
      await supabase.from('merchants').update({ wallet_address: chainState.wallet }).eq('merchant_id', req.params.id);
    }
    await supabase.from('wallet_update_requests').update({ status: 'confirmed', confirmed_at: new Date().toISOString() }).eq('merchant_id', req.params.id);
    res.json({ message: 'Wallet updated', tx });
  } catch (err) { next(err); }
});

module.exports = router;
