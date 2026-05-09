#!/usr/bin/env bash
set -e

# ═══════════════════════════════════════════════════════════
#  SETTL — Phase 2 Setup Script
#  Contract integration: Anchor SDK, merchant registration,
#  escrow init, wallet update flow, escrow state viewer
#
#  Run from the repo root (where settl/ folder lives):
#  bash settl-phase2-setup.sh
#
#  Requires Phase 1 to be complete first.
# ═══════════════════════════════════════════════════════════

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()   { echo -e "${GREEN}[SETTL P2]${NC} $1"; }
info()  { echo -e "${BLUE}[INFO]${NC}     $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}     $1"; }
error() { echo -e "${RED}[ERROR]${NC}    $1"; }

# ── Guard: must run from repo root ────────────────────────


log "Phase 2 starting inside settl/..."

# ═══════════════════════════════════════════════════════════
# BACKEND — new directories
# ═══════════════════════════════════════════════════════════
mkdir -p backend/src/services
mkdir -p backend/src/idl
mkdir -p supabase/migrations

# ═══════════════════════════════════════════════════════════
# 1. SETTL IDL  (Anchor Interface Definition Language)
#    Derived from the contract's lib.rs — accounts + ix args
# ═══════════════════════════════════════════════════════════
log "Writing SETTL IDL..."
cat > backend/src/idl/settl.json << 'EOF'
{
  "version": "0.1.0",
  "name": "settl",
  "instructions": [
    {
      "name": "initializeConfig",
      "accounts": [
        { "name": "config",          "isMut": true,  "isSigner": false },
        { "name": "treasuryWallet",  "isMut": false, "isSigner": false },
        { "name": "authority",       "isMut": true,  "isSigner": true  },
        { "name": "systemProgram",   "isMut": false, "isSigner": false }
      ],
      "args": [{ "name": "feeBasisPoints", "type": "u16" }]
    },
    {
      "name": "registerMerchant",
      "accounts": [
        { "name": "merchant",      "isMut": true,  "isSigner": false },
        { "name": "authority",     "isMut": true,  "isSigner": true  },
        { "name": "systemProgram", "isMut": false, "isSigner": false }
      ],
      "args": [
        { "name": "merchantId",     "type": "string" },
        { "name": "walletAddress",  "type": "publicKey" }
      ]
    },
    {
      "name": "initializeMerchantEscrow",
      "accounts": [
        { "name": "merchant",      "isMut": false, "isSigner": false },
        { "name": "escrow",        "isMut": true,  "isSigner": false },
        { "name": "vault",         "isMut": true,  "isSigner": false },
        { "name": "auddMint",      "isMut": false, "isSigner": false },
        { "name": "authority",     "isMut": true,  "isSigner": true  },
        { "name": "tokenProgram",  "isMut": false, "isSigner": false },
        { "name": "systemProgram", "isMut": false, "isSigner": false },
        { "name": "rent",          "isMut": false, "isSigner": false }
      ],
      "args": [{ "name": "merchantId", "type": "string" }]
    },
    {
      "name": "requestWalletUpdate",
      "accounts": [
        { "name": "merchant",  "isMut": true, "isSigner": false },
        { "name": "authority", "isMut": false, "isSigner": true  }
      ],
      "args": [{ "name": "newWallet", "type": "publicKey" }]
    },
    {
      "name": "confirmWalletUpdate",
      "accounts": [
        { "name": "merchant",  "isMut": true, "isSigner": false },
        { "name": "authority", "isMut": false, "isSigner": true  }
      ],
      "args": []
    },
    {
      "name": "deactivateMerchant",
      "accounts": [
        { "name": "merchant",  "isMut": true, "isSigner": false },
        { "name": "authority", "isMut": false, "isSigner": true  }
      ],
      "args": []
    },
    {
      "name": "updateEscrowWallet",
      "accounts": [
        { "name": "merchant",  "isMut": false, "isSigner": false },
        { "name": "escrow",    "isMut": true,  "isSigner": false },
        { "name": "authority", "isMut": false, "isSigner": true  }
      ],
      "args": []
    },
    {
      "name": "deposit",
      "accounts": [
        { "name": "merchant",     "isMut": false, "isSigner": false },
        { "name": "escrow",       "isMut": true,  "isSigner": false },
        { "name": "vault",        "isMut": true,  "isSigner": false },
        { "name": "customerAta",  "isMut": true,  "isSigner": false },
        { "name": "customer",     "isMut": true,  "isSigner": true  },
        { "name": "tokenProgram", "isMut": false, "isSigner": false }
      ],
      "args": [
        { "name": "merchantId", "type": "string" },
        { "name": "amount",     "type": "u64"    }
      ]
    },
    {
      "name": "release",
      "accounts": [
        { "name": "config",       "isMut": true,  "isSigner": false },
        { "name": "merchant",     "isMut": true,  "isSigner": false },
        { "name": "escrow",       "isMut": true,  "isSigner": false },
        { "name": "vault",        "isMut": true,  "isSigner": false },
        { "name": "merchantAta",  "isMut": true,  "isSigner": false },
        { "name": "treasuryAta",  "isMut": true,  "isSigner": false },
        { "name": "authority",    "isMut": false, "isSigner": true  },
        { "name": "tokenProgram", "isMut": false, "isSigner": false }
      ],
      "args": [{ "name": "merchantId", "type": "string" }]
    }
  ],
  "accounts": [
    {
      "name": "SettlConfig",
      "type": {
        "kind": "struct",
        "fields": [
          { "name": "authority",           "type": "publicKey" },
          { "name": "treasuryWallet",      "type": "publicKey" },
          { "name": "feeBasisPoints",      "type": "u16"       },
          { "name": "totalFeesCollected",  "type": "u64"       },
          { "name": "bump",                "type": "u8"        }
        ]
      }
    },
    {
      "name": "MerchantAccount",
      "type": {
        "kind": "struct",
        "fields": [
          { "name": "merchantId",     "type": "string"            },
          { "name": "wallet",         "type": "publicKey"         },
          { "name": "isActive",       "type": "bool"              },
          { "name": "registeredAt",   "type": "i64"               },
          { "name": "totalReleased",  "type": "u64"               },
          { "name": "totalFeesPaid",  "type": "u64"               },
          { "name": "authority",      "type": "publicKey"         },
          { "name": "pendingWallet",  "type": { "option": "publicKey" } },
          { "name": "walletUpdateAt", "type": { "option": "i64"  }     },
          { "name": "bump",           "type": "u8"                }
        ]
      }
    },
    {
      "name": "EscrowAccount",
      "type": {
        "kind": "struct",
        "fields": [
          { "name": "merchantId",     "type": "string"    },
          { "name": "merchantWallet", "type": "publicKey" },
          { "name": "pendingBalance", "type": "u64"       },
          { "name": "totalPayments",  "type": "u64"       },
          { "name": "lastReleasedAt", "type": "i64"       },
          { "name": "authority",      "type": "publicKey" },
          { "name": "bump",           "type": "u8"        },
          { "name": "vaultBump",      "type": "u8"        }
        ]
      }
    }
  ],
  "errors": [
    { "code": 6000, "name": "FeeTooHigh",            "msg": "Fee cannot exceed 10%" },
    { "code": 6001, "name": "MerchantIdTooLong",     "msg": "Merchant ID must be 64 chars or fewer" },
    { "code": 6002, "name": "Unauthorized",           "msg": "Unauthorized" },
    { "code": 6003, "name": "NoWalletUpdatePending",  "msg": "No wallet update is pending" },
    { "code": 6004, "name": "WalletUpdateNotReady",   "msg": "24-hour delay has not passed" },
    { "code": 6005, "name": "ZeroAmount",             "msg": "Amount must be greater than zero" },
    { "code": 6006, "name": "ZeroBalance",            "msg": "No pending balance to release" },
    { "code": 6007, "name": "MerchantMismatch",       "msg": "Merchant ID does not match escrow" },
    { "code": 6008, "name": "MerchantInactive",       "msg": "Merchant is inactive" },
    { "code": 6009, "name": "Overflow",               "msg": "Arithmetic overflow" }
  ]
}
EOF

