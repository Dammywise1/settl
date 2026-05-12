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

app.set('trust proxy', 1);
app.use(helmet({ contentSecurityPolicy: false }));
app.use(cors());
app.use(express.json());
app.use(morgan('dev'));

// Static frontend
app.use(express.static(path.join(__dirname, '../../frontend')));

// ── Public routes ──────────────────────────────────────────
app.use('/api/health',  require('./routes/health'));
app.use('/api/auth',    require('./routes/auth'));
app.use('/api/public',  require('./routes/public'));
app.use('/api/pay',     require('./routes/pay'));

// ── Reusable link redirect ─────────────────────────────────
// /pay/:slug → serves the checkout page
// Frontend JS calls /api/public/link/:slug to get/create session
app.get('/pay/:slug', (req, res) => {
  res.sendFile(path.join(__dirname, '../../frontend', 'pages', 'pay-link.html'));
});

// ── Protected routes ───────────────────────────────────────
app.use('/api/merchants', authMiddleware, require('./routes/merchants'));
app.use('/api/payments',  authMiddleware, require('./routes/payments'));
app.use('/api/release',   authMiddleware, require('./routes/release'));
app.use('/api/webhooks',  authMiddleware, require('./routes/webhooks'));
app.use('/api/apikeys',   authMiddleware, require('./routes/apikeys'));
app.use('/api/links',     authMiddleware, require('./routes/paymentLinks'));

// Catch-all → frontend
app.get('*', (req, res) =>
  res.sendFile(path.join(__dirname, '../../frontend', 'index.html'))
);

app.use((err, req, res, next) => {
  console.error('[ERROR]', err.stack || err.message);
  res.status(err.status || 500).json({ error: err.message || 'Internal server error' });
});

app.listen(PORT, () => {
  console.log(`\n[SETTL] ▶  http://localhost:${PORT}`);
  console.log(`[SETTL] Trust proxy: enabled`);
  startCron();
});
module.exports = app;
