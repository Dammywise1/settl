const { validateKey } = require('../services/apiKey');

async function apiKeyMiddleware(req, res, next) {
  const key = req.headers['x-api-key'];
  if (!key) return res.status(401).json({ error: 'Missing x-api-key header' });

  const keyRecord = await validateKey(key);
  if (!keyRecord) return res.status(401).json({ error: 'Invalid or revoked API key' });
  if (!keyRecord.merchants?.is_active) {
    return res.status(403).json({ error: 'Merchant account is not active' });
  }

  req.apiKey   = keyRecord;
  req.merchant = keyRecord.merchants;
  next();
}

module.exports = apiKeyMiddleware;
