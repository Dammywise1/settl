const { PublicKey, SystemProgram, SYSVAR_RENT_PUBKEY } = require('@solana/web3.js');
const { TOKEN_PROGRAM_ID }  = require('@solana/spl-token');
const { supabase }          = require('../config/supabase');
const {
  getProgram, getKeypair,
  getMerchantPDA, getEscrowPDA, getVaultPDA,
} = require('../config/anchor');

const AUDD_MINT = () => new PublicKey(process.env.AUDD_MINT);

// Lenient base58 Solana address validation
function isValidSolanaAddress(addr) {
  try {
    if (!addr || typeof addr !== 'string') return false;
    if (addr.length < 32 || addr.length > 44) return false;
    new PublicKey(addr.trim());
    return true;
  } catch { return false; }
}

// ── registerMerchantForUser ───────────────────────────────
// Called in background after signup.
// 1. register_merchant on-chain
// 2. initialize_merchant_escrow on-chain
// 3. Update DB with PDAs + mark active
async function registerMerchantForUser({ userId, merchantId, walletAddress }) {
  console.log(`[merchant] Registering ${merchantId} on-chain...`);

  // Mark as processing
  await supabase.from('merchants').update({ registration_status: 'processing' })
    .eq('merchant_id', merchantId);

  try {
    const program       = getProgram();
    const authority     = getKeypair();
    const walletPubkey  = new PublicKey(walletAddress.trim());

    const [merchantPDA] = getMerchantPDA(merchantId);
    const [escrowPDA]   = getEscrowPDA(merchantId);
    const [vaultPDA]    = getVaultPDA(merchantId);

    // ── Step 1: register_merchant ─────────────────────────
    const registerTx = await program.methods
      .registerMerchant(merchantId, walletPubkey)
      .accounts({
        merchant:      merchantPDA,
        authority:     authority.publicKey,
        systemProgram: SystemProgram.programId,
      })
      .signers([authority])
      .rpc();
    console.log(`[merchant] register_merchant tx: ${registerTx}`);

    // ── Step 2: initialize_merchant_escrow ────────────────
    const escrowTx = await program.methods
      .initializeMerchantEscrow(merchantId)
      .accounts({
        merchant:      merchantPDA,
        escrow:        escrowPDA,
        vault:         vaultPDA,
        auddMint:      AUDD_MINT(),
        authority:     authority.publicKey,
        tokenProgram:  TOKEN_PROGRAM_ID,
        systemProgram: SystemProgram.programId,
        rent:          SYSVAR_RENT_PUBKEY,
      })
      .signers([authority])
      .rpc();
    console.log(`[merchant] initialize_merchant_escrow tx: ${escrowTx}`);

    // vaultPDA is the actual AUDD token account — used in Solana Pay URL
    const vaultBase58 = vaultPDA.toBase58();

    // ── Step 3: Update DB ─────────────────────────────────
    await supabase.from('merchants').update({
      is_active:           true,
      registered_at:       new Date().toISOString(),
      on_chain_tx:         registerTx,
      escrow_tx:           escrowTx,
      merchant_pda:        merchantPDA.toBase58(),
      escrow_pda:          escrowPDA.toBase58(),
      vault_address:       vaultBase58,
      registration_status: 'active',
      registration_error:  null,
    }).eq('merchant_id', merchantId);

    // ── Step 4: Create escrow record ──────────────────────
    await supabase.from('escrows').upsert({
      merchant_id:     merchantId,
      pending_balance: 0,
      total_payments:  0,
      vault_address:   vaultBase58,
    }, { onConflict: 'merchant_id' });

    console.log(`[merchant] ${merchantId} fully registered. Vault: ${vaultBase58}`);
    return { registerTx, escrowTx, vaultPDA: vaultBase58 };

  } catch (err) {
    console.error(`[merchant] Registration failed for ${merchantId}:`, err.message);
    await supabase.from('merchants').update({
      registration_status: 'failed',
      registration_error:  err.message,
    }).eq('merchant_id', merchantId);
    throw err;
  }
}

module.exports = { registerMerchantForUser, isValidSolanaAddress };
