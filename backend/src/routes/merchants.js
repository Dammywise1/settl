const router          = require('express').Router();
const { supabase }    = require('../config/supabase');
const merchantService = require('../services/merchant');
const contract        = require('../services/contract');

// ── GET /api/merchants ────────────────────────────────────
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

// ── GET /api/merchants/:id ────────────────────────────────
router.get('/:id', async (req, res, next) => {
  try {
    const { db, onChain, escrowChain } = await merchantService.getMerchantWithChainState(req.params.id);
    res.json({ merchant: db, onChain, escrowChain });
  } catch (err) { next(err); }
});

// ── POST /api/merchants ───────────────────────────────────
// Full on-chain registration + escrow init
router.post('/', async (req, res, next) => {
  try {
    const { merchant_id, wallet_address, name, email } = req.body;

    if (!merchant_id || !wallet_address) {
      return res.status(400).json({ error: 'merchant_id and wallet_address are required' });
    }
    if (merchant_id.length > 64) {
      return res.status(400).json({ error: 'merchant_id must be 64 characters or fewer' });
    }

    const result = await merchantService.createMerchant({
      merchantId:    merchant_id,
      walletAddress: wallet_address,
      name,
      email,
      createdBy:     req.user.id,
    });

    res.status(201).json({
      merchant:    result.merchant,
      registerTx:  result.registerTx,
      escrowTx:    result.escrowTx,
      vaultPDA:    result.vaultPDA,
    });
  } catch (err) { next(err); }
});

// ── GET /api/merchants/:id/chain ──────────────────────────
// Live on-chain state only (no DB)
router.get('/:id/chain', async (req, res, next) => {
  try {
    const [merchantChain, escrowChain] = await Promise.all([
      contract.fetchMerchantOnChain(req.params.id),
      contract.fetchEscrowOnChain(req.params.id),
    ]);
    if (!merchantChain) return res.status(404).json({ error: 'Merchant not found on-chain' });
    res.json({ merchant: merchantChain, escrow: escrowChain });
  } catch (err) { next(err); }
});

// ── POST /api/merchants/:id/wallet-update/request ─────────
// Stage a wallet change (24h security delay)
router.post('/:id/wallet-update/request', async (req, res, next) => {
  try {
    const { new_wallet } = req.body;
    if (!new_wallet) return res.status(400).json({ error: 'new_wallet is required' });

    const result = await merchantService.requestWalletUpdate(req.params.id, new_wallet);
    const unlockTime = new Date(Date.now() + 86_400_000);

    res.json({
      message:   'Wallet update staged. Confirm after 24 hours.',
      tx:        result.tx,
      unlockAt:  unlockTime.toISOString(),
    });
  } catch (err) { next(err); }
});

// ── POST /api/merchants/:id/wallet-update/confirm ─────────
// Confirm a pending wallet change after 24h
router.post('/:id/wallet-update/confirm', async (req, res, next) => {
  try {
    const result = await merchantService.confirmWalletUpdate(req.params.id);
    res.json({ message: 'Wallet updated successfully', tx: result.tx });
  } catch (err) { next(err); }
});

// ── POST /api/merchants/:id/deactivate ────────────────────
router.post('/:id/deactivate', async (req, res, next) => {
  try {
    const result = await merchantService.deactivateMerchant(req.params.id);
    res.json({ message: 'Merchant deactivated', tx: result.tx });
  } catch (err) { next(err); }
});

// ── POST /api/merchants/:id/sync ──────────────────────────
// Pull latest on-chain state into DB
router.post('/:id/sync', async (req, res, next) => {
  try {
    const onChain = await merchantService.syncMerchantFromChain(req.params.id);
    res.json({ message: 'Synced from chain', onChain });
  } catch (err) { next(err); }
});

module.exports = router;