# ═══════════════════════════════════════════════════════════
# 2. config/anchor.js  — REPLACE the Phase 1 stub
#    Now fully initialises the Program with the IDL
# ═══════════════════════════════════════════════════════════
log "Wiring Anchor config with IDL..."
cat > backend/src/config/anchor.js << 'EOF'
require('dotenv').config();
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
EOF

# ═══════════════════════════════════════════════════════════
# 3. services/contract.js  — core on-chain calls
# ═══════════════════════════════════════════════════════════
log "Writing contract service..."
cat > backend/src/services/contract.js << 'EOF'
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
EOF

# ═══════════════════════════════════════════════════════════
# 4. services/merchant.js  — orchestrates DB + contract
# ═══════════════════════════════════════════════════════════
log "Writing merchant service..."
cat > backend/src/services/merchant.js << 'EOF'
const { supabase } = require('../config/supabase');
const contract     = require('./contract');

// ── createMerchant ────────────────────────────────────────
// Full flow: on-chain register → escrow init → DB record
async function createMerchant({ merchantId, walletAddress, name, email, createdBy }) {
  // 1. Register on-chain
  const { tx: registerTx, merchantPDA } = await contract.registerMerchant(merchantId, walletAddress);

  // 2. Initialize escrow vault
  const { tx: escrowTx, escrowPDA, vaultPDA } = await contract.initializeMerchantEscrow(merchantId);

  // 3. Persist to Supabase — merchants table
  const { data: merchant, error: mErr } = await supabase
    .from('merchants')
    .upsert({
      merchant_id:    merchantId,
      wallet_address: walletAddress,
      name:           name || merchantId,
      email:          email || null,
      is_active:      true,
      registered_at:  new Date().toISOString(),
      on_chain_tx:    registerTx,
      created_by:     createdBy,
    }, { onConflict: 'merchant_id' })
    .select()
    .single();

  if (mErr) throw new Error('DB merchant insert failed: ' + mErr.message);

  // 4. Persist escrow record
  const { error: eErr } = await supabase
    .from('escrows')
    .upsert({
      merchant_id:     merchantId,
      pending_balance: 0,
      total_payments:  0,
      vault_address:   vaultPDA,
    }, { onConflict: 'merchant_id' });

  if (eErr) throw new Error('DB escrow insert failed: ' + eErr.message);

  return { merchant, registerTx, escrowTx, escrowPDA, vaultPDA };
}

// ── getMerchantWithChainState ─────────────────────────────
// Merges DB record + live on-chain state
async function getMerchantWithChainState(merchantId) {
  const { data: dbRecord, error } = await supabase
    .from('merchants')
    .select('*, escrows(*)')
    .eq('merchant_id', merchantId)
    .single();

  if (error || !dbRecord) throw new Error('Merchant not found');

  const [onChain, escrowChain] = await Promise.all([
    contract.fetchMerchantOnChain(merchantId),
    contract.fetchEscrowOnChain(merchantId),
  ]);

  return { db: dbRecord, onChain, escrowChain };
}

// ── syncMerchantFromChain ─────────────────────────────────
// Updates DB to match on-chain state (called after wallet updates)
async function syncMerchantFromChain(merchantId) {
  const onChain = await contract.fetchMerchantOnChain(merchantId);
  if (!onChain) throw new Error('Merchant not found on-chain');

  await supabase
    .from('merchants')
    .update({
      wallet_address: onChain.wallet,
      is_active:      onChain.isActive,
    })
    .eq('merchant_id', merchantId);

  return onChain;
}

// ── requestWalletUpdate ───────────────────────────────────
async function requestWalletUpdate(merchantId, newWallet) {
  const result = await contract.requestWalletUpdate(merchantId, newWallet);

  // Record in DB for audit
  await supabase.from('wallet_update_requests').upsert({
    merchant_id:  merchantId,
    new_wallet:   newWallet,
    tx_signature: result.tx,
    unlocks_at:   new Date(Date.now() + 86_400_000).toISOString(),
    status:       'pending',
  }, { onConflict: 'merchant_id' });

  return result;
}

// ── confirmWalletUpdate ───────────────────────────────────
async function confirmWalletUpdate(merchantId) {
  const result = await contract.confirmWalletUpdate(merchantId);
  await contract.updateEscrowWallet(merchantId);
  await syncMerchantFromChain(merchantId);

  await supabase
    .from('wallet_update_requests')
    .update({ status: 'confirmed', confirmed_at: new Date().toISOString() })
    .eq('merchant_id', merchantId);

  return result;
}

// ── deactivateMerchant ────────────────────────────────────
async function deactivateMerchant(merchantId) {
  const result = await contract.deactivateMerchant(merchantId);

  await supabase
    .from('merchants')
    .update({ is_active: false })
    .eq('merchant_id', merchantId);

  return result;
}

module.exports = {
  createMerchant,
  getMerchantWithChainState,
  syncMerchantFromChain,
  requestWalletUpdate,
  confirmWalletUpdate,
  deactivateMerchant,
};
EOF

# ═══════════════════════════════════════════════════════════
# 5. routes/merchants.js — REPLACE Phase 1 stub
#    Full CRUD + wallet update + deactivate + chain state
# ═══════════════════════════════════════════════════════════
log "Replacing merchant routes with full implementation..."
cat > backend/src/routes/merchants.js << 'EOF'
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
EOF

# ═══════════════════════════════════════════════════════════
# 6. routes/escrow.js  — escrow state endpoints
# ═══════════════════════════════════════════════════════════
log "Writing escrow routes..."
cat > backend/src/routes/escrow.js << 'EOF'
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
EOF

# ═══════════════════════════════════════════════════════════
# 7. server.js — REPLACE to add escrow route
# ═══════════════════════════════════════════════════════════
log "Updating server.js with escrow route..."
cat > backend/src/server.js << 'EOF'
require('dotenv').config();
const express   = require('express');
const cors      = require('cors');
const helmet    = require('helmet');
const morgan    = require('morgan');
const rateLimit = require('express-rate-limit');

const authMiddleware   = require('./middleware/auth');
const merchantRoutes   = require('./routes/merchants');
const escrowRoutes     = require('./routes/escrow');
const authRoutes       = require('./routes/auth');
const healthRoutes     = require('./routes/health');

const app  = express();
const PORT = process.env.PORT || 3000;

app.use(helmet());
app.use(cors({ origin: process.env.FRONTEND_URL || 'http://localhost:5500', credentials: true }));
app.use(express.json());
app.use(morgan('dev'));

const limiter = rateLimit({ windowMs: 15 * 60 * 1000, max: 100 });
app.use('/api/', limiter);

app.use('/api/health',    healthRoutes);
app.use('/api/auth',      authRoutes);
app.use('/api/merchants', authMiddleware, merchantRoutes);
app.use('/api/escrow',    authMiddleware, escrowRoutes);

app.use((req, res) => res.status(404).json({ error: 'Route not found' }));
app.use((err, req, res, next) => {
  console.error('[ERROR]', err.message);
  res.status(err.status || 500).json({ error: err.message || 'Internal server error' });
});

app.listen(PORT, () => {
  console.log(`[SETTL] Backend running on http://localhost:${PORT}`);
  console.log(`[SETTL] Program ID: ${process.env.SETTL_PROGRAM_ID}`);
});

module.exports = app;
EOF

# ═══════════════════════════════════════════════════════════
# 8. Supabase migration — Phase 2 additions
#    wallet_update_requests table
# ═══════════════════════════════════════════════════════════
log "Writing Phase 2 Supabase migration..."
cat > supabase/migrations/002_phase2_wallet_updates.sql << 'EOF'
-- ═══════════════════════════════════════════════════════════
--  SETTL — Phase 2 Schema additions
-- ═══════════════════════════════════════════════════════════

