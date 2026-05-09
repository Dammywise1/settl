require('dotenv').config();
const express   = require('express');
const cors      = require('cors');
const helmet    = require('helmet');
const morgan    = require('morgan');
const rateLimit = require('express-rate-limit');

const authMiddleware   = require('./middleware/auth');
const merchantRoutes   = require('./routes/merchants');
const escrowRoutes     = require('./routes/escrow');
const authRoutes       = require('./routes/auth');
const healthRoutes     = require('./routes/health');

const app  = express();
const PORT = process.env.PORT || 3000;

app.use(helmet());
app.use(cors({ origin: process.env.FRONTEND_URL || 'http://localhost:5500', credentials: true }));
app.use(express.json());
app.use(morgan('dev'));

const limiter = rateLimit({ windowMs: 15 * 60 * 1000, max: 100 });
app.use('/api/', limiter);

app.use('/api/health',    healthRoutes);
app.use('/api/auth',      authRoutes);
app.use('/api/merchants', authMiddleware, merchantRoutes);
app.use('/api/escrow',    authMiddleware, escrowRoutes);

app.use((req, res) => res.status(404).json({ error: 'Route not found' }));
app.use((err, req, res, next) => {
  console.error('[ERROR]', err.message);
  res.status(err.status || 500).json({ error: err.message || 'Internal server error' });
});

app.listen(PORT, () => {
  console.log(`[SETTL] Backend running on http://localhost:${PORT}`);
  console.log(`[SETTL] Program ID: ${process.env.SETTL_PROGRAM_ID}`);
});

module.exports = app;
