require('../config/env');
const { Connection, Keypair, PublicKey } = require('@solana/web3.js');
const { AnchorProvider, Program, BN }   = require('@coral-xyz/anchor');
const fs   = require('fs');
const path = require('path');

const IDL         = require('../idl/settl.json');
const PROGRAM_ID  = new PublicKey(process.env.SETTL_PROGRAM_ID || 'RZgHzaU8jKm4ydzwkmoooqd2TNek4L9W4o8tthekeLn');

let _provider = null;
let _program  = null;
let _keypair  = null;

function getKeypair() {
  if (_keypair) return _keypair;
  const kpPath = path.resolve(process.env.AUTHORITY_KEYPAIR_PATH || './keypair.json');
  if (!fs.existsSync(kpPath)) {
    throw new Error(`Authority keypair not found at: ${kpPath}\nCreate one with: solana-keygen new -o keypair.json`);
  }
  const raw = JSON.parse(fs.readFileSync(kpPath, 'utf-8'));
  _keypair  = Keypair.fromSecretKey(Uint8Array.from(raw));
  return _keypair;
}

function getProvider() {
  if (_provider) return _provider;
  const rpcUrl     = process.env.SOLANA_RPC_URL || 'https://api.devnet.solana.com';
  const connection = new Connection(rpcUrl, 'confirmed');
  const kp         = getKeypair();

  const wallet = {
    publicKey: kp.publicKey,
    signTransaction:     async (tx)  => { tx.sign(kp); return tx; },
    signAllTransactions: async (txs) => txs.map(tx => { tx.sign(kp); return tx; }),
  };

  _provider = new AnchorProvider(connection, wallet, {
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

// ── PDA helpers (mirrors the contract seeds) ──────────────
function getMerchantPDA(merchantId) {
  return PublicKey.findProgramAddressSync(
    [Buffer.from('merchant'), Buffer.from(merchantId)],
    PROGRAM_ID
  );
}

function getEscrowPDA(merchantId) {
  return PublicKey.findProgramAddressSync(
    [Buffer.from('escrow'), Buffer.from(merchantId)],
    PROGRAM_ID
  );
}

function getVaultPDA(merchantId) {
  return PublicKey.findProgramAddressSync(
    [Buffer.from('vault'), Buffer.from(merchantId)],
    PROGRAM_ID
  );
}

function getConfigPDA() {
  return PublicKey.findProgramAddressSync(
    [Buffer.from('config')],
    PROGRAM_ID
  );
}

module.exports = {
  getProvider,
  getProgram,
  getKeypair,
  getMerchantPDA,
  getEscrowPDA,
  getVaultPDA,
  getConfigPDA,
  PROGRAM_ID,
  BN,
};
