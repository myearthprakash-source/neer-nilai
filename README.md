# Neer Nilai — GLR-level water supply monitoring

Made by Catalyx Technology.

A daily Yes / Partial / No report from every GLR (ground level reservoir) in a panchayat, reviewed by the panchayat officer, with automatic alerts to block and district officers when supply fails or a GLR goes silent.

## Hierarchy and roles

```
District → Block → Village Panchayat → Habitation → GLR
```

One habitation can have several GLRs. Every level is a table row, so adding or renaming a level (for example a Ward between Panchayat and Habitation) is a data change, not a code change.

| Role | Page | Sign-in | What they do |
|---|---|---|---|
| GLR operator (pump operator / valve man) | https://myearthprakash-source.github.io/neer-nilai/ | GLR code + 4-digit PIN, remembered on the phone (demo PIN 1234) | Enters the daily report for each GLR they look after |
| Panchayat officer (reviewer) | https://myearthprakash-source.github.io/neer-nilai/review/ | Official email; magic link in live mode, access code 1234 in demo | Confirms or flags each GLR report for their panchayat, adds a note |
| Block / district officer | https://myearthprakash-source.github.io/neer-nilai/officer/ | Official email; magic link in live mode, access code 1234 in demo | Dashboard: counts, alerts, per-GLR table with review status |

The three pages never link to each other. In live mode the database enforces the split: operator functions accept only a valid GLR code + PIN, and every officer sees only the GLRs inside their panchayat, block or district (row-level security).

## The daily report (operator)

1. Pick the GLR (the phone can hold several; tap **+ Another GLR** to add one). The card shows the scheme flow (for example *Open well → 7.5 HP pump → 15,000 L GLR → gravity*) and the normal supply window.
2. **Was normal water supply provided today?** Yes (normal) / Partial (less than normal) / No (not supplied).
3. For Partial or No, the **Problem details** section opens:
   - Was sufficient water available in the source? Yes / No / Don't know
   - Did the pump operate normally? Yes / No / Don't know
   - Was the GLR adequately filled? Yes / No / Don't know
   - What appears to be the problem? Source insufficient · Electricity · Pump · Source-to-GLR pipeline · GLR · Distribution pipeline / valve · Don't know · Other
   - Action taken / remarks
4. Submit. One report per GLR per day; it can be corrected the same day, which resets the review to pending.

Tamil is the default language, English is one tap away. Reports queue offline and send when signal returns.

## Review and alerts

| Event | Who is alerted |
|---|---|
| Partial supply | Panchayat officer, immediately |
| No supply | Panchayat officer + block officer, immediately |
| Problem on 2 consecutive days | District officer added |
| No report by 12:00 | In the noon digest to everyone in scope |

The panchayat officer opens the review page, sees every GLR in the panchayat (including silent ones), and taps **Confirm** or **Flag as incorrect** with an optional note. The review status shows on the block/district dashboard and in the digest.

Channels: in-app dashboard and email are free; WhatsApp Cloud API utility messages cost about ₹0.12 each; SMS is optional (DLT registration, about ₹0.20 each).

## Stack and cost

| Layer | Choice | Cost |
|---|---|---|
| App | Installable web app (PWA), single source for all three pages, works offline | ₹0 |
| Hosting | GitHub Pages (or Cloudflare Pages) | ₹0 |
| Database + API + auth | Supabase (Postgres, row-level security, magic-link email login, edge functions, cron) | ₹0 for a district pilot, about ₹2,100/month (Pro) statewide |
| Alerts | Resend email (3,000/month free), WhatsApp Cloud API | ₹0 to a few hundred ₹/month |

Scale: about 12,500 village panchayats in Tamil Nadu, several GLRs each, one row per GLR per day. Roughly 30 to 50 million rows a year statewide, a few GB, within Supabase Pro for years.

## Mobile app: install and distribution

1. **Android, no store (recommended for the pilot)**: open the link in Chrome, tap **Install app** in the top bar (or Chrome menu, *Add to Home screen*). Icon, full screen, works offline, updates itself.
2. **Android APK / Play Store**: https://www.pwabuilder.com, paste the operator URL, choose *Android*, *Generate package*. It produces a signed `.apk` (share on WhatsApp for sideloading) and an `.aab` for Play Store. Copy the generated `assetlinks.json` to `docs/.well-known/assetlinks.json` and push. Play Store needs a one-time developer account (about ₹2,000).
3. **iPhone**: Safari, Share, *Add to Home Screen*.

## Repository layout

```
src/app.html                        Single source for all three pages (role fixed by URL)
src/sw.js, src/icon.html            Service worker template, app icon source
build.js                            Generates docs/ from src/   →  node build.js
docs/                               Published site: index.html, review/, officer/, sw.js, icons/
supabase/schema.sql                 Tables (5-level hierarchy), RPCs, review, RLS, view, sample data
supabase/functions/notify/index.ts  Edge function: alerts on Partial / No, noon digest
```

## Go-live steps

1. Create a free Supabase project (Mumbai region). Run `supabase/schema.sql` in the SQL editor.
2. Deploy the notify function: `supabase functions deploy notify`. Set secrets `RESEND_API_KEY`, `FROM_EMAIL`, optionally `WA_TOKEN`, `WA_PHONE_ID`, and `APP_URL`.
3. Database → Webhooks: table `reports`, events INSERT and UPDATE, target the `notify` function URL. Optionally schedule the noon digest with the pg_cron snippet at the end of `schema.sql`.
4. In `src/app.html`, fill in `CONFIG.SUPABASE_URL` and `CONFIG.SUPABASE_ANON_KEY`, run `node build.js`, push. GitHub Pages serves `docs/`.
5. Load districts, blocks, panchayats, habitations and GLRs (CSV import). Set each GLR's PIN: `select set_glr_pin('NLG-UDH-KKL-01','4821');`. Print a card per GLR with the QR link, code and PIN.
6. Add staff: create the user by email in Supabase Auth, then insert a row in `officers` with role (`panchayat`, `block`, `district`, `state`) and the matching id.

Without `CONFIG` filled in, the site runs in demo mode with Nilgiris sample data stored on the phone, which is what the public links show.
