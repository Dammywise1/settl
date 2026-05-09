const { PublicKey, SYSVAR_RENT_PUBKEY, SystemProgram } = require('@solana/web3.js');
const { TOKEN_PROGRAM_ID, getAssociatedTokenAddress }  = require('@solana/spl-token');
const {
  getProgram, getKeypair,
  getMerchantPDA, getEscrowPDA, getVaultPDA, getConfigPDA,
  BN,
} = require('../config/anchor');

const AUDD_MINT = () => new PublicKey(process.env.AUDD_MINT);

// ── registerMerchant ──────────────────────────────────────
// Calls the on-chain register_merchant instruction.
// Only the backend authority signs — merchant does nothing.
async function registerMerchant(merchantId, walletAddress) {
  if (merchantId.length > 64) throw new Error('merchant_id must be 64 chars or fewer');

  const program              = getProgram();
  const authority            = getKeypair();
  const walletPubkey         = new PublicKey(walletAddress);
  const [merchantPDA]        = getMerchantPDA(merchantId);

  const tx = await program.methods
    .registerMerchant(merchantId, walletPubkey)
    .accounts({
      merchant:      merchantPDA,
      authority:     authority.publicKey,
      systemProgram: SystemProgram.programId,
    })
    .signers([authority])
    .rpc();

  console.log(`[contract] registerMerchant tx: ${tx}`);
  return { tx, merchantPDA: merchantPDA.toBase58() };
}

// ── initializeMerchantEscrow ──────────────────────────────
// Creates the AUDD vault PDA for a merchant.
// Called immediately after registerMerchant.
async function initializeMerchantEscrow(merchantId) {
  const program       = getProgram();
  const authority     = getKeypair();
  const auddMint      = AUDD_MINT();
  const [merchantPDA] = getMerchantPDA(merchantId);
  const [escrowPDA]   = getEscrowPDA(merchantId);
  const [vaultPDA]    = getVaultPDA(merchantId);

  const tx = await program.methods
    .initializeMerchantEscrow(merchantId)
    .accounts({
      merchant:      merchantPDA,
      escrow:        escrowPDA,
      vault:         vaultPDA,
      auddMint:      auddMint,
      authority:     authority.publicKey,
      tokenProgram:  TOKEN_PROGRAM_ID,
      systemProgram: SystemProgram.programId,
      rent:          SYSVAR_RENT_PUBKEY,
    })
    .signers([authority])
    .rpc();

  console.log(`[contract] initializeMerchantEscrow tx: ${tx}`);
  return { tx, escrowPDA: escrowPDA.toBase58(), vaultPDA: vaultPDA.toBase58() };
}

// ── fetchMerchantOnChain ──────────────────────────────────
// Reads the MerchantAccount from the chain.
async function fetchMerchantOnChain(merchantId) {
  const program       = getProgram();
  const [merchantPDA] = getMerchantPDA(merchantId);
  try {
    const account = await program.account.merchantAccount.fetch(merchantPDA);
    return {
      merchantId:    account.merchantId,
      wallet:        account.wallet.toBase58(),
      isActive:      account.isActive,
      registeredAt:  account.registeredAt.toNumber(),
      totalReleased: account.totalReleased.toNumber(),
      totalFeesPaid: account.totalFeesPaid.toNumber(),
      pendingWallet: account.pendingWallet?.toBase58() || null,
      walletUpdateAt:account.walletUpdateAt?.toNumber() || null,
    };
  } catch (e) {
    return null;
  }
}

// ── fetchEscrowOnChain ────────────────────────────────────
// Reads the EscrowAccount from the chain.
async function fetchEscrowOnChain(merchantId) {
  const program      = getProgram();
  const [escrowPDA]  = getEscrowPDA(merchantId);
  try {
    const account = await program.account.escrowAccount.fetch(escrowPDA);
    return {
      merchantId:     account.merchantId,
      merchantWallet: account.merchantWallet.toBase58(),
      pendingBalance: account.pendingBalance.toNumber(),
      totalPayments:  account.totalPayments.toNumber(),
      lastReleasedAt: account.lastReleasedAt.toNumber(),
    };
  } catch (e) {
    return null;
  }
}

// ── requestWalletUpdate ───────────────────────────────────
// Stages a wallet change with a 24-hour security delay.
async function requestWalletUpdate(merchantId, newWalletAddress) {
  const program       = getProgram();
  const authority     = getKeypair();
  const [merchantPDA] = getMerchantPDA(merchantId);
  const newWallet     = new PublicKey(newWalletAddress);

  const tx = await program.methods
    .requestWalletUpdate(newWallet)
    .accounts({ merchant: merchantPDA, authority: authority.publicKey })
    .signers([authority])
    .rpc();

  console.log(`[contract] requestWalletUpdate tx: ${tx}`);
  return { tx };
}

// ── confirmWalletUpdate ───────────────────────────────────
// Confirms a pending wallet change after 24h delay.
async function confirmWalletUpdate(merchantId) {
  const program       = getProgram();
  const authority     = getKeypair();
  const [merchantPDA] = getMerchantPDA(merchantId);

  const tx = await program.methods
    .confirmWalletUpdate()
    .accounts({ merchant: merchantPDA, authority: authority.publicKey })
    .signers([authority])
    .rpc();

  console.log(`[contract] confirmWalletUpdate tx: ${tx}`);
  return { tx };
}

// ── updateEscrowWallet ────────────────────────────────────
// Syncs the escrow's stored wallet after a confirmed update.
async function updateEscrowWallet(merchantId) {
  const program       = getProgram();
  const authority     = getKeypair();
  const [merchantPDA] = getMerchantPDA(merchantId);
  const [escrowPDA]   = getEscrowPDA(merchantId);

  const tx = await program.methods
    .updateEscrowWallet()
    .accounts({
      merchant:  merchantPDA,
      escrow:    escrowPDA,
      authority: authority.publicKey,
    })
    .signers([authority])
    .rpc();

  console.log(`[contract] updateEscrowWallet tx: ${tx}`);
  return { tx };
}

// ── deactivateMerchant ────────────────────────────────────
async function deactivateMerchant(merchantId) {
  const program       = getProgram();
  const authority     = getKeypair();
  const [merchantPDA] = getMerchantPDA(merchantId);

  const tx = await program.methods
    .deactivateMerchant()
    .accounts({ merchant: merchantPDA, authority: authority.publicKey })
    .signers([authority])
    .rpc();

  console.log(`[contract] deactivateMerchant tx: ${tx}`);
  return { tx };
}

module.exports = {
  registerMerchant,
  initializeMerchantEscrow,
  fetchMerchantOnChain,
  fetchEscrowOnChain,
  requestWalletUpdate,
  confirmWalletUpdate,
  updateEscrowWallet,
  deactivateMerchant,
};
