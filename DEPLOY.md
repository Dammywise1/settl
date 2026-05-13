# SETTL — Railway Deployment Guide

## Prerequisites

- Railway account (railway.app)
- GitHub account with SETTL repo pushed
- Supabase project running
- Solana authority keypair (keypair.json)

---

## Step 1 — Prepare your keypair for Railway

Railway can't read files from your filesystem. Encode your keypair as base64:

```bash
# Run this in your terminal (not on Railway)
base64 -w 0 backend/keypair.json
# On macOS:
base64 -i backend/keypair.json
```

Copy the output — you'll paste it as `AUTHORITY_KEYPAIR_BASE64` in Railway.

---

## Step 2 — Push to GitHub

```bash
cd settl

# Initialise git if not already done
git init
git add .
git commit -m "Initial SETTL deployment"

# Create a new repo on GitHub, then:
git remote add origin https://github.com/YOUR_USERNAME/settl.git
git push -u origin main
```

Make sure `.gitignore` is in place before pushing — never commit `.env` or `keypair.json`.

---

## Step 3 — Create Railway project

1. Go to [railway.app](https://railway.app)
2. Click **New Project**
3. Select **Deploy from GitHub repo**
4. Choose your `settl` repository
5. Railway detects the `Dockerfile` automatically

---

## Step 4 — Set environment variables

In Railway Dashboard → your project → **Variables**, add:

| Variable | Value |
|---|---|
| `NODE_ENV` | `production` |
| `APP_URL` | Leave blank for now — set after first deploy |
| `SUPABASE_URL` | Your Supabase project URL |
| `SUPABASE_SERVICE_ROLE_KEY` | Your Supabase service role key |
| `SUPABASE_ANON_KEY` | Your Supabase anon key |
| `JWT_SECRET` | Run `openssl rand -hex 32` and paste output |
| `SOLANA_RPC_URL` | `https://api.devnet.solana.com` |
| `SETTL_PROGRAM_ID` | `RZgHzaU8jKm4ydzwkmoooqd2TNek4L9W4o8tthekeLn` |
| `AUDD_MINT` | Your AUDD mint address |
| `TREASURY_WALLET` | Your treasury wallet public key |
| `AUTHORITY_KEYPAIR_BASE64` | Output of the base64 command above |
| `WEBHOOK_SECRET` | Run `openssl rand -hex 32` and paste output |

**Do NOT set `PORT`** — Railway sets it automatically.

---

## Step 5 — Deploy

Railway auto-deploys when you push to GitHub. For the first deploy:

1. Click **Deploy** in the Railway dashboard
2. Watch the build logs — should take 2–3 minutes
3. Once deployed, click the generated domain (e.g. `settl-production-xxxx.up.railway.app`)

---

## Step 6 — Set APP_URL

After deploy, you'll have a Railway URL. Set it:

1. Railway Dashboard → Variables → Add `APP_URL`
2. Value: `https://your-app.up.railway.app`
3. Railway auto-redeploys

This makes payment links use your real domain instead of localhost.

---

## Step 7 — Add custom domain (optional)

1. Railway Dashboard → Settings → Domains
2. Add your domain (e.g. `pay.yoursite.com`)
3. Add the CNAME record Railway gives you to your DNS provider
4. Update `APP_URL` to `https://pay.yoursite.com`

---

## Verify deployment

```bash
# Health check
curl https://your-app.up.railway.app/api/health

# Should return:
# {"status":"ok","db":"ok","ts":"..."}
```

---

## Redeploying after code changes

```bash
git add .
git commit -m "your change"
git push
# Railway auto-deploys in ~2 minutes
```

---

## Troubleshooting

**Build fails**
- Check Railway build logs
- Make sure all files in Dockerfile COPY paths exist

**App crashes on start**
- Check Railway deploy logs
- Most common: missing environment variable
- Check `AUTHORITY_KEYPAIR_BASE64` is correctly encoded

**Payments not confirming**
- Check `SOLANA_RPC_URL` is set correctly
- Devnet: `https://api.devnet.solana.com`
- Mainnet: `https://api.mainnet-beta.solana.com`

**Database errors**
- Verify `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` are correct
- Check Supabase migrations have been run

