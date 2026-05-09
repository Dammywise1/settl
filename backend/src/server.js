require('./config/env');
const express   = require('express');
const cors      = require('cors');
const helmet    = require('helmet');
const morgan    = require('morgan');
const rateLimit = require('express-rate-limit');
const path      = require('path');

const authMiddleware  = require('./middleware/auth');
const merchantRoutes  = require('./routes/merchants');
const escrowRoutes    = require('./routes/escrow');
const authRoutes      = require('./routes/auth');
const healthRoutes    = require('./routes/health');
const paymentRoutes   = require('./routes/payments');
const releaseRoutes   = require('./routes/releases');

// Start the daily release cron
require('./cron/dailyRelease');

const app  = express();
const PORT = process.env.PORT || 3000;

// ── Security & parsing ────────────────────────────────────
app.use(helmet({ contentSecurityPolicy: false }));
app.use(cors());
app.use(express.json());
app.use(morgan('dev'));

// ── Serve static frontend ─────────────────────────────────
const frontendPath = path.join(__dirname, '../../frontend');
app.use(express.static(frontendPath));

// ── API rate limiting ─────────────────────────────────────
const limiter = rateLimit({ windowMs: 15 * 60 * 1000, max: 100 });
app.use('/api/', limiter);

// ── API routes ────────────────────────────────────────────
app.use('/api/health',    healthRoutes);
app.use('/api/auth',      authRoutes);
app.use('/api/merchants', authMiddleware, merchantRoutes);
app.use('/api/escrow',    authMiddleware, escrowRoutes);
app.use('/api/payments',  paymentRoutes);          // public — customers pay here
app.use('/api/releases',  authMiddleware, releaseRoutes);

// ── Error handler ─────────────────────────────────────────
app.use((err, req, res, next) => {
  console.error('[ERROR]', err.stack || err.message);
  res.status(err.status || 500).json({ error: err.message || 'Internal server error' });
});

// ── Catch-all → frontend ──────────────────────────────────
app.get('*', (req, res) => {
  res.sendFile(path.join(frontendPath, 'index.html'));
});

app.listen(PORT, () => {
  console.log(`[SETTL] Server running on http://localhost:${PORT}`);
  console.log(`[SETTL] Frontend served from: ${frontendPath}`);
  console.log(`[SETTL] Program ID: ${process.env.SETTL_PROGRAM_ID}`);
});

module.exports = app;
