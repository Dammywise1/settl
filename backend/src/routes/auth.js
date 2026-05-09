const router   = require('express').Router();
const bcrypt   = require('bcryptjs');
const jwt      = require('jsonwebtoken');
const { supabase } = require('../config/supabase');
const authMiddleware = require('../middleware/auth');

const SALT_ROUNDS = 12;
const TOKEN_TTL   = '7d';

function signToken(user) {
  return jwt.sign(
    { sub: user.id, email: user.email, role: user.role },
    process.env.JWT_SECRET,
    { expiresIn: TOKEN_TTL }
  );
}

// ── POST /api/auth/signup ─────────────────────────────────
router.post('/signup', async (req, res, next) => {
  try {
    const { email, password, full_name } = req.body;
    if (!email || !password) return res.status(400).json({ error: 'Email and password required' });
    if (password.length < 8)  return res.status(400).json({ error: 'Password must be at least 8 characters' });

    // Check duplicate
    const { data: existing } = await supabase.from('users').select('id').eq('email', email.toLowerCase()).single();
    if (existing) return res.status(409).json({ error: 'An account with this email already exists' });

    const password_hash = await bcrypt.hash(password, SALT_ROUNDS);

    const { data: user, error } = await supabase
      .from('users')
      .insert({ email: email.toLowerCase(), password_hash, full_name: full_name || null, role: 'operator' })
      .select('id, email, role, full_name')
      .single();

    if (error) throw error;

    const token = signToken(user);
    res.status(201).json({ token, user });
  } catch (err) { next(err); }
});

// ── POST /api/auth/login ──────────────────────────────────
router.post('/login', async (req, res, next) => {
  try {
    const { email, password } = req.body;
    if (!email || !password) return res.status(400).json({ error: 'Email and password required' });

    const { data: user } = await supabase
      .from('users')
      .select('id, email, role, full_name, is_active, password_hash')
      .eq('email', email.toLowerCase())
      .single();

    if (!user) return res.status(401).json({ error: 'Invalid email or password' });
    if (!user.is_active) return res.status(403).json({ error: 'Account is disabled' });

    const valid = await bcrypt.compare(password, user.password_hash);
    if (!valid) return res.status(401).json({ error: 'Invalid email or password' });

    const { password_hash, ...safeUser } = user;
    const token = signToken(safeUser);
    res.json({ token, user: safeUser });
  } catch (err) { next(err); }
});

// ── GET /api/auth/me ──────────────────────────────────────
router.get('/me', authMiddleware, async (req, res) => {
  const { password_hash, ...user } = req.user;
  res.json({ user: req.user });
});

// ── PATCH /api/auth/profile ───────────────────────────────
router.patch('/profile', authMiddleware, async (req, res, next) => {
  try {
    const { full_name, role } = req.body;
    const updates = {};
    if (full_name) updates.full_name = full_name;
    if (role && ['developer', 'operator'].includes(role)) updates.role = role;

    const { data: user } = await supabase
      .from('users').update(updates).eq('id', req.user.id).select('id,email,role,full_name').single();
    res.json({ user });
  } catch (err) { next(err); }
});

// ── POST /api/auth/logout ─────────────────────────────────
// Stateless JWT — just tell client to delete the token
router.post('/logout', (req, res) => res.json({ message: 'Logged out' }));

module.exports = router;
