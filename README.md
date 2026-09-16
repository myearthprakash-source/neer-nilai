# Neer Nilai — Panchayat water delivery monitoring

Made by Catalyx Technology.

A daily Yes / Partial / No report from every panchayat tank, with automatic alerts to block and district officers when water is not delivered or when a panchayat goes silent.

## Recommended approach (decided)

| Layer | Choice | Why | Cost |
|---|---|---|---|
| Operator app | Installable web app (PWA), Tamil + English, works offline | No Play Store, no APK updates, runs on any Android phone via a link or QR. Reports queue offline and send when signal returns. | ₹0 |
| Hosting | Cloudflare Pages (or GitHub Pages) | Static files, free, unlimited traffic | ₹0 |
| Database + API | Supabase (Postgres) | Free tier covers a district pilot; Pro tier covers all 12,500+ village panchayats statewide | ₹0 pilot, ~₹2,100/month statewide |
| Operator login | Panchayat code + 4-digit PIN, remembered on the device | No SMS OTP cost, no accounts to manage. One PIN per panchayat, reset by the block office. | ₹0 |
| Officer login | Email magic link | Officers are few; no passwords to forget | ₹0 |
| Alerts | In-app dashboard + email (free) → WhatsApp (cheap) → SMS (optional) | Email and dashboard are free. WhatsApp Cloud API utility messages cost about ₹0.12 each and are what TN officers actually read. SMS needs DLT registration and costs ~₹0.20 each; add only if demanded. | ₹0 to a few hundred ₹/month |
| Scheduled digest | Supabase pg_cron + Edge Function | "No report by noon" is itself an alert. | ₹0 |

### Why not the alternatives

- **Google Forms + Sheets**: no identity per panchayat, duplicate entries, no offline queue, Sheets slows badly past a few hundred thousand rows, alerts need Apps Script hacks.
- **Native Android app**: Play Store review, forced updates, and a developer account. A PWA gives the same home-screen icon.
- **No-code builders (Glide, AppSheet, Zoho Creator)**: per-user pricing that explodes at thousands of operators.

## How it works

1. **Operator** (pump operator / panchayat secretary) opens the app on the phone after the tank fills, taps **Yes** (normal supply), **Partial** (limited supply) or **No** (no supply). For Partial or No, the reason box opens (no power, motor failure, pipe burst, source dry, low pressure, tanker didn't arrive, operator absent, other), adds an optional comment, taps Save. One report per panchayat per day; can be corrected the same day.
2. **Database** stores one row per panchayat per day. A webhook fires on every "No" or "Partial".
3. **Notify function** finds the block and district officers for that panchayat and sends email + WhatsApp. Everything sent is logged.
4. **Noon digest** (pg_cron, 12:00 IST) sends each block officer the list of panchayats that reported No and those that have not reported at all. District officers get the roll-up.
5. **Officer dashboard** shows today's counts, the alert feed, and a per-block table with filters. Works on phone and desktop.

### Escalation rules (configurable in SQL, no code)

| Event | Who is alerted |
|---|---|
| "No" or "Partial" reported | Block officer (BDO / AE), immediately |
| Problem on 2 consecutive days | District officer added |
| No report by 12:00 | Block officer in noon digest |
| No report for 3 days | District officer in digest |

## Scale check

- Tamil Nadu: ~12,500 village panchayats. One report each per day ≈ 4.6 million rows/year, roughly 700 MB/year with indexes.
- Supabase free tier: 500 MB database, 500k edge function calls/month. Enough for a full district pilot for a year.
- Supabase Pro ($25/month): 8 GB database. Enough for statewide for several years; archive old years to cold storage after that.
- Cloudflare Pages: no limits that matter here.

## Rollout plan

1. **Week 1–2**: Pilot in one block (30–50 panchayats). Print a QR + panchayat code + PIN card for each tank operator.
2. **Week 3–4**: Whole district. Enable WhatsApp alerts for BDOs.
3. **Month 2+**: Add districts on request. Supabase Pro when the database passes 400 MB.

## Roles and access

Operators and officers use different pages and never see each other's screens.

| Who | URL | Sign-in |
|---|---|---|
| Tank operator | https://myearthprakash-source.github.io/neer-nilai/ | Panchayat code + 4-digit PIN (demo: any code, PIN 1234) |
| Block / district officer | https://myearthprakash-source.github.io/neer-nilai/officer/ | Official email; live mode sends a magic link, demo uses access code 1234 |

In live mode the database enforces this too: operator functions only accept a valid code + PIN, and officers only see reports inside their block or district (row-level security).

## Mobile app: install and distribution

The site is a Progressive Web App (manifest + service worker + icons), so it installs like a normal app:

1. **Android, no store (recommended for the pilot)**: open the link in Chrome, tap **Install app** in the top bar (or Chrome menu, *Add to Home screen*). It gets an icon, opens full screen, and works offline. Free, no approval, updates itself.
2. **Android APK / Play Store**: go to https://www.pwabuilder.com, paste the operator URL, choose *Android*, *Generate package*. It produces a signed `.apk` (share directly on WhatsApp for sideloading) and an `.aab` for Play Store. Copy the generated `assetlinks.json` to `docs/.well-known/assetlinks.json` and push, so the app opens without the browser bar. Play Store needs a one-time developer account (about ₹2,000) and a listing review.
3. **iPhone**: Safari, Share, *Add to Home Screen*. Officers on iPhone use this; operators are almost all on Android.

Build the site after any change to `src/app.html`:

```
node build.js
```

## Repository layout

```
docs/index.html                      Operator app + officer dashboard (single file, PWA)
supabase/schema.sql                 Tables, row-level security, submit RPC, trigger, cron
supabase/functions/notify/index.ts  Edge function: alerts on "No", noon digest
```

## Go-live steps

1. Create a free Supabase project (Mumbai region). Run `supabase/schema.sql` in the SQL editor.
2. Deploy the notify function: `supabase functions deploy notify`. Set secrets: `RESEND_API_KEY` (email, free 3,000/month), optionally `WA_TOKEN`, `WA_PHONE_ID` (WhatsApp Cloud API).
3. Create a Database Webhook in Supabase: table `reports`, events INSERT and UPDATE, target the `notify` function URL.
4. In `src/app.html`, fill in `CONFIG.SUPABASE_URL` and `CONFIG.SUPABASE_ANON_KEY`, run `node build.js`, push. GitHub Pages serves `docs/`.
5. Load districts, blocks, panchayats from the TN Rural Development master list (CSV import in Supabase). Set PINs with `select set_panchayat_pin('VPM-TDV-001','4821');`.
6. Add officers: create the user by email in Supabase Auth, then insert a row in `officers` with role and district/block.

Without `CONFIG` filled in, the web app runs in demo mode with sample data stored on the phone, which is what the prototype link shows.