-- ── wallet_update_requests ────────────────────────────────
-- Tracks the 24-hour delayed wallet change flow
create table if not exists wallet_update_requests (
  id           uuid primary key default uuid_generate_v4(),
  merchant_id  text not null references merchants(merchant_id) on delete cascade,
  new_wallet   text not null,
  tx_signature text,
  unlocks_at   timestamptz not null,
  status       text default 'pending'
               check (status in ('pending', 'confirmed', 'cancelled')),
  confirmed_at timestamptz,
  created_at   timestamptz default now(),
  constraint wallet_update_requests_merchant_id_key unique (merchant_id)
);

alter table wallet_update_requests enable row level security;

create policy "Authenticated users can read wallet update requests"
  on wallet_update_requests for select using (auth.role() = 'authenticated');

create policy "Service role can manage wallet update requests"
  on wallet_update_requests for all using (true);

-- ── Index for pending wallet updates ──────────────────────
create index if not exists idx_wallet_updates_status
  on wallet_update_requests(status);

-- ── Add on_chain_pda columns to merchants ────────────────
alter table merchants
  add column if not exists merchant_pda text,
  add column if not exists escrow_pda   text;
EOF

# ═══════════════════════════════════════════════════════════
# 9. FRONTEND — js/modules/api.js  UPDATE
#    Add merchant chain, escrow, and wallet update endpoints
# ═══════════════════════════════════════════════════════════
log "Updating frontend API module..."
cat > frontend/js/modules/api.js << 'EOF'
// ── SETTL API client — Phase 2 ────────────────────────────
const API_BASE = 'http://localhost:3000/api';

function getToken() {
  try { return JSON.parse(localStorage.getItem('settl_session'))?.access_token; }
  catch { return null; }
}

async function request(path, options = {}) {
  const token = getToken();
  const headers = {
    'Content-Type': 'application/json',
    ...(token ? { Authorization: `Bearer ${token}` } : {}),
    ...options.headers,
  };

  const res  = await fetch(`${API_BASE}${path}`, { ...options, headers });
  const data = await res.json();

  if (!res.ok) {
    const err = new Error(data.error || 'Request failed');
    err.status = res.status;
    throw err;
  }
  return data;
}

const api = {
  get:    (path, opts)        => request(path, { ...opts, method: 'GET'    }),
  post:   (path, body, opts)  => request(path, { ...opts, method: 'POST',   body: JSON.stringify(body) }),
  patch:  (path, body, opts)  => request(path, { ...opts, method: 'PATCH',  body: JSON.stringify(body) }),
  delete: (path, opts)        => request(path, { ...opts, method: 'DELETE' }),

  auth: {
    login:  (email) => api.post('/auth/login', { email }),
    me:     ()      => api.get('/auth/me'),
    logout: ()      => api.post('/auth/logout', {}),
  },

  merchants: {
    list:               ()                      => api.get('/merchants'),
    get:                (id)                    => api.get(`/merchants/${id}`),
    create:             (body)                  => api.post('/merchants', body),
    getChainState:      (id)                    => api.get(`/merchants/${id}/chain`),
    deactivate:         (id)                    => api.post(`/merchants/${id}/deactivate`, {}),
    sync:               (id)                    => api.post(`/merchants/${id}/sync`, {}),
    requestWalletUpdate: (id, newWallet)        => api.post(`/merchants/${id}/wallet-update/request`, { new_wallet: newWallet }),
    confirmWalletUpdate: (id)                   => api.post(`/merchants/${id}/wallet-update/confirm`, {}),
  },

  escrow: {
    get:     (merchantId)          => api.get(`/escrow/${merchantId}`),
    history: (merchantId, params)  => api.get(`/escrow/${merchantId}/history?${new URLSearchParams(params || {})}`),
  },
};

window.api = api;
EOF

# ═══════════════════════════════════════════════════════════
# 10. FRONTEND — pages/developer/merchants.html  FULL PAGE
#     Register form, merchant list, status, deactivate
# ═══════════════════════════════════════════════════════════
log "Writing developer merchants page..."
cat > frontend/pages/developer/merchants.html << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8"/>
  <meta name="viewport" content="width=device-width, initial-scale=1.0"/>
  <title>SETTL — Merchants</title>
  <link rel="stylesheet" href="../../css/app.css"/>
</head>
<body>
<div class="app-shell">
  <nav class="sidebar" id="sidebar"></nav>
  <div class="main-content">

    <div class="topbar">
      <span class="topbar-title">Merchants</span>
      <span class="badge badge-info">developer</span>
    </div>

    <div class="page-body">

      <!-- Register form -->
      <div class="card" style="margin-bottom:24px;">
        <h2 style="font-size:16px;font-weight:500;margin-bottom:18px;">Register new merchant</h2>
        <div style="display:grid;grid-template-columns:1fr 1fr;gap:16px;">
          <div class="form-group">
            <label class="form-label">Merchant ID <span style="color:var(--coral)">*</span></label>
            <input class="form-input" id="f-merchant-id" placeholder="e.g. acme-store-001" maxlength="64"/>
            <div class="form-hint">Unique identifier — max 64 chars. Used as the on-chain seed.</div>
          </div>
          <div class="form-group">
            <label class="form-label">Wallet address <span style="color:var(--coral)">*</span></label>
            <input class="form-input" id="f-wallet" placeholder="Solana public key (base58)"/>
            <div class="form-hint">AUDD releases will go to this wallet automatically.</div>
          </div>
          <div class="form-group">
            <label class="form-label">Display name</label>
            <input class="form-input" id="f-name" placeholder="ACME Store"/>
          </div>
          <div class="form-group">
            <label class="form-label">Contact email</label>
            <input class="form-input" id="f-email" type="email" placeholder="merchant@example.com"/>
          </div>
        </div>
        <div style="display:flex;gap:10px;align-items:center;margin-top:4px;">
          <button class="btn btn-primary" id="register-btn" onclick="registerMerchant()">
            Register on-chain
          </button>
          <span id="register-status" style="font-size:13px;color:var(--text-muted);"></span>
        </div>
      </div>

      <!-- Merchant list -->
      <div class="card">
        <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:16px;">
          <h2 style="font-size:16px;font-weight:500;">All merchants</h2>
          <button class="btn btn-secondary" style="font-size:13px;" onclick="loadMerchants()">Refresh</button>
        </div>
        <div class="table-wrap">
          <table>
            <thead>
              <tr>
                <th>Merchant ID</th>
                <th>Name</th>
                <th>Wallet</th>
                <th>Status</th>
                <th>Registered</th>
                <th>Actions</th>
              </tr>
            </thead>
            <tbody id="merchant-tbody">
              <tr><td colspan="6" style="text-align:center;padding:32px;color:var(--text-hint);">Loading...</td></tr>
            </tbody>
          </table>
        </div>
      </div>

    </div>
  </div>
</div>

<!-- Chain state modal -->
<div id="chain-modal-wrap" style="display:none;min-height:400px;background:rgba(0,0,0,0.45);position:fixed;inset:0;z-index:100;display:none;align-items:center;justify-content:center;">
  <div style="background:var(--surface);border-radius:var(--radius-lg);padding:28px 32px;width:100%;max-width:540px;border:1px solid var(--border);">
    <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:20px;">
      <h3 style="font-size:16px;font-weight:500;" id="modal-title">On-chain state</h3>
      <button onclick="closeModal()" style="background:none;border:none;cursor:pointer;font-size:20px;color:var(--text-muted);">×</button>
    </div>
    <div id="modal-body"></div>
  </div>
</div>

