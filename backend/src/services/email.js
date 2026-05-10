let _transporter = null;

function getTransporter() {
  if (_transporter) return _transporter;
  if (!process.env.SMTP_HOST) return null;

  const nodemailer = require('nodemailer');
  _transporter = nodemailer.createTransport({
    host:   process.env.SMTP_HOST,
    port:   parseInt(process.env.SMTP_PORT || '587'),
    secure: process.env.SMTP_PORT === '465',
    auth: {
      user: process.env.SMTP_USER,
      pass: process.env.SMTP_PASS,
    },
  });
  return _transporter;
}

// ── send ──────────────────────────────────────────────────
async function send({ to, subject, html, text }) {
  const t = getTransporter();
  if (!t) return; // Email not configured — skip silently

  try {
    await t.sendMail({
      from:    process.env.EMAIL_FROM || 'SETTL <noreply@settl.app>',
      to,
      subject,
      html,
      text: text || html.replace(/<[^>]+>/g, ''),
    });
    console.log(`[email] Sent "${subject}" to ${to}`);
  } catch (err) {
    console.error('[email] Send failed:', err.message);
    // Never throw — email is non-critical
  }
}

// ── sendDepositConfirmed ──────────────────────────────────
async function sendDepositConfirmed({ email, merchantName, amount, txSignature, reference }) {
  const explorerUrl = `https://explorer.solana.com/tx/${txSignature}?cluster=devnet`;
  await send({
    to:      email,
    subject: `💰 Payment received — ${Number(amount).toFixed(2)} AUDD`,
    html: `
      <div style="font-family:sans-serif;max-width:480px;margin:0 auto;padding:24px;">
        <h2 style="color:#534AB7;margin-bottom:4px;">SETTL</h2>
        <p style="color:#6B7280;margin-bottom:24px;">Payment Gateway</p>
        <h3 style="margin-bottom:8px;">Payment confirmed ✓</h3>
        <p>A payment of <strong>${Number(amount).toFixed(2)} AUDD</strong> has been received into your escrow vault.</p>
        <div style="background:#F9FAFB;border:1px solid #E5E7EB;border-radius:8px;padding:16px;margin:16px 0;">
          <div style="font-size:13px;color:#6B7280;margin-bottom:4px;">Amount</div>
          <div style="font-size:24px;font-weight:700;color:#534AB7;">${Number(amount).toFixed(4)} AUDD</div>
        </div>
        <p style="font-size:13px;color:#6B7280;">
          Funds will be released to your wallet at 6am UTC.<br/>
          Reference: <code>${reference}</code>
        </p>
        <a href="${explorerUrl}" style="display:inline-block;margin-top:12px;color:#1D9E75;font-size:13px;">
          View on Solana Explorer →
        </a>
        <hr style="border:none;border-top:1px solid #E5E7EB;margin:24px 0;"/>
        <p style="font-size:11px;color:#9CA3AF;">SETTL Payment Gateway · Solana Devnet</p>
      </div>
    `,
  });
}

// ── sendReleaseCompleted ──────────────────────────────────
async function sendReleaseCompleted({ email, merchantName, gross, fee, net, txSignature }) {
  const explorerUrl = `https://explorer.solana.com/tx/${txSignature}?cluster=devnet`;
  await send({
    to:      email,
    subject: `✅ Release completed — ${Number(net).toFixed(2)} AUDD sent to your wallet`,
    html: `
      <div style="font-family:sans-serif;max-width:480px;margin:0 auto;padding:24px;">
        <h2 style="color:#534AB7;margin-bottom:4px;">SETTL</h2>
        <p style="color:#6B7280;margin-bottom:24px;">Payment Gateway</p>
        <h3 style="margin-bottom:8px;">Daily release completed ✓</h3>
        <p>Your escrow balance has been released to your wallet.</p>
        <div style="background:#F9FAFB;border:1px solid #E5E7EB;border-radius:8px;padding:16px;margin:16px 0;">
          <table style="width:100%;font-size:14px;">
            <tr><td style="color:#6B7280;padding:4px 0;">Gross collected</td><td style="text-align:right;font-weight:600;">${Number(gross).toFixed(4)} AUDD</td></tr>
            <tr><td style="color:#6B7280;padding:4px 0;">SETTL fee (1.5%)</td><td style="text-align:right;color:#D85A30;">-${Number(fee).toFixed(4)} AUDD</td></tr>
            <tr style="border-top:1px solid #E5E7EB;">
              <td style="padding:8px 0 4px;font-weight:600;">Net sent to wallet</td>
              <td style="text-align:right;font-size:18px;font-weight:700;color:#1D9E75;padding:8px 0 4px;">${Number(net).toFixed(4)} AUDD</td>
            </tr>
          </table>
        </div>
        <a href="${explorerUrl}" style="display:inline-block;margin-top:4px;color:#1D9E75;font-size:13px;">
          View transaction on Solana Explorer →
        </a>
        <hr style="border:none;border-top:1px solid #E5E7EB;margin:24px 0;"/>
        <p style="font-size:11px;color:#9CA3AF;">SETTL Payment Gateway · Solana Devnet</p>
      </div>
    `,
  });
}

module.exports = { send, sendDepositConfirmed, sendReleaseCompleted };
