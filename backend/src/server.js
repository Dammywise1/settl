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
const frontendPath = path.join(__dirname, '../../frontend');
app.use(express.static(frontendPath));

// Rate limit
app.use('/api/', rateLimit({ windowMs: 15 * 60 * 1000, max: 150 }));

// Public routes (no auth)
app.use('/api/health',   require('./routes/health'));
app.use('/api/auth',     require('./routes/auth'));

// Payments poll is public (customer-facing, no login)
app.use('/api/payments/poll', require('./routes/payments'));

// Protected routes
app.use('/api/merchants', authMiddleware, require('./routes/merchants'));
app.use('/api/escrow',    authMiddleware, require('./routes/escrow'));
app.use('/api/payments',  authMiddleware, require('./routes/payments'));
app.use('/api/release',   authMiddleware, require('./routes/release'));

// Catch-all → frontend
app.get('*', (req, res) => res.sendFile(path.join(frontendPath, 'index.html')));

// Error handler
app.use((err, req, res, next) => {
  console.error('[ERROR]', err.message);
  res.status(err.status || 500).json({ error: err.message || 'Internal server error' });
});

app.listen(PORT, () => {
  console.log(`\n[SETTL] ▶  http://localhost:${PORT}`);
  console.log(`[SETTL] Program: ${process.env.SETTL_PROGRAM_ID}`);
  startCron();
});

module.exports = app;
