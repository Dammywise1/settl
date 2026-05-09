require('../config/env');
const router       = require('express').Router();
const { supabase } = require('../config/supabase');

// ── POST /api/auth/register ───────────────────────────────
router.post('/register', async (req, res, next) => {
  try {
    const { email, password, full_name } = req.body;
    if (!email || !password) {
      return res.status(400).json({ error: 'Email and password are required' });
    }
    if (password.length < 8) {
      return res.status(400).json({ error: 'Password must be at least 8 characters' });
    }

    const { data, error } = await supabase.auth.signUp({ email, password });
    if (error) throw error;

    // Set full_name on profile if provided
    if (full_name && data.user) {
      await supabase
        .from('profiles')
        .update({ full_name })
        .eq('id', data.user.id);
    }

    res.status(201).json({
      message: 'Account created. Check your email to confirm (if email confirmation is enabled).',
      user:    data.user,
    });
  } catch (err) { next(err); }
});

// ── POST /api/auth/login ──────────────────────────────────
router.post('/login', async (req, res, next) => {
  try {
    const { email, password } = req.body;
    if (!email || !password) {
      return res.status(400).json({ error: 'Email and password are required' });
    }

    const { data, error } = await supabase.auth.signInWithPassword({ email, password });
    if (error) {
      return res.status(401).json({ error: 'Invalid email or password' });
    }

    // Fetch profile + role
    const { data: profile } = await supabase
      .from('profiles')
      .select('*')
      .eq('id', data.user.id)
      .single();

    res.json({
      session: data.session,
      user:    data.user,
      profile,
    });
  } catch (err) { next(err); }
});

// ── POST /api/auth/logout ─────────────────────────────────
router.post('/logout', async (req, res, next) => {
  try {
    const token = req.headers.authorization?.split(' ')[1];
    if (token) await supabase.auth.admin.signOut(token);
    res.json({ message: 'Logged out' });
  } catch (err) { next(err); }
});

// ── POST /api/auth/forgot-password ───────────────────────
router.post('/forgot-password', async (req, res, next) => {
  try {
    const { email } = req.body;
    if (!email) return res.status(400).json({ error: 'Email is required' });

    const { error } = await supabase.auth.resetPasswordForEmail(email, {
      redirectTo: `${process.env.FRONTEND_URL || 'http://localhost:3000'}/pages/auth/reset-password.html`,
    });
    if (error) throw error;

    // Always respond OK so we don't leak which emails are registered
    res.json({ message: 'If that email exists, a reset link was sent.' });
  } catch (err) { next(err); }
});

// ── POST /api/auth/reset-password ────────────────────────
router.post('/reset-password', async (req, res, next) => {
  try {
    const { new_password } = req.body;
    const token = req.headers.authorization?.split(' ')[1];
    if (!token || !new_password) {
      return res.status(400).json({ error: 'Token and new_password are required' });
    }

    const { error } = await supabase.auth.updateUser({ password: new_password });
    if (error) throw error;
    res.json({ message: 'Password updated' });
  } catch (err) { next(err); }
});

// ── GET /api/auth/me ──────────────────────────────────────
router.get('/me', async (req, res, next) => {
  try {
    const token = req.headers.authorization?.split(' ')[1];
    if (!token) return res.status(401).json({ error: 'No token' });

    const { data: { user }, error } = await supabase.auth.getUser(token);
    if (error || !user) return res.status(401).json({ error: 'Invalid token' });

    const { data: profile } = await supabase
      .from('profiles')
      .select('*')
      .eq('id', user.id)
      .single();

    res.json({ user, profile });
  } catch (err) { next(err); }
});

module.exports = router;