<script src="../../js/modules/api.js"></script>
<script src="../../js/modules/auth.js"></script>
<script src="../../js/modules/toast.js"></script>
<script src="../../js/modules/nav.js"></script>
<script>
  if (!auth.requireAuth()) throw new Error();
  document.getElementById('sidebar').innerHTML = buildSidebar('developer');

  function shortKey(k) {
    if (!k) return '—';
    return k.slice(0,6) + '…' + k.slice(-4);
  }

  function copyText(text) {
    navigator.clipboard.writeText(text).then(() => toast.success('Copied!'));
  }

  async function loadMerchants() {
    const tbody = document.getElementById('merchant-tbody');
    try {
      const { merchants } = await api.merchants.list();
      if (!merchants.length) {
        tbody.innerHTML = `<tr><td colspan="6" style="text-align:center;padding:40px;color:var(--text-hint);">
          No merchants yet — register the first one above.</td></tr>`;
        return;
      }
      tbody.innerHTML = merchants.map(m => `
        <tr>
          <td>
            <span style="font-family:var(--font-mono);font-size:12px;cursor:pointer;" onclick="copyText('${m.merchant_id}')" title="Click to copy">
              ${m.merchant_id}
            </span>
          </td>
          <td>${m.name || '—'}</td>
          <td>
            <span style="font-family:var(--font-mono);font-size:12px;cursor:pointer;" onclick="copyText('${m.wallet_address}')" title="Click to copy">
              ${shortKey(m.wallet_address)}
            </span>
          </td>
          <td>
            <span class="badge ${m.is_active ? 'badge-success' : 'badge-pending'}">
              ${m.is_active ? 'Active' : 'Inactive'}
            </span>
          </td>
          <td style="color:var(--text-muted);font-size:13px;">
            ${m.registered_at ? new Date(m.registered_at).toLocaleDateString() : '—'}
          </td>
          <td>
            <div style="display:flex;gap:6px;">
              <button class="btn btn-secondary" style="font-size:12px;padding:4px 10px;" onclick="showChainState('${m.merchant_id}')">Chain state</button>
              ${m.is_active ? `<button class="btn btn-danger" style="font-size:12px;padding:4px 10px;" onclick="deactivate('${m.merchant_id}')">Deactivate</button>` : ''}
            </div>
          </td>
        </tr>`).join('');
    } catch (err) {
      toast.error('Failed to load merchants: ' + err.message);
    }
  }

  async function registerMerchant() {
    const merchantId = document.getElementById('f-merchant-id').value.trim();
    const wallet     = document.getElementById('f-wallet').value.trim();
    const name       = document.getElementById('f-name').value.trim();
    const email      = document.getElementById('f-email').value.trim();

    if (!merchantId) { toast.error('Merchant ID is required'); return; }
    if (!wallet)     { toast.error('Wallet address is required'); return; }
    if (merchantId.length > 64) { toast.error('Merchant ID must be 64 chars or fewer'); return; }

    const btn    = document.getElementById('register-btn');
    const status = document.getElementById('register-status');
    btn.disabled = true;
    btn.textContent = 'Registering on-chain…';
    status.textContent = 'Sending transaction to Devnet…';

    try {
      const result = await api.merchants.create({ merchant_id: merchantId, wallet_address: wallet, name, email });
      status.textContent = '';
      toast.success('Merchant registered on-chain!');

      // Clear form
      ['f-merchant-id','f-wallet','f-name','f-email'].forEach(id => document.getElementById(id).value = '');

      // Show tx links
      showTxResult(result);
      loadMerchants();
    } catch (err) {
      toast.error(err.message);
      status.textContent = 'Failed: ' + err.message;
    } finally {
      btn.disabled = false;
      btn.textContent = 'Register on-chain';
    }
  }

  function showTxResult(result) {
    const explorerBase = 'https://explorer.solana.com/tx/';
    const cluster      = '?cluster=devnet';
    openModal('Registration successful', `
      <div style="display:flex;flex-direction:column;gap:12px;">
        <div>
          <div class="form-label" style="margin-bottom:4px;">Register tx</div>
          <a href="${explorerBase}${result.registerTx}${cluster}" target="_blank"
             style="font-family:var(--font-mono);font-size:12px;word-break:break-all;">
            ${result.registerTx}
          </a>
        </div>
        <div>
          <div class="form-label" style="margin-bottom:4px;">Escrow init tx</div>
          <a href="${explorerBase}${result.escrowTx}${cluster}" target="_blank"
             style="font-family:var(--font-mono);font-size:12px;word-break:break-all;">
            ${result.escrowTx}
          </a>
        </div>
        <div>
          <div class="form-label" style="margin-bottom:4px;">Vault PDA</div>
          <span style="font-family:var(--font-mono);font-size:12px;cursor:pointer;" onclick="copyText('${result.vaultPDA}')">
            ${result.vaultPDA}
          </span>
        </div>
      </div>
    `);
  }

  async function showChainState(merchantId) {
    openModal('On-chain state — ' + merchantId, '<p style="color:var(--text-muted);">Fetching from Devnet…</p>');
    try {
      const { merchant, escrow } = await api.merchants.getChainState(merchantId);
      const escrowData = await api.escrow.get(merchantId).catch(() => null);

      openModal('On-chain state — ' + merchantId, `
        <div style="display:flex;flex-direction:column;gap:16px;">
          <div>
            <div class="form-label" style="margin-bottom:8px;">Merchant account</div>
            <div style="display:grid;grid-template-columns:1fr 1fr;gap:8px;font-size:13px;">
              <div style="color:var(--text-muted);">Active</div>
              <div><span class="badge ${merchant.isActive ? 'badge-success' : 'badge-pending'}">${merchant.isActive}</span></div>
              <div style="color:var(--text-muted);">Wallet</div>
              <div style="font-family:var(--font-mono);font-size:12px;cursor:pointer;" onclick="copyText('${merchant.wallet}')">${shortKey(merchant.wallet)}</div>
              <div style="color:var(--text-muted);">Total released</div>
              <div>${(merchant.totalReleased / 1_000_000).toFixed(6)} AUDD</div>
              <div style="color:var(--text-muted);">Total fees paid</div>
              <div>${(merchant.totalFeesPaid / 1_000_000).toFixed(6)} AUDD</div>
              ${merchant.pendingWallet ? `
              <div style="color:var(--text-muted);">Pending wallet</div>
              <div style="font-family:var(--font-mono);font-size:12px;">${shortKey(merchant.pendingWallet)}</div>
              <div style="color:var(--text-muted);">Unlocks at</div>
              <div>${merchant.walletUpdateAt ? new Date(merchant.walletUpdateAt * 1000).toLocaleString() : '—'}</div>
              ` : ''}
            </div>
          </div>
          ${escrow ? `
          <div>
            <div class="form-label" style="margin-bottom:8px;">Escrow vault</div>
            <div style="display:grid;grid-template-columns:1fr 1fr;gap:8px;font-size:13px;">
              <div style="color:var(--text-muted);">Pending balance</div>
              <div style="font-weight:500;">${(escrow.pendingBalance / 1_000_000).toFixed(6)} AUDD</div>
              <div style="color:var(--text-muted);">Total payments</div>
              <div>${escrow.totalPayments}</div>
              <div style="color:var(--text-muted);">Last released</div>
              <div>${escrow.lastReleasedAt || '—'}</div>
              <div style="color:var(--text-muted);">Source</div>
              <div><span class="badge badge-info">${escrow.source}</span></div>
            </div>
          </div>
          ` : ''}
          ${merchant.pendingWallet ? `
          <div style="border-top:1px solid var(--border);padding-top:16px;">
            <div class="form-label" style="margin-bottom:8px;">Wallet update pending</div>
            <p style="font-size:13px;color:var(--text-muted);margin-bottom:12px;">
              A wallet change to <strong>${shortKey(merchant.pendingWallet)}</strong> is staged.
              It can be confirmed after ${new Date(merchant.walletUpdateAt * 1000).toLocaleString()}.
            </p>
            <button class="btn btn-primary" style="font-size:13px;" onclick="confirmWalletUpdate('${merchantId}')">
              Confirm wallet update
            </button>
          </div>
          ` : `
          <div style="border-top:1px solid var(--border);padding-top:16px;">
            <div class="form-label" style="margin-bottom:8px;">Request wallet update</div>
            <div style="display:flex;gap:8px;">
              <input class="form-input" id="new-wallet-input" placeholder="New Solana public key" style="flex:1;"/>
              <button class="btn btn-secondary" onclick="requestWalletUpdate('${merchantId}')">Stage update</button>
            </div>
            <div class="form-hint">A 24-hour security delay applies before the change can be confirmed.</div>
          </div>
          `}
        </div>
      `);
    } catch (err) {
      openModal('Error', `<p style="color:var(--coral);">${err.message}</p>`);
    }
  }

  async function deactivate(merchantId) {
    if (!confirm(`Deactivate merchant "${merchantId}"? This stops the escrow from accepting deposits.`)) return;
    try {
      await api.merchants.deactivate(merchantId);
      toast.success('Merchant deactivated on-chain');
      loadMerchants();
    } catch (err) {
      toast.error(err.message);
    }
  }

  async function requestWalletUpdate(merchantId) {
    const newWallet = document.getElementById('new-wallet-input')?.value?.trim();
    if (!newWallet) { toast.error('Enter a new wallet address'); return; }
    try {
      const result = await api.merchants.requestWalletUpdate(merchantId, newWallet);
      toast.success('Wallet update staged — confirm in 24 hours');
      closeModal();
      loadMerchants();
    } catch (err) {
      toast.error(err.message);
    }
  }

  async function confirmWalletUpdate(merchantId) {
    try {
      await api.merchants.confirmWalletUpdate(merchantId);
      toast.success('Wallet updated on-chain');
      closeModal();
      loadMerchants();
    } catch (err) {
      toast.error(err.message);
    }
  }

  function openModal(title, bodyHtml) {
    document.getElementById('modal-title').textContent = title;
    document.getElementById('modal-body').innerHTML    = bodyHtml;
    document.getElementById('chain-modal-wrap').style.display = 'flex';
  }

  function closeModal() {
    document.getElementById('chain-modal-wrap').style.display = 'none';
  }

  loadMerchants();
