require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const express   = require('express');
const cors      = require('cors');
const helmet    = require('helmet');
const morgan    = require('morgan');
const path      = require('path');

const authMiddleware = require('./middleware/auth');
const { startCron }  = require('./cron/dailyRelease');

const app  = express();
const PORT = process.env.PORT || 3000;

// ── Trust proxy ────────────────────────────────────────────
// REQUIRED for Codespaces, Railway, Render, Heroku, ngrok.
// Without this, X-Forwarded-For causes express-rate-limit to
// throw ERR_ERL_UNEXPECTED_X_FORWARDED_FOR and crash requests.
app.set('trust proxy', 1);

// ── Core middleware ────────────────────────────────────────
app.use(helmet({ contentSecurityPolicy: false }));
app.use(cors());
app.use(express.json());
app.use(morgan('dev'));

// ── Static frontend ────────────────────────────────────────
app.use(express.static(path.join(__dirname, '../../frontend')));

// ══════════════════════════════════════════════════════════
// PUBLIC ROUTES — zero auth, zero rate limit
// Mounted at distinct prefixes so there is NO overlap
// with the protected /api/payments route below.
// ══════════════════════════════════════════════════════════

// Health + public config (anon key for Realtime)
app.use('/api/health',  require('./routes/health'));

// Auth (signup / login — no JWT needed to call these)
app.use('/api/auth',    require('./routes/auth'));

// ── THE FIX: public payment poll + session info ────────────
// Mounted at /api/public — completely separate from /api/payments
// so the protected payments router NEVER intercepts these.
app.use('/api/public',  require('./routes/public'));

// Public programmatic API (x-api-key auth, not JWT)
app.use('/api/pay',     require('./routes/pay'));

// ══════════════════════════════════════════════════════════
// PROTECTED ROUTES — JWT required
// ══════════════════════════════════════════════════════════
app.use('/api/merchants', authMiddleware, require('./routes/merchants'));
app.use('/api/payments',  authMiddleware, require('./routes/payments'));
app.use('/api/release',   authMiddleware, require('./routes/release'));
app.use('/api/webhooks',  authMiddleware, require('./routes/webhooks'));
app.use('/api/apikeys',   authMiddleware, require('./routes/apikeys'));

// ── Catch-all → frontend SPA ───────────────────────────────
app.get('*', (req, res) =>
  res.sendFile(path.join(__dirname, '../../frontend', 'index.html'))
);

// ── Error handler ──────────────────────────────────────────
app.use((err, req, res, next) => {
  console.error('[ERROR]', err.stack || err.message);
  res.status(err.status || 500).json({ error: err.message || 'Internal server error' });
});

app.listen(PORT, () => {
  console.log(`\n[SETTL] ▶  http://localhost:${PORT}`);
  console.log(`[SETTL] Trust proxy: enabled`);
  console.log(`[SETTL] Poll endpoint: /api/public/poll/:ref (public)`);
  startCron();
});

module.exports = app;
