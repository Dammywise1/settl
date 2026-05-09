const { supabase } = require('../config/supabase');

/**
 * Validates x-api-key header against the api_keys table.
 * Used for programmatic/developer access.
 * Attaches req.apiKeyRecord on success.
 */
async function apiKeyMiddleware(req, res, next) {
  const apiKey = req.headers['x-api-key'];
  if (!apiKey) {
    return res.status(401).json({ error: 'Missing x-api-key header' });
  }

  const { data, error } = await supabase
    .from('api_keys')
    .select('*, merchants(id, merchant_id, is_active)')
    .eq('key', apiKey)
    .eq('is_active', true)
    .single();

  if (error || !data) {
    return res.status(401).json({ error: 'Invalid or revoked API key' });
  }

  // Update last used timestamp (non-blocking)
  supabase
    .from('api_keys')
    .update({ last_used_at: new Date().toISOString() })
    .eq('id', data.id)
    .then(() => {});

  req.apiKeyRecord = data;
  next();
}

module.exports = apiKeyMiddleware;