</script>
</body>
</html>
EOF

# ═══════════════════════════════════════════════════════════
# 11. FRONTEND — pages/developer/escrow.html  FULL PAGE
#     Live escrow state viewer for all merchants
# ═══════════════════════════════════════════════════════════
log "Writing developer escrow viewer page..."
cat > frontend/pages/developer/escrow.html << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8"/>
  <meta name="viewport" content="width=device-width, initial-scale=1.0"/>
  <title>SETTL — Escrow viewer</title>
  <link rel="stylesheet" href="../../css/app.css"/>
</head>
<body>
<div class="app-shell">
  <nav class="sidebar" id="sidebar"></nav>
  <div class="main-content">

    <div class="topbar">
      <span class="topbar-title">Escrow viewer</span>
      <div style="display:flex;gap:10px;align-items:center;">
        <span class="badge badge-info">developer</span>
        <button class="btn btn-secondary" style="font-size:13px;" onclick="refreshAll()">Refresh all</button>
      </div>
    </div>

    <div class="page-body">

      <!-- Summary cards -->
      <div class="card-grid" id="summary-cards">
        <div class="card">
          <div class="card-title">Total pending</div>
          <div class="card-value" id="total-pending">—</div>
          <div class="card-sub">AUDD across all escrows</div>
        </div>
        <div class="card">
          <div class="card-title">Active merchants</div>
          <div class="card-value" id="total-merchants">—</div>
          <div class="card-sub">With initialised escrows</div>
        </div>
        <div class="card">
          <div class="card-title">Total payments</div>
          <div class="card-value" id="total-payments">—</div>
          <div class="card-sub">All time across all vaults</div>
        </div>
      </div>

      <!-- Per-merchant escrow state -->
      <div class="card">
        <h2 style="font-size:16px;font-weight:500;margin-bottom:16px;">Vault state — live from chain</h2>
        <div class="table-wrap">
          <table>
            <thead>
              <tr>
                <th>Merchant ID</th>
                <th>Pending balance</th>
                <th>Total payments</th>
                <th>Last released</th>
                <th>Vault</th>
                <th>Source</th>
              </tr>
            </thead>
            <tbody id="escrow-tbody">
              <tr><td colspan="6" style="text-align:center;padding:32px;color:var(--text-hint);">Loading…</td></tr>
            </tbody>
          </table>
        </div>
      </div>

      <!-- Transaction history for selected merchant -->
      <div class="card" id="tx-section" style="display:none;">
        <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:16px;">
          <h2 style="font-size:16px;font-weight:500;">Transactions — <span id="tx-merchant-label"></span></h2>
          <button class="btn btn-secondary" style="font-size:13px;" onclick="document.getElementById('tx-section').style.display='none'">Close</button>
        </div>
        <div class="table-wrap">
          <table>
            <thead>
              <tr><th>Type</th><th>Amount</th><th>Fee</th><th>Net</th><th>Status</th><th>Date</th><th>Tx</th></tr>
            </thead>
            <tbody id="tx-tbody">
              <tr><td colspan="7" style="text-align:center;padding:24px;color:var(--text-hint);">Select a merchant to view transactions</td></tr>
            </tbody>
          </table>
        </div>
      </div>

    </div>
  </div>
</div>

<script src="../../js/modules/api.js"></script>
<script src="../../js/modules/auth.js"></script>
<script src="../../js/modules/toast.js"></script>
<script src="../../js/modules/nav.js"></script>
<script>
  if (!auth.requireAuth()) throw new Error();
  document.getElementById('sidebar').innerHTML = buildSidebar('developer');

  function shortKey(k) { return k ? k.slice(0,6) + '…' + k.slice(-4) : '—'; }
  function fmtAUDD(raw) {
    if (raw == null) return '—';
    return (raw / 1_000_000).toFixed(2) + ' AUDD';
  }

  async function refreshAll() {
    const tbody = document.getElementById('escrow-tbody');
    tbody.innerHTML = `<tr><td colspan="6" style="text-align:center;padding:32px;color:var(--text-hint);">Fetching from chain…</td></tr>`;

    try {
      const { merchants } = await api.merchants.list();
      if (!merchants.length) {
        tbody.innerHTML = `<tr><td colspan="6" style="text-align:center;padding:40px;color:var(--text-hint);">No merchants registered yet</td></tr>`;
        return;
      }

      // Fetch all escrow states in parallel
      const escrows = await Promise.all(
        merchants.map(m => api.escrow.get(m.merchant_id).catch(e => ({
          merchantId:     m.merchant_id,
          pendingBalance: 0,
          totalPayments:  0,
          lastReleasedAt: null,
          vaultAddress:   null,
          source:         'error: ' + e.message,
        })))
      );

      // Summary
      const totalPending  = escrows.reduce((s, e) => s + (e.pendingBalance || 0), 0);
      const totalPayments = escrows.reduce((s, e) => s + (e.totalPayments  || 0), 0);
      document.getElementById('total-pending').textContent   = fmtAUDD(totalPending);
      document.getElementById('total-merchants').textContent = merchants.filter(m => m.is_active).length;
      document.getElementById('total-payments').textContent  = totalPayments;

      tbody.innerHTML = escrows.map(e => `
        <tr style="cursor:pointer;" onclick="loadTxHistory('${e.merchantId}')">
          <td style="font-family:var(--font-mono);font-size:12px;">${e.merchantId}</td>
          <td style="font-weight:500;color:${e.pendingBalance > 0 ? 'var(--teal)' : 'inherit'}">${fmtAUDD(e.pendingBalance)}</td>
          <td>${e.totalPayments ?? '—'}</td>
          <td style="font-size:13px;color:var(--text-muted);">${e.lastReleasedAt ? new Date(e.lastReleasedAt).toLocaleString() : 'Never'}</td>
          <td style="font-family:var(--font-mono);font-size:11px;">${shortKey(e.vaultAddress)}</td>
          <td><span class="badge ${e.source === 'chain' ? 'badge-success' : 'badge-pending'}">${e.source}</span></td>
        </tr>`).join('');

    } catch (err) {
      toast.error('Failed to load escrow state: ' + err.message);
    }
  }

  async function loadTxHistory(merchantId) {
    document.getElementById('tx-section').style.display = 'block';
    document.getElementById('tx-merchant-label').textContent = merchantId;
    const tbody = document.getElementById('tx-tbody');
    tbody.innerHTML = `<tr><td colspan="7" style="text-align:center;padding:24px;color:var(--text-hint);">Loading…</td></tr>`;

    try {
      const { transactions } = await api.escrow.history(merchantId, { limit: 30 });
      if (!transactions.length) {
        tbody.innerHTML = `<tr><td colspan="7" style="text-align:center;padding:24px;color:var(--text-hint);">No transactions yet</td></tr>`;
        return;
      }
      const explorerBase = 'https://explorer.solana.com/tx/';
      tbody.innerHTML = transactions.map(t => `
        <tr>
          <td><span class="badge badge-info">${t.type}</span></td>
          <td>${fmtAUDD(t.amount)}</td>
          <td style="color:var(--text-muted);">${t.fee ? fmtAUDD(t.fee) : '—'}</td>
          <td>${t.net ? fmtAUDD(t.net) : '—'}</td>
          <td><span class="badge ${t.status === 'confirmed' ? 'badge-success' : t.status === 'failed' ? 'badge-error' : 'badge-pending'}">${t.status}</span></td>
          <td style="font-size:13px;color:var(--text-muted);">${new Date(t.created_at).toLocaleString()}</td>
          <td>${t.tx_signature ? `<a href="${explorerBase}${t.tx_signature}?cluster=devnet" target="_blank" style="font-family:var(--font-mono);font-size:11px;">${shortKey(t.tx_signature)}</a>` : '—'}</td>
        </tr>`).join('');
    } catch (err) {
      toast.error('Failed to load transactions: ' + err.message);
    }
  }

  refreshAll();
