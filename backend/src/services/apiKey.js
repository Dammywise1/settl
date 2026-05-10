const crypto   = require('crypto');
const bcrypt   = require('bcryptjs');
const { supabase } = require('../config/supabase');

// ── generate ──────────────────────────────────────────────
// Returns the raw key once (never stored).
// Stores a bcrypt hash. Prefix stored for display.
async function generateKey(merchantId, name) {
  // Format: sk_live_<32 random hex chars>
  const raw    = `sk_live_${crypto.randomBytes(16).toString('hex')}`;
  const prefix = raw.slice(0, 16); // "sk_live_XXXXXXXX"
  const hash   = await bcrypt.hash(raw, 10);

  const { data, error } = await supabase
    .from('api_keys')
    .insert({ merchant_id: merchantId, name, key_hash: hash, key_prefix: prefix })
    .select('id, name, key_prefix, created_at')
    .single();

  if (error) throw new Error('Failed to create API key: ' + error.message);

  return {
    ...data,
    key: raw, // shown ONCE to the merchant
    warning: 'Copy this key now — it will never be shown again.',
  };
}

// ── validate ──────────────────────────────────────────────
// Called by API key middleware on every protected request.
// bcrypt.compare is slow by design — cache result if needed.
async function validateKey(rawKey) {
  if (!rawKey?.startsWith('sk_live_')) return null;

  const prefix = rawKey.slice(0, 16);

  // Find keys matching the prefix (reduces bcrypt calls)
  const { data: keys } = await supabase
    .from('api_keys')
    .select('*, merchants(merchant_id, name, is_active, vault_address)')
    .eq('key_prefix', prefix)
    .eq('is_active', true);

  if (!keys?.length) return null;

  for (const key of keys) {
    const match = await bcrypt.compare(rawKey, key.key_hash);
    if (match) {
      // Update last_used_at (fire and forget)
      supabase.from('api_keys')
        .update({ last_used_at: new Date().toISOString() })
        .eq('id', key.id)
        .then(() => {}).catch(() => {});

      return key;
    }
  }
  return null;
}

// ── listKeys ──────────────────────────────────────────────
async function listKeys(merchantId) {
  const { data } = await supabase
    .from('api_keys')
    .select('id, name, key_prefix, is_active, last_used_at, created_at')
    .eq('merchant_id', merchantId)
    .order('created_at', { ascending: false });
  return data || [];
}

// ── revokeKey ─────────────────────────────────────────────
async function revokeKey(keyId, merchantId) {
  const { error } = await supabase
    .from('api_keys')
    .update({ is_active: false })
    .eq('id', keyId)
    .eq('merchant_id', merchantId);
  if (error) throw error;
}

module.exports = { generateKey, validateKey, listKeys, revokeKey };
