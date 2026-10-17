# Neer Nilai — tank-level water supply monitoring

Made by Catalyx Technology.

A daily Yes / Partial / No report from every water tank in a panchayat — GLRs (ground level reservoirs) and OHTs (overhead tanks) — reviewed by the panchayat officer, with automatic alerts to block and district officers when supply fails or an operator goes silent.

## Hierarchy and roles

```
District → Block → Village Panchayat → Habitation → Tank (GLR or OHT)
```

One habitation can have several tanks of either kind. A habitation supplied by another body (for example Singara, supplied by TNEB) has no tanks and carries a supply note instead, so the review page and dashboard say why nothing is reported there. Every level is a table row, so adding or renaming a level (for example a Ward between Panchayat and Habitation) is a data change, not a code change.

| Role | Page | Sign-in | What they do |
|---|---|---|---|
| Pump operator | https://myearthprakash-source.github.io/neer-nilai/ | Registered mobile number + 4-digit PIN, one phone per operator (demo: pick an operator, PIN 1234) | Enters the daily report for each tank they look after |
| Panchayat officer (reviewer) | https://myearthprakash-source.github.io/neer-nilai/review/ | Official email; magic link in live mode, access code 1234 in demo (pick Kookal or Masinagudi) | Confirms or flags each tank report for their panchayat, adds a note, records for a silent operator after a call |
| Block / district officer | https://myearthprakash-source.github.io/neer-nilai/officer/ | Official email; magic link in live mode, access code 1234 in demo | Dashboard: counts, alerts, per-tank table with review status |

The three pages never link to each other. In live mode the database enforces the split: operator functions accept only a registered mobile number + PIN from the bound phone, and every officer sees only the tanks inside their panchayat, block or district (row-level security).

## Who can report: registered operators only

The block's tank sheet lists, for every habitation, the pump operator who will use the app and their mobile number. That list is the access control:

- **Sign-in is mobile number + 4-digit PIN.** The number must already be in the operators table. The panchayat officer sets the PIN from the review page and tells the operator in person or by phone. No SMS, no OTP cost, no DLT registration, nothing to print.
- **One phone per operator.** The first sign-in binds the phone. A second phone is refused until the panchayat officer taps *Reset phone*. A lost phone is fixed the same way. Two people sharing one phone (the sheet's "Maran / Badichi") are one account.
- **Every report is tagged** with the operator and the phone it came from, and the panchayat officer confirms or flags it.
- **Sending the app link**: the review page has a *Send app link on WhatsApp* button per operator, which opens WhatsApp on the officer's own phone with the link and a one-line Tamil instruction.

Real phone numbers never go into this public repo: `schema.sql` seeds 90000000xx placeholders, and the real numbers live in `supabase/private/operator-phones.sql`, which is git-ignored and run only against the live database.

## The daily report (operator): one tap on a normal day, nothing to type

1. **One question, three big colour buttons:** *Did water come to all tanks today?* Green "water came" saves every tank not yet reported. Amber "came less" or red "water did not come" go to one more screen.
2. **Six picture tiles:** no electricity · motor broken · pipe broken · no water in source · tank not filled · don't know. Tap one and the report is saved.
3. **One tank different?** Under the buttons is a grid of the operator's tanks, each with a GLR or OHT picture and today's colour dot. Tap the one that had a problem, answer for it alone, and the big buttons then cover the rest. An operator with 12 tanks (Sidick Shameer, Masinagudi: 4 GLR + 8 OHT) still finishes a normal day in one tap.
4. **Done screen** with a big tick, counts per status and, for a problem, one mic button to leave a 20-second voice note in Tamil instead of typing.

The detailed questions the officer asked for (source sufficient? pump ran? tank filled? action taken) are answered by the **panchayat officer at review time**, who can judge them and can call the operator.

Tamil is the default language. The app is light-themed on every phone (readable outdoors; a phone in dark mode does not change it). Reports queue offline and send when signal returns. One report per tank per day; a same-day correction resets the review to pending.

## Review and alerts

| Event | Who is alerted |
|---|---|
| Partial supply | Panchayat officer, immediately |
| No supply | Panchayat officer + block officer, immediately |
| Problem on 2 consecutive days | District officer added |
| No report by 12:00 | In the noon digest to everyone in scope, grouped per operator |

The panchayat officer opens the review page, sees problems first, then silent operators, then normal tanks. Each problem gets **Confirm** or **Flag as incorrect** with diagnostics and a note. A silent operator is one card (all their unreported tanks) with **Call**, **All normal** (after the call) and **Tank by tank**. The review status shows on the block/district dashboard and in the digest; the dashboard also lists silence once per operator, not once per tank.

Channels: in-app dashboard and email are free; WhatsApp Cloud API utility messages cost about ₹0.12 each; SMS is optional (DLT registration, about ₹0.20 each).

## Stack and cost

| Layer | Choice | Cost |
|---|---|---|
| App | Installable web app (PWA), single source for all three pages, works offline | ₹0 |
| Hosting | GitHub Pages (or Cloudflare Pages) | ₹0 |
| Database + API + auth | Supabase (Postgres, row-level security, magic-link email login, edge functions, cron) | ₹0 for a district pilot, about ₹2,100/month (Pro) statewide |
| Alerts | Resend email (3,000/month free), WhatsApp Cloud API | ₹0 to a few hundred ₹/month |

Scale: about 12,500 village panchayats in Tamil Nadu, around 10 to 20 tanks each (Masinagudi has 21), one row per tank per day. Roughly 50 to 90 million rows a year statewide, a few GB, within Supabase Pro for years.

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
supabase/schema.sql                 Tables (5-level hierarchy, tank kind GLR/OHT), RPCs, review, RLS, views, pilot data
supabase/functions/notify/index.ts  Edge function: alerts on Partial / No, noon digest
supabase/private/                   Git-ignored: real operator phone numbers for the live database
```

## Go-live steps

1. Create a free Supabase project (Mumbai region). Run `supabase/schema.sql` in the SQL editor, then `supabase/private/operator-phones.sql` for the real numbers.
2. Deploy the notify function: `supabase functions deploy notify`. Set secrets `RESEND_API_KEY`, `FROM_EMAIL`, optionally `WA_TOKEN`, `WA_PHONE_ID`, and `APP_URL`.
3. Database → Webhooks: table `reports`, events INSERT and UPDATE, target the `notify` function URL. Optionally schedule the noon digest with the pg_cron snippet at the end of `schema.sql`.
4. In `src/app.html`, fill in `CONFIG.SUPABASE_URL` and `CONFIG.SUPABASE_ANON_KEY`, run `node build.js`, push. GitHub Pages serves `docs/`.
5. Load further districts, blocks, panchayats, habitations (with `supply_note` where another body supplies water), operators and tanks (`glrs` table, `kind` = `GLR` or `OHT`) by CSV import. The Kookal and Masinagudi pilot rows are already in `schema.sql`. The panchayat officer then sets each operator's PIN from the review page and sends the app link on WhatsApp.
6. Add staff: create the user by email in Supabase Auth, then insert a row in `officers` with role (`panchayat`, `block`, `district`, `state`) and the matching id.

Without `CONFIG` filled in, the site runs in demo mode with Nilgiris sample data (Kookal, Udhagai block; Masinagudi, Gudalur block) stored on the phone, which is what the public links show.
