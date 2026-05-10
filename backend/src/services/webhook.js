const crypto   = require('crypto');
const { supabase } = require('../config/supabase');

// ── sign ──────────────────────────────────────────────────
// HMAC-SHA256 signature so merchants can verify the request
function sign(payload, secret) {
  return crypto
    .createHmac('sha256', secret)
    .update(typeof payload === 'string' ? payload : JSON.stringify(payload))
    .digest('hex');
}

// ── dispatch ──────────────────────────────────────────────
// Fire all active webhooks for a merchant + event type.
// Non-blocking — called with .catch() so it never blocks the caller.
async function dispatch(merchantId, event, data) {
  try {
    const { data: webhooks, error } = await supabase
      .from('webhook_configs')
      .select('id, url, secret')
      .eq('merchant_id', merchantId)
      .eq('is_active', true)
      .contains('events', [event]);

    if (error || !webhooks?.length) return;

    for (const wh of webhooks) {
      await deliverWebhook(wh, merchantId, event, data, 1);
    }
  } catch (err) {
    console.error('[webhook] dispatch error:', err.message);
  }
}

// ── deliverWebhook ────────────────────────────────────────
// Single delivery attempt. Retries up to 3 times with
// exponential backoff (1s, 3s, 9s).
async function deliverWebhook(webhook, merchantId, event, data, attempt) {
  const payload = {
    event,
    merchant_id: merchantId,
    timestamp:   new Date().toISOString(),
    data,
  };

  const body      = JSON.stringify(payload);
  const signature = sign(body, webhook.secret);

  // Log the attempt
  const { data: delivery } = await supabase
    .from('webhook_deliveries')
    .insert({
      webhook_id:  webhook.id,
      merchant_id: merchantId,
      event,
      payload,
      attempt,
      status: 'pending',
    })
    .select()
    .single();

  const deliveryId = delivery?.id;

  try {
    const controller = new AbortController();
    const timeout    = setTimeout(() => controller.abort(), 10_000); // 10s timeout

    const res = await fetch(webhook.url, {
      method:  'POST',
      headers: {
        'Content-Type':       'application/json',
        'X-SETTL-Signature':  `sha256=${signature}`,
        'X-SETTL-Event':      event,
        'X-SETTL-Delivery':   deliveryId || '',
        'User-Agent':         'SETTL-Webhooks/1.0',
      },
      body,
      signal: controller.signal,
    });

    clearTimeout(timeout);

    const responseBody = await res.text().catch(() => '');
    const success      = res.status >= 200 && res.status < 300;

    if (deliveryId) {
      await supabase.from('webhook_deliveries').update({
        status:        success ? 'success' : 'failed',
        response_code: res.status,
        response_body: responseBody.slice(0, 500),
        delivered_at:  success ? new Date().toISOString() : null,
        error:         success ? null : `HTTP ${res.status}`,
      }).eq('id', deliveryId);
    }

    if (!success && attempt < 3) {
      // Exponential backoff: 1s, 3s, 9s
      const delay = Math.pow(3, attempt) * 1000;
      console.log(`[webhook] Retry ${attempt+1} for ${webhook.url} in ${delay}ms`);
      setTimeout(() => deliverWebhook(webhook, merchantId, event, data, attempt + 1), delay);
    } else if (!success) {
      console.error(`[webhook] Failed after 3 attempts: ${webhook.url}`);
    } else {
      console.log(`[webhook] Delivered ${event} to ${webhook.url}`);
    }

  } catch (err) {
    console.error(`[webhook] Request error (attempt ${attempt}):`, err.message);
    if (deliveryId) {
      await supabase.from('webhook_deliveries').update({
        status: attempt < 3 ? 'retrying' : 'failed',
        error:  err.message,
      }).eq('id', deliveryId);
    }
    if (attempt < 3) {
      const delay = Math.pow(3, attempt) * 1000;
      setTimeout(() => deliverWebhook(webhook, merchantId, event, data, attempt + 1), delay);
    }
  }
}

// ── verifySignature ───────────────────────────────────────
// For merchants to verify incoming webhooks in their own code
// (also used in our test endpoint)
function verifySignature(body, signature, secret) {
  const expected = `sha256=${sign(body, secret)}`;
  try {
    return crypto.timingSafeEqual(
      Buffer.from(signature),
      Buffer.from(expected)
    );
  } catch { return false; }
}

module.exports = { dispatch, verifySignature, sign };
