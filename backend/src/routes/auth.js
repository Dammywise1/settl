require('../config/env');
const router = require('express').Router();
const customAuth = require('../services/customAuth');

router.post('/register', async (req, res, next) => {
  try {
    const { email, password, full_name, role } = req.body;
    
    if (!email || !password) {
      return res.status(400).json({ error: 'Email and password are required' });
    }
    
    if (password.length < 6) {
      return res.status(400).json({ error: 'Password must be at least 6 characters' });
    }

    const { user, session } = await customAuth.registerUser(
      email, 
      password, 
      full_name || null,
      role || 'operator'
    );

    res.status(201).json({
      message: 'Account created successfully',
      user,
      session
    });
    
  } catch (err) {
    console.error('Register error:', err.message);
    res.status(400).json({ error: err.message });
  }
});

router.post('/login', async (req, res, next) => {
  try {
    const { email, password } = req.body;
    
    if (!email || !password) {
      return res.status(400).json({ error: 'Email and password are required' });
    }

    const { user, session } = await customAuth.loginUser(email, password);

    res.json({
      message: 'Logged in successfully',
      user,
      session
    });
    
  } catch (err) {
    console.error('Login error:', err.message);
    res.status(401).json({ error: err.message });
  }
});

router.post('/logout', async (req, res, next) => {
  try {
    const token = req.headers.authorization?.split(' ')[1];
    if (token) {
      await customAuth.logoutUser(token);
    }
    res.json({ message: 'Logged out successfully' });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

router.get('/me', async (req, res, next) => {
  try {
    const token = req.headers.authorization?.split(' ')[1];
    if (!token) {
      return res.status(401).json({ error: 'No token provided' });
    }

    const { user, session } = await customAuth.verifySession(token);
    res.json({ user, session });
    
  } catch (err) {
    res.status(401).json({ error: err.message });
  }
});

module.exports = router;