</script>
</body>
</html>
EOF

# ═══════════════════════════════════════════════════════════
# 12. FRONTEND — pages/operator/balance.html  FULL PAGE
#     Live balance, escrow state, wallet settings
# ═══════════════════════════════════════════════════════════
log "Writing operator balance page..."
cat > frontend/pages/operator/balance.html << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8"/>
  <meta name="viewport" content="width=device-width, initial-scale=1.0"/>
  <title>SETTL — Balance</title>
  <link rel="stylesheet" href="../../css/app.css"/>
</head>
<body>
<div class="app-shell">
  <nav class="sidebar" id="sidebar"></nav>
  <div class="main-content">

    <div class="topbar">
      <span class="topbar-title">Balance</span>
      <span class="badge badge-success">operator</span>
    </div>

    <div class="page-body">

      <div class="card-grid">
        <div class="card">
          <div class="card-title">Pending balance</div>
          <div class="card-value" id="pending-balance">—</div>
          <div class="card-sub">Releases automatically at 6am</div>
        </div>
        <div class="card">
          <div class="card-title">Total payments</div>
          <div class="card-value" id="total-payments">—</div>
          <div class="card-sub">Deposits received all time</div>
        </div>
        <div class="card">
          <div class="card-title">Total released</div>
          <div class="card-value" id="total-released">—</div>
          <div class="card-sub">Net AUDD received</div>
        </div>
        <div class="card">
          <div class="card-title">Total fees paid</div>
          <div class="card-value" id="total-fees">—</div>
          <div class="card-sub">1.5% per release</div>
        </div>
      </div>

      <!-- Wallet info -->
      <div class="card">
        <h2 style="font-size:16px;font-weight:500;margin-bottom:16px;">Merchant wallet</h2>
        <div id="wallet-section">
          <div style="display:flex;align-items:center;gap:12px;flex-wrap:wrap;">
            <code id="wallet-address" style="font-family:var(--font-mono);font-size:13px;background:var(--bg);padding:8px 12px;border-radius:var(--radius-sm);border:1px solid var(--border);">Loading…</code>
            <button class="btn btn-secondary" style="font-size:13px;" onclick="copyWallet()">Copy</button>
          </div>
          <div id="pending-wallet-notice" style="display:none;margin-top:12px;padding:12px;background:var(--color-background-warning);border-radius:var(--radius-sm);font-size:13px;color:var(--color-text-warning);border:1px solid var(--color-border-warning);">
            A wallet update is pending. It will be confirmed by your administrator after the 24-hour security delay.
          </div>
        </div>
      </div>

      <!-- Vault technical details -->
      <div class="card">
        <h2 style="font-size:16px;font-weight:500;margin-bottom:16px;">Escrow vault</h2>
        <div style="display:grid;grid-template-columns:1fr 1fr;gap:12px;font-size:14px;" id="vault-details">
          <div style="color:var(--text-muted);">Vault address</div>
          <div id="vault-addr" style="font-family:var(--font-mono);font-size:12px;">—</div>
          <div style="color:var(--text-muted);">Last released</div>
          <div id="last-released">—</div>
          <div style="color:var(--text-muted);">Data source</div>
          <div id="data-source"><span class="badge badge-info">—</span></div>
        </div>
        <button class="btn btn-secondary" style="font-size:13px;margin-top:16px;" onclick="loadBalance()">Refresh from chain</button>
      </div>

    </div>
  </div>
</div>

<script src="../../js/modules/api.js"></script>
<script src="../../js/modules/auth.js"></script>
<script src="../../js/modules/toast.js"></script>
<script src="../../js/modules/nav.js"></script>
<script>
  if (!auth.requireAuth()) throw new Error();
  document.getElementById('sidebar').innerHTML = buildSidebar('operator');

  function fmtAUDD(raw) {
    if (raw == null) return '—';
    return (raw / 1_000_000).toFixed(6) + ' AUDD';
  }

  let currentMerchantId = null;

  async function loadBalance() {
    try {
      const { merchants } = await api.merchants.list();
      const active = merchants.find(m => m.is_active);
      if (!active) {
        toast.info('No active merchant found — ask your developer to register one.');
        return;
      }
      currentMerchantId = active.merchant_id;

      const [escrow, chainState] = await Promise.all([
        api.escrow.get(active.merchant_id),
        api.merchants.getChainState(active.merchant_id).catch(() => null),
      ]);

      document.getElementById('pending-balance').textContent = fmtAUDD(escrow.pendingBalance);
      document.getElementById('total-payments').textContent  = escrow.totalPayments ?? '—';

      if (chainState?.merchant) {
        document.getElementById('total-released').textContent = fmtAUDD(chainState.merchant.totalReleased);
        document.getElementById('total-fees').textContent     = fmtAUDD(chainState.merchant.totalFeesPaid);
        document.getElementById('wallet-address').textContent  = chainState.merchant.wallet;

        if (chainState.merchant.pendingWallet) {
          document.getElementById('pending-wallet-notice').style.display = 'block';
        }
      }

      document.getElementById('vault-addr').textContent   = escrow.vaultAddress || '—';
      document.getElementById('last-released').textContent = escrow.lastReleasedAt
        ? new Date(escrow.lastReleasedAt).toLocaleString() : 'Never';
      document.getElementById('data-source').innerHTML =
        `<span class="badge ${escrow.source === 'chain' ? 'badge-success' : 'badge-pending'}">${escrow.source}</span>`;

    } catch (err) {
      toast.error('Failed to load balance: ' + err.message);
    }
  }

  function copyWallet() {
    const addr = document.getElementById('wallet-address').textContent;
    navigator.clipboard.writeText(addr).then(() => toast.success('Wallet address copied!'));
  }

  loadBalance();
</script>
</body>
</html>
EOF

# ═══════════════════════════════════════════════════════════
# 13. FRONTEND — pages/developer/transactions.html
#     Raw transaction log across all merchants
# ═══════════════════════════════════════════════════════════
log "Writing developer transactions page..."
cat > frontend/pages/developer/transactions.html << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8"/>
  <meta name="viewport" content="width=device-width, initial-scale=1.0"/>
  <title>SETTL — Transactions</title>
  <link rel="stylesheet" href="../../css/app.css"/>
