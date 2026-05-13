require('dotenv').config({ path: require('path').resolve(__dirname, '../../../.env') });
const { Connection, Keypair, PublicKey } = require('@solana/web3.js');
const { AnchorProvider, Program }        = require('@coral-xyz/anchor');
const fs   = require('fs');
const path = require('path');

const IDL        = require('../idl/settl.json');
const PROGRAM_ID = new PublicKey(
  process.env.SETTL_PROGRAM_ID || 'RZgHzaU8jKm4ydzwkmoooqd2TNek4L9W4o8tthekeLn'
);

let _provider   = null;
let _program    = null;
let _keypair    = null;
let _connection = null;

// ── getKeypair ────────────────────────────────────────────
// Supports two sources (in priority order):
//   1. AUTHORITY_KEYPAIR_BASE64 env var (production/Railway)
//      base64-encoded JSON array of the secret key bytes
//      Generate: base64 -w 0 keypair.json
//   2. AUTHORITY_KEYPAIR_PATH file (local development)
//      Path to keypair.json on disk
function getKeypair() {
  if (_keypair) return _keypair;

  // Option 1: base64 env var (Railway / production)
  if (process.env.AUTHORITY_KEYPAIR_BASE64) {
    try {
      const decoded = Buffer.from(process.env.AUTHORITY_KEYPAIR_BASE64, 'base64').toString('utf-8');
      const raw     = JSON.parse(decoded);
      _keypair      = Keypair.fromSecretKey(Uint8Array.from(raw));
      console.log('[anchor] Keypair loaded from AUTHORITY_KEYPAIR_BASE64');
      return _keypair;
    } catch (err) {
      throw new Error('AUTHORITY_KEYPAIR_BASE64 is set but could not be decoded: ' + err.message);
    }
  }

  // Option 2: file path (local development)
  const kpPath = path.resolve(process.env.AUTHORITY_KEYPAIR_PATH || './keypair.json');
  if (!fs.existsSync(kpPath)) {
    throw new Error(
      `Authority keypair not found.\n` +
      `  For local dev: set AUTHORITY_KEYPAIR_PATH in .env\n` +
      `  For Railway:   set AUTHORITY_KEYPAIR_BASE64 in Railway Variables\n` +
      `  Generate keypair: solana-keygen new -o keypair.json`
    );
  }

  try {
    const raw = JSON.parse(fs.readFileSync(kpPath, 'utf-8'));
    _keypair  = Keypair.fromSecretKey(Uint8Array.from(raw));
    console.log(`[anchor] Keypair loaded from file: ${kpPath}`);
    return _keypair;
  } catch (err) {
    throw new Error(`Failed to load keypair from ${kpPath}: ` + err.message);
  }
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
async function getVaultTokenBalance(vaultAddress) {
  try {
    const balance = await getConnection().getTokenAccountBalance(
      new PublicKey(vaultAddress), 'confirmed'
    );
    return {
      amount:   balance.value.amount,
      uiAmount: balance.value.uiAmount || 0,
      decimals: balance.value.decimals,
    };
  } catch (err) {
    console.warn('[anchor] getVaultTokenBalance failed:', err.message);
    return { amount: '0', uiAmount: 0, decimals: 6 };
  }
}

module.exports = {
  getProvider, getProgram, getKeypair, getConnection,
  getMerchantPDA, getEscrowPDA, getVaultPDA, getConfigPDA,
  getVaultTokenBalance,
  PROGRAM_ID,
};
