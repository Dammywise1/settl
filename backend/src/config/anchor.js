require('dotenv').config({ path: require('path').resolve(__dirname, '../../../.env') });
const { Connection, Keypair, PublicKey } = require('@solana/web3.js');
const { AnchorProvider, Program }        = require('@coral-xyz/anchor');
const fs   = require('fs');
const path = require('path');

const IDL        = require('../idl/settl.json');
const PROGRAM_ID = new PublicKey(
  process.env.SETTL_PROGRAM_ID || 'RZgHzaU8jKm4ydzwkmoooqd2TNek4L9W4o8tthekeLn'
);

let _provider = null;
let _program  = null;
let _keypair  = null;
let _connection = null;

function getKeypair() {
  if (_keypair) return _keypair;
  const kpPath = path.resolve(process.env.AUTHORITY_KEYPAIR_PATH || './keypair.json');
  if (!fs.existsSync(kpPath)) throw new Error(`Keypair not found: ${kpPath}`);
  _keypair = Keypair.fromSecretKey(
    Uint8Array.from(JSON.parse(fs.readFileSync(kpPath, 'utf-8')))
  );
  return _keypair;
}

function getConnection() {
  if (_connection) return _connection;
  _connection = new Connection(
    process.env.SOLANA_RPC_URL || 'https://api.devnet.solana.com',
    'confirmed'
  );
  return _connection;
}

function getProvider() {
  if (_provider) return _provider;
  const kp = getKeypair();
  const wallet = {
    publicKey:           kp.publicKey,
    signTransaction:     async tx  => { tx.sign(kp); return tx; },
    signAllTransactions: async txs => txs.map(tx => { tx.sign(kp); return tx; }),
  };
  _provider = new AnchorProvider(getConnection(), wallet, {
    commitment:          'confirmed',
    preflightCommitment: 'confirmed',
  });
  return _provider;
}

function getProgram() {
  if (_program) return _program;
  _program = new Program(IDL, PROGRAM_ID, getProvider());
  return _program;
}

// ── PDA helpers ───────────────────────────────────────────
function getMerchantPDA(merchantId) {
  return PublicKey.findProgramAddressSync(
    [Buffer.from('merchant'), Buffer.from(merchantId)], PROGRAM_ID
  );
}
function getEscrowPDA(merchantId) {
  return PublicKey.findProgramAddressSync(
    [Buffer.from('escrow'), Buffer.from(merchantId)], PROGRAM_ID
  );
}
function getVaultPDA(merchantId) {
  return PublicKey.findProgramAddressSync(
    [Buffer.from('vault'), Buffer.from(merchantId)], PROGRAM_ID
  );
}
function getConfigPDA() {
  return PublicKey.findProgramAddressSync(
    [Buffer.from('config')], PROGRAM_ID
  );
}

// ── getVaultTokenBalance ──────────────────────────────────
// Reads the actual AUDD balance from the vault token account.
// This is the source of truth for pending balance because
// Solana Pay sends tokens directly to vault — the deposit()
// instruction is NOT called, so escrow.pendingBalance stays
// 0 on-chain. The token account balance is real.
async function getVaultTokenBalance(vaultAddress) {
  try {
    const connection = getConnection();
    const vaultPubkey = new PublicKey(vaultAddress);
    const balance = await connection.getTokenAccountBalance(vaultPubkey, 'confirmed');
    return {
      amount:    balance.value.amount,          // raw integer string
      uiAmount:  balance.value.uiAmount || 0,   // decimal AUDD
      decimals:  balance.value.decimals,
    };
  } catch (err) {
    console.warn('[anchor] getVaultTokenBalance failed:', err.message);
    return { amount: '0', uiAmount: 0, decimals: 6 };
  }
}

// ── getEscrowOnChain ──────────────────────────────────────
// Reads the EscrowAccount PDA (contract state).
// Note: pendingBalance here only reflects deposit() calls,
// not direct token transfers via Solana Pay.
async function getEscrowOnChain(merchantId) {
  try {
    const program     = getProgram();
    const [escrowPDA] = getEscrowPDA(merchantId);
    const acc         = await program.account.escrowAccount.fetch(escrowPDA);
    return {
      pendingBalance: acc.pendingBalance.toNumber(),
      totalPayments:  acc.totalPayments.toNumber(),
      lastReleasedAt: acc.lastReleasedAt.toNumber(),
      merchantWallet: acc.merchantWallet.toBase58(),
    };
  } catch (err) {
    console.warn('[anchor] getEscrowOnChain failed:', err.message);
    return null;
  }
}

module.exports = {
  getProvider,
  getProgram,
  getKeypair,
  getConnection,
  getMerchantPDA,
  getEscrowPDA,
  getVaultPDA,
  getConfigPDA,
  getVaultTokenBalance,
  getEscrowOnChain,
  PROGRAM_ID,
};