</head>
<body>
<div class="app-shell">
  <nav class="sidebar" id="sidebar"></nav>
  <div class="main-content">
    <div class="topbar">
      <span class="topbar-title">Transaction log</span>
      <span class="badge badge-info">developer</span>
    </div>
    <div class="page-body">

      <!-- Filters -->
      <div class="card" style="margin-bottom:16px;">
        <div style="display:flex;gap:12px;align-items:flex-end;flex-wrap:wrap;">
          <div class="form-group" style="margin-bottom:0;flex:1;min-width:180px;">
            <label class="form-label">Merchant ID</label>
            <select class="form-input" id="filter-merchant" onchange="loadTx()">
              <option value="">All merchants</option>
            </select>
          </div>
          <div class="form-group" style="margin-bottom:0;">
            <label class="form-label">Type</label>
            <select class="form-input" id="filter-type" onchange="loadTx()">
              <option value="">All types</option>
              <option value="deposit">Deposit</option>
              <option value="release">Release</option>
              <option value="fee">Fee</option>
            </select>
          </div>
          <div class="form-group" style="margin-bottom:0;">
            <label class="form-label">Status</label>
            <select class="form-input" id="filter-status" onchange="loadTx()">
              <option value="">All statuses</option>
              <option value="confirmed">Confirmed</option>
              <option value="pending">Pending</option>
              <option value="failed">Failed</option>
            </select>
          </div>
          <button class="btn btn-secondary" onclick="loadTx()">Filter</button>
        </div>
      </div>

      <div class="card">
        <div class="table-wrap">
          <table>
            <thead>
              <tr>
                <th>Merchant</th>
                <th>Type</th>
                <th>Amount</th>
                <th>Fee</th>
                <th>Net</th>
                <th>Status</th>
                <th>Date</th>
                <th>Tx signature</th>
              </tr>
            </thead>
            <tbody id="tx-tbody">
              <tr><td colspan="8" style="text-align:center;padding:32px;color:var(--text-hint);">Loading…</td></tr>
            </tbody>
          </table>
        </div>
        <div id="pagination" style="display:flex;justify-content:space-between;align-items:center;margin-top:12px;font-size:13px;color:var(--text-muted);">
          <span id="page-info"></span>
          <div style="display:flex;gap:8px;">
            <button class="btn btn-secondary" style="font-size:13px;" id="btn-prev" onclick="changePage(-1)">Previous</button>
            <button class="btn btn-secondary" style="font-size:13px;" id="btn-next" onclick="changePage(1)">Next</button>
          </div>
        </div>
      </div>

    </div>
  </div>
</div>

<script src="../../js/modules/api.js"></script>
<script src="../../js/modules/auth.js"></script>
<script src="../../js/modules/toast.js"></script>
<script src="../../js/modules/nav.js"></script>
<script>
  if (!auth.requireAuth()) throw new Error();
  document.getElementById('sidebar').innerHTML = buildSidebar('developer');

  const { supabase: sb } = window;
  let offset = 0;
  const limit = 25;
  let total   = 0;

  function fmtAUDD(v) { return v != null ? (v/1_000_000).toFixed(2) + ' AUDD' : '—'; }
  function shortKey(k) { return k ? k.slice(0,6) + '…' + k.slice(-4) : '—'; }

  async function init() {
    try {
      const { merchants } = await api.merchants.list();
      const sel = document.getElementById('filter-merchant');
      merchants.forEach(m => {
        const opt = document.createElement('option');
        opt.value = m.merchant_id;
        opt.textContent = m.merchant_id + (m.name ? ` (${m.name})` : '');
        sel.appendChild(opt);
      });
    } catch {}
    loadTx();
  }

  async function loadTx() {
    const merchantId = document.getElementById('filter-merchant').value;
    const type       = document.getElementById('filter-type').value;
    const status     = document.getElementById('filter-status').value;
    const tbody      = document.getElementById('tx-tbody');
    tbody.innerHTML  = `<tr><td colspan="8" style="text-align:center;padding:24px;color:var(--text-hint);">Loading…</td></tr>`;

    try {
      const params = new URLSearchParams({ limit, offset });
      if (type)   params.set('type',   type);
      if (status) params.set('status', status);

      const url = merchantId
        ? `/escrow/${merchantId}/history?${params}`
        : `/merchants?${params}`;

      // Fetch from the right endpoint
      let transactions = [], t = 0;
      if (merchantId) {
        const r = await api.escrow.history(merchantId, { limit, offset, type, status });
        transactions = r.transactions;
        t = r.total;
      } else {
        // All merchants — pull from supabase directly via backend
        // (In production, add a dedicated /transactions endpoint)
        const { merchants } = await api.merchants.list();
        const all = await Promise.all(
          merchants.slice(0, 10).map(m =>
            api.escrow.history(m.merchant_id, { limit: 10 }).then(r => r.transactions).catch(() => [])
          )
        );
        transactions = all.flat().sort((a, b) => new Date(b.created_at) - new Date(a.created_at)).slice(0, limit);
        t = transactions.length;
      }

      total = t;
      const explorerBase = 'https://explorer.solana.com/tx/';

      if (!transactions.length) {
        tbody.innerHTML = `<tr><td colspan="8" style="text-align:center;padding:40px;color:var(--text-hint);">No transactions found</td></tr>`;
      } else {
        tbody.innerHTML = transactions.map(tx => `
          <tr>
            <td style="font-family:var(--font-mono);font-size:12px;">${tx.merchant_id}</td>
            <td><span class="badge badge-info">${tx.type}</span></td>
            <td>${fmtAUDD(tx.amount)}</td>
            <td style="color:var(--text-muted);">${fmtAUDD(tx.fee)}</td>
            <td style="font-weight:500;">${fmtAUDD(tx.net)}</td>
            <td><span class="badge ${tx.status==='confirmed'?'badge-success':tx.status==='failed'?'badge-error':'badge-pending'}">${tx.status}</span></td>
            <td style="font-size:12px;color:var(--text-muted);">${new Date(tx.created_at).toLocaleString()}</td>
            <td>${tx.tx_signature ? `<a href="${explorerBase}${tx.tx_signature}?cluster=devnet" target="_blank" style="font-family:var(--font-mono);font-size:11px;">${shortKey(tx.tx_signature)}</a>` : '—'}</td>
          </tr>`).join('');
      }

      document.getElementById('page-info').textContent = `Showing ${offset+1}–${Math.min(offset+limit, total)} of ${total}`;
      document.getElementById('btn-prev').disabled = offset === 0;
      document.getElementById('btn-next').disabled = offset + limit >= total;

    } catch (err) {
      toast.error('Failed to load transactions: ' + err.message);
    }
  }

  function changePage(dir) {
    offset = Math.max(0, offset + dir * limit);
    loadTx();
  }

  init();
</script>
</body>
</html>
EOF

# ═══════════════════════════════════════════════════════════
# 14. FRONTEND — pages/dashboard.html — UPDATE
#     Now loads real escrow stats from the contract
# ═══════════════════════════════════════════════════════════
log "Updating dashboard with live chain stats..."
cat > frontend/pages/dashboard.html << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8"/>
  <meta name="viewport" content="width=device-width, initial-scale=1.0"/>
  <title>SETTL — Dashboard</title>
  <link rel="stylesheet" href="../css/app.css"/>
