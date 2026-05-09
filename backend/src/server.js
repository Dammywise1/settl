require('./config/env');
const express = require('express');
const cors = require('cors');
const helmet = require('helmet');
const morgan = require('morgan');
const rateLimit = require('express-rate-limit');
const path = require('path');

const customAuthMiddleware = require('./middleware/customAuth');
const merchantRoutes = require('./routes/merchants');
const escrowRoutes = require('./routes/escrow');
const authRoutes = require('./routes/auth');
const healthRoutes = require('./routes/health');
const paymentRoutes = require('./routes/payments');
const releaseRoutes = require('./routes/releases');

// Start cron job
require('./cron/dailyRelease');

const app = express();
const PORT = process.env.PORT || 3000;

app.set('trust proxy', 1);

app.use(helmet({ contentSecurityPolicy: false }));
app.use(cors());
app.use(express.json());
app.use(morgan('dev'));

// Serve frontend
const frontendPath = path.join(__dirname, '../../frontend');
app.use(express.static(frontendPath));

// Rate limiting
const limiter = rateLimit({ windowMs: 15 * 60 * 1000, max: 100 });
app.use('/api/', limiter);

// API Routes
app.use('/api/health', healthRoutes);
app.use('/api/auth', authRoutes);
app.use('/api/merchants', customAuthMiddleware, merchantRoutes);
app.use('/api/escrow', customAuthMiddleware, escrowRoutes);
app.use('/api/payments', paymentRoutes); // Public
app.use('/api/releases', customAuthMiddleware, releaseRoutes);

// Catch-all for frontend
app.get('*', (req, res) => {
  res.sendFile(path.join(frontendPath, 'index.html'));
});

app.listen(PORT, () => {
  console.log(`[SETTL] Server running on http://localhost:${PORT}`);
  console.log(`[SETTL] Custom auth enabled - no Supabase Auth`);
});

module.exports = app;
