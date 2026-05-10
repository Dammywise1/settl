const router   = require('express').Router();
const bcrypt   = require('bcryptjs');
const jwt      = require('jsonwebtoken');
const { v4: uuidv4 }   = require('uuid');
const { supabase }     = require('../config/supabase');
const authMiddleware   = require('../middleware/auth');
const { registerMerchantForUser } = require('../services/merchant');

const SALT  = 12;
const TTL   = '30d';

function signToken(user) {
  return jwt.sign(
    { sub: user.id, email: user.email },
    process.env.JWT_SECRET,
    { expiresIn: TTL }
  );
}

// ── POST /api/auth/signup ─────────────────────────────────
// Creates account AND registers merchant on-chain in background
router.post('/signup', async (req, res, next) => {
  try {
    const { email, password, full_name, wallet_address } = req.body;

    if (!email || !password)        return res.status(400).json({ error: 'Email and password required' });
    if (!wallet_address)            return res.status(400).json({ error: 'Wallet address required' });
    if (password.length < 8)        return res.status(400).json({ error: 'Password must be at least 8 characters' });

    // Check duplicate email
    const { data: existing } = await supabase
      .from('users').select('id').eq('email', email.toLowerCase()).maybeSingle();
    if (existing) return res.status(409).json({ error: 'An account with this email already exists' });

    const password_hash = await bcrypt.hash(password, SALT);

    // Create user
    const { data: user, error: uErr } = await supabase
      .from('users')
      .insert({ email: email.toLowerCase(), password_hash, full_name: full_name || null })
      .select('id, email, full_name')
      .single();
    if (uErr) throw uErr;

    // Generate a merchant_id from email prefix + random suffix
    // Sanitise: lowercase, replace non-alphanumeric with dash, max 40 chars
    const emailPrefix  = email.split('@')[0].toLowerCase().replace(/[^a-z0-9]/g, '-').slice(0, 20);
    const randomSuffix = uuidv4().split('-')[0];           // 8 chars
    const merchantId   = `${emailPrefix}-${randomSuffix}`; // e.g. "john-smith-3f7a2b1c"

    // Create merchant row as pending — respond immediately
    await supabase.from('merchants').insert({
      user_id:        user.id,
      merchant_id:    merchantId,
      name:           full_name || email.split('@')[0],
      wallet_address: wallet_address.trim(),
      registration_status: 'processing',
    });

    // Fire on-chain registration in background (don't await)
    registerMerchantForUser({ userId: user.id, merchantId, walletAddress: wallet_address.trim() })
      .catch(err => console.error('[signup] On-chain registration failed:', err.message));

    const token = signToken(user);
    res.status(201).json({
      token,
      user: { id: user.id, email: user.email, full_name: user.full_name },
      merchant: { merchant_id: merchantId, registration_status: 'processing' },
      message: 'Account created. Merchant being registered on-chain in background.',
    });
  } catch (err) { next(err); }
});

// ── POST /api/auth/login ──────────────────────────────────
router.post('/login', async (req, res, next) => {
  try {
    const { email, password } = req.body;
    if (!email || !password) return res.status(400).json({ error: 'Email and password required' });

    const { data: user } = await supabase
      .from('users')
      .select('id, email, full_name, is_active, password_hash')
      .eq('email', email.toLowerCase())
      .maybeSingle();

    if (!user)            return res.status(401).json({ error: 'Invalid email or password' });
    if (!user.is_active)  return res.status(403).json({ error: 'Account disabled' });

    const valid = await bcrypt.compare(password, user.password_hash);
    if (!valid) return res.status(401).json({ error: 'Invalid email or password' });

    // Fetch merchant
    const { data: merchant } = await supabase
      .from('merchants').select('merchant_id, registration_status, vault_address, wallet_address, name, is_active')
      .eq('user_id', user.id).maybeSingle();

    const { password_hash, ...safeUser } = user;
    const token = signToken(safeUser);
    res.json({ token, user: safeUser, merchant: merchant || null });
  } catch (err) { next(err); }
});

// ── POST /api/auth/logout ─────────────────────────────────
router.post('/logout', (req, res) => res.json({ message: 'Logged out' }));

// ── GET /api/auth/me ──────────────────────────────────────
router.get('/me', authMiddleware, async (req, res, next) => {
  try {
    const { data: merchant } = await supabase
      .from('merchants').select('*').eq('user_id', req.user.id).maybeSingle();
    res.json({ user: req.user, merchant });
  } catch (err) { next(err); }
});

// ── GET /api/auth/status ──────────────────────────────────
// Poll merchant registration status after signup
router.get('/status', authMiddleware, async (req, res, next) => {
  try {
    const { data: merchant } = await supabase
      .from('merchants')
      .select('merchant_id, registration_status, registration_error, vault_address, is_active, wallet_address')
      .eq('user_id', req.user.id)
      .maybeSingle();
    res.json({ merchant });
  } catch (err) { next(err); }
});

module.exports = router;

// ── PATCH /api/auth/profile ───────────────────────────────
router.patch('/profile', authMiddleware, async (req, res, next) => {
  try {
    const { full_name } = req.body;
    const { data: user } = await supabase
      .from('users').update({ full_name }).eq('id', req.user.id)
      .select('id,email,full_name').single();
    res.json({ user });
  } catch (err) { next(err); }
});