</head>
<body>
<div class="app-shell">
  <nav class="sidebar" id="sidebar"></nav>
  <div class="main-content">

    <div class="topbar">
      <span class="topbar-title" id="page-title">Overview</span>
      <div style="display:flex;align-items:center;gap:12px;">
        <span class="badge badge-info" id="mode-badge">loading</span>
        <span id="user-email" style="font-size:13px;color:var(--text-muted);"></span>
      </div>
    </div>

    <div class="page-body">
      <div class="card-grid">
        <div class="card">
          <div class="card-title">Total pending</div>
          <div class="card-value" id="stat-balance">—</div>
          <div class="card-sub">AUDD across all escrows</div>
        </div>
        <div class="card">
          <div class="card-title">Total payments</div>
          <div class="card-value" id="stat-payments">—</div>
          <div class="card-sub">All time</div>
        </div>
        <div class="card">
          <div class="card-title">Next release</div>
          <div class="card-value" id="stat-release">—</div>
          <div class="card-sub">Automatic daily at 6am</div>
        </div>
        <div class="card">
          <div class="card-title">Active merchants</div>
          <div class="card-value" id="stat-merchants">—</div>
          <div class="card-sub">On-chain registered</div>
        </div>
      </div>

      <div class="card">
        <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:16px;">
          <h2 style="font-size:16px;font-weight:500;">Merchants overview</h2>
          <a href="/pages/developer/merchants.html" class="btn btn-secondary" style="font-size:13px;">View all</a>
        </div>
        <div class="table-wrap">
          <table>
            <thead>
              <tr><th>Merchant ID</th><th>Status</th><th>Pending balance</th><th>Total payments</th><th>Last released</th></tr>
            </thead>
            <tbody id="merchant-overview-tbody">
              <tr><td colspan="5" style="text-align:center;padding:32px;color:var(--text-hint);">Loading…</td></tr>
            </tbody>
          </table>
        </div>
      </div>
    </div>

  </div>
</div>

<script src="../js/modules/api.js"></script>
<script src="../js/modules/auth.js"></script>
<script src="../js/modules/toast.js"></script>
<script src="../js/modules/nav.js"></script>
<script>
  if (!auth.requireAuth()) throw new Error();

  const mode    = auth.getMode();
  const profile = auth.getProfile();

  document.getElementById('sidebar').innerHTML = buildSidebar(mode);
  document.getElementById('mode-badge').textContent = mode;
  document.getElementById('user-email').textContent  = profile?.email || '';

  function fmtAUDD(v) { return v != null ? (v/1_000_000).toFixed(2) + ' AUDD' : '—'; }

  function getNextReleaseTime() {
    const now   = new Date();
    const next  = new Date();
    next.setHours(6, 0, 0, 0);
    if (next <= now) next.setDate(next.getDate() + 1);
    const diff  = next - now;
    const h     = Math.floor(diff / 3_600_000);
    const m     = Math.floor((diff % 3_600_000) / 60_000);
    return `${h}h ${m}m`;
  }

  async function loadDashboard() {
    try {
      const { merchants } = await api.merchants.list();
      const active = merchants.filter(m => m.is_active);

      document.getElementById('stat-merchants').textContent = active.length;
      document.getElementById('stat-release').textContent   = getNextReleaseTime();

      if (!merchants.length) {
        document.getElementById('merchant-overview-tbody').innerHTML =
          `<tr><td colspan="5"><div class="empty-state">
            <div class="empty-state-icon">◈</div>
            <h3>No merchants yet</h3>
            <p>Go to <a href="/pages/developer/merchants.html">Merchants</a> to register the first one</p>
          </div></td></tr>`;
        return;
      }

      // Load escrow state for each merchant
      const escrows = await Promise.all(
        active.slice(0, 10).map(m =>
          api.escrow.get(m.merchant_id).catch(() => ({ merchantId: m.merchant_id, pendingBalance: 0, totalPayments: 0 }))
        )
      );

      const totalPending  = escrows.reduce((s, e) => s + (e.pendingBalance  || 0), 0);
      const totalPayments = escrows.reduce((s, e) => s + (e.totalPayments   || 0), 0);

      document.getElementById('stat-balance').textContent   = fmtAUDD(totalPending);
      document.getElementById('stat-payments').textContent  = totalPayments;

      document.getElementById('merchant-overview-tbody').innerHTML = active.map((m, i) => {
        const e = escrows[i] || {};
        return `<tr>
          <td style="font-family:var(--font-mono);font-size:12px;">${m.merchant_id}</td>
          <td><span class="badge badge-success">Active</span></td>
          <td style="font-weight:500;">${fmtAUDD(e.pendingBalance)}</td>
          <td>${e.totalPayments ?? '—'}</td>
          <td style="font-size:13px;color:var(--text-muted);">${e.lastReleasedAt ? new Date(e.lastReleasedAt).toLocaleDateString() : 'Never'}</td>
        </tr>`;
      }).join('');

    } catch (err) {
      toast.error('Dashboard load failed: ' + err.message);
    }
  }

  loadDashboard();
  // Refresh release countdown every minute
  setInterval(() => {
    document.getElementById('stat-release').textContent = getNextReleaseTime();
  }, 60_000);
</script>
</body>
</html>
EOF

# ═══════════════════════════════════════════════════════════
# 15. Install @solana/spl-token (needed for getAssociatedTokenAddress)
# ═══════════════════════════════════════════════════════════
log "Installing @solana/spl-token..."
cd backend
npm install @solana/spl-token --save --silent
cd ..

# ═══════════════════════════════════════════════════════════
# Done
# ═══════════════════════════════════════════════════════════
echo ""
echo -e "${GREEN}╔════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║   SETTL Phase 2 — Setup complete           ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BLUE}What was added:${NC}"
echo ""
echo -e "  Backend"
echo -e "   ${GREEN}+${NC} backend/src/idl/settl.json         Full contract IDL"
echo -e "   ${GREEN}+${NC} backend/src/config/anchor.js       Live Anchor program + PDA helpers"
echo -e "   ${GREEN}+${NC} backend/src/services/contract.js   All on-chain instruction calls"
echo -e "   ${GREEN}+${NC} backend/src/services/merchant.js   Orchestrates DB + contract"
echo -e "   ${GREEN}~${NC} backend/src/routes/merchants.js    Replaced stub with full implementation"
echo -e "   ${GREEN}+${NC} backend/src/routes/escrow.js       Escrow state + history endpoints"
echo -e "   ${GREEN}~${NC} backend/src/server.js              Added escrow route"
echo ""
echo -e "  Frontend"
echo -e "   ${GREEN}~${NC} frontend/js/modules/api.js         Extended with all Phase 2 endpoints"
echo -e "   ${GREEN}~${NC} frontend/pages/developer/merchants.html  Full register form + chain state modal"
echo -e "   ${GREEN}+${NC} frontend/pages/developer/escrow.html     Live escrow viewer (all vaults)"
echo -e "   ${GREEN}+${NC} frontend/pages/developer/transactions.html  Raw tx log with filters"
echo -e "   ${GREEN}~${NC} frontend/pages/operator/balance.html   Live balance from chain"
echo -e "   ${GREEN}~${NC} frontend/pages/dashboard.html          Real escrow stats + countdown"
echo ""
echo -e "  Supabase"
echo -e "   ${GREEN}+${NC} supabase/migrations/002_phase2_wallet_updates.sql"
echo ""
echo -e "  ${BLUE}Before starting:${NC}"
echo ""
echo -e "  1. Run the Phase 2 migration in Supabase SQL editor:"
echo -e "     ${YELLOW}supabase/migrations/002_phase2_wallet_updates.sql${NC}"
echo ""
echo -e "  2. Make sure backend/.env has:"
echo -e "     ${YELLOW}SETTL_PROGRAM_ID=RZgHzaU8jKm4ydzwkmoooqd2TNek4L9W4o8tthekeLn${NC}"
echo -e "     ${YELLOW}AUDD_MINT=<your AUDD mint address>${NC}"
echo -e "     ${YELLOW}AUTHORITY_KEYPAIR_PATH=./keypair.json${NC}"
echo ""
echo -e "  3. Place your authority keypair at ${YELLOW}backend/keypair.json${NC}"
echo ""
echo -e "  4. Restart the backend:"
echo -e "     ${YELLOW}npm run dev${NC}"
echo ""
warn "The authority keypair must have SOL on Devnet for transaction fees."
warn "Fund it with: solana airdrop 2 <your-authority-pubkey> --url devnet"
echo ""