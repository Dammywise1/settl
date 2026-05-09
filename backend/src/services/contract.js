const { PublicKey, SystemProgram, SYSVAR_RENT_PUBKEY } = require('@solana/web3.js');
const { TOKEN_PROGRAM_ID, getAssociatedTokenAddress }  = require('@solana/spl-token');
const { getProgram, getKeypair, getMerchantPDA, getEscrowPDA, getVaultPDA, getConfigPDA } = require('../config/anchor');

const AUDD_MINT = () => new PublicKey(process.env.AUDD_MINT);
const TREASURY  = () => new PublicKey(process.env.TREASURY_WALLET);

async function registerMerchant(merchantId, walletAddress) {
  const program       = getProgram();
  const authority     = getKeypair();
  const walletPubkey  = new PublicKey(walletAddress);
  const [merchantPDA] = getMerchantPDA(merchantId);

  const tx = await program.methods
    .registerMerchant(merchantId, walletPubkey)
    .accounts({ merchant: merchantPDA, authority: authority.publicKey, systemProgram: SystemProgram.programId })
    .signers([authority]).rpc();

  return { tx, merchantPDA: merchantPDA.toBase58() };
}

async function initializeMerchantEscrow(merchantId) {
  const program       = getProgram();
  const authority     = getKeypair();
  const [merchantPDA] = getMerchantPDA(merchantId);
  const [escrowPDA]   = getEscrowPDA(merchantId);
  const [vaultPDA]    = getVaultPDA(merchantId);

  const tx = await program.methods
    .initializeMerchantEscrow(merchantId)
    .accounts({
      merchant: merchantPDA, escrow: escrowPDA, vault: vaultPDA,
      auddMint: AUDD_MINT(), authority: authority.publicKey,
      tokenProgram: TOKEN_PROGRAM_ID, systemProgram: SystemProgram.programId,
      rent: SYSVAR_RENT_PUBKEY,
    })
    .signers([authority]).rpc();

  return { tx, escrowPDA: escrowPDA.toBase58(), vaultPDA: vaultPDA.toBase58() };
}

async function fetchMerchantOnChain(merchantId) {
  const program = getProgram();
  const [pda]   = getMerchantPDA(merchantId);
  try {
    const a = await program.account.merchantAccount.fetch(pda);
    return {
      wallet: a.wallet.toBase58(), isActive: a.isActive,
      registeredAt: a.registeredAt.toNumber(),
      totalReleased: a.totalReleased.toNumber(),
      totalFeesPaid: a.totalFeesPaid.toNumber(),
      pendingWallet: a.pendingWallet?.toBase58() || null,
      walletUpdateAt: a.walletUpdateAt?.toNumber() || null,
    };
  } catch { return null; }
}

async function fetchEscrowOnChain(merchantId) {
  const program = getProgram();
  const [pda]   = getEscrowPDA(merchantId);
  try {
    const a = await program.account.escrowAccount.fetch(pda);
    return {
      merchantWallet: a.merchantWallet.toBase58(),
      pendingBalance: a.pendingBalance.toNumber(),
      totalPayments: a.totalPayments.toNumber(),
      lastReleasedAt: a.lastReleasedAt.toNumber(),
    };
  } catch { return null; }
}

async function releaseMerchant(merchantId) {
  const program   = getProgram();
  const authority = getKeypair();
  const auddMint  = AUDD_MINT();
  const treasury  = TREASURY();

  const [configPDA]   = getConfigPDA();
  const [merchantPDA] = getMerchantPDA(merchantId);
  const [escrowPDA]   = getEscrowPDA(merchantId);
  const [vaultPDA]    = getVaultPDA(merchantId);

  const m = await program.account.merchantAccount.fetch(merchantPDA);
  const merchantATA = await getAssociatedTokenAddress(auddMint, m.wallet);
  const treasuryATA = await getAssociatedTokenAddress(auddMint, treasury);

  const tx = await program.methods
    .release(merchantId)
    .accounts({
      config: configPDA, merchant: merchantPDA, escrow: escrowPDA,
      vault: vaultPDA, merchantAta: merchantATA, treasuryAta: treasuryATA,
      authority: authority.publicKey, tokenProgram: TOKEN_PROGRAM_ID,
    })
    .signers([authority]).rpc();

  return tx;
}

async function deactivateMerchant(merchantId) {
  const program   = getProgram();
  const authority = getKeypair();
  const [pda]     = getMerchantPDA(merchantId);
  const tx = await program.methods.deactivateMerchant()
    .accounts({ merchant: pda, authority: authority.publicKey })
    .signers([authority]).rpc();
  return tx;
}

async function requestWalletUpdate(merchantId, newWallet) {
  const program   = getProgram();
  const authority = getKeypair();
  const [pda]     = getMerchantPDA(merchantId);
  const tx = await program.methods.requestWalletUpdate(new PublicKey(newWallet))
    .accounts({ merchant: pda, authority: authority.publicKey })
    .signers([authority]).rpc();
  return tx;
}

async function confirmWalletUpdate(merchantId) {
  const program   = getProgram();
  const authority = getKeypair();
  const [pda]     = getMerchantPDA(merchantId);
  const tx = await program.methods.confirmWalletUpdate()
    .accounts({ merchant: pda, authority: authority.publicKey })
    .signers([authority]).rpc();
  return tx;
}

module.exports = {
  registerMerchant, initializeMerchantEscrow,
  fetchMerchantOnChain, fetchEscrowOnChain,
  releaseMerchant, deactivateMerchant,
  requestWalletUpdate, confirmWalletUpdate,
  AUDD_MINT, TREASURY,
};
