require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const express   = require('express');
const cors      = require('cors');
const helmet    = require('helmet');
const morgan    = require('morgan');
const rateLimit = require('express-rate-limit');
const path      = require('path');

const authMiddleware = require('./middleware/auth');
const { startCron }  = require('./cron/dailyRelease');

const app  = express();
const PORT = process.env.PORT || 3000;

app.use(helmet({ contentSecurityPolicy: false }));
app.use(cors());
app.use(express.json());
app.use(morgan('dev'));

// Static frontend
app.use(express.static(path.join(__dirname, '../../frontend')));

// Rate limit
app.use('/api/', rateLimit({ windowMs: 15 * 60 * 1000, max: 200 }));

// ── Public routes (no auth) ───────────────────────────────
app.use('/api/auth',    require('./routes/auth'));
app.use('/api/health',  require('./routes/health'));

// Public payment polling + checkout session loading
const paymentsRouter = require('./routes/payments');
app.get('/api/payments/poll/:ref',    paymentsRouter);
app.get('/api/payments/session/:ref', paymentsRouter);

// ── Protected routes ──────────────────────────────────────
app.use('/api/merchants', authMiddleware, require('./routes/merchants'));
app.use('/api/payments',  authMiddleware, paymentsRouter);
app.use('/api/release',   authMiddleware, require('./routes/release'));

// Catch-all → frontend SPA
app.get('*', (req, res) =>
  res.sendFile(path.join(__dirname, '../../frontend', 'index.html'))
);

app.use((err, req, res, next) => {
  console.error('[ERROR]', err.message);
  res.status(err.status || 500).json({ error: err.message || 'Internal server error' });
});

app.listen(PORT, () => {
  console.log(`\n[SETTL] ▶  http://localhost:${PORT}`);
  startCron();
});
module.exports = app;
