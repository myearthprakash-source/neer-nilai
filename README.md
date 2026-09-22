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
| GLR operator (pump operator) | https://myearthprakash-source.github.io/neer-nilai/ | Registered mobile number + 4-digit PIN, one phone per operator (demo: pick an operator, PIN 1234) | Enters the daily report for each GLR they look after |
| Panchayat officer (reviewer) | https://myearthprakash-source.github.io/neer-nilai/review/ | Official email; magic link in live mode, access code 1234 in demo | Confirms or flags each GLR report for their panchayat, adds a note |
| Block / district officer | https://myearthprakash-source.github.io/neer-nilai/officer/ | Official email; magic link in live mode, access code 1234 in demo | Dashboard: counts, alerts, per-GLR table with review status |

The three pages never link to each other. In live mode the database enforces the split: operator functions accept only a registered mobile number + PIN from the bound phone, and every officer sees only the GLRs inside their panchayat, block or district (row-level security).

## Who can report: registered operators only

The block's GLR sheet lists, for every habitation, the pump operator who will use the app and their mobile number. That list is the access control:

- **Sign-in is mobile number + 4-digit PIN.** The number must already be in the operators table. The panchayat officer sets the PIN from the review page and tells the operator in person or by phone. No SMS, no OTP cost, no DLT registration, nothing to print.
- **One phone per operator.** The first sign-in binds the phone. A second phone is refused until the panchayat officer taps *Reset phone*. A lost phone is fixed the same way.
- **Every report is tagged** with the operator and the phone it came from, and the panchayat officer confirms or flags it.
- **Sending the app link**: the review page has a *Send app link on WhatsApp* button per operator, which opens WhatsApp on the officer's own phone with the link and a one-line Tamil instruction.

An SMS one-time code can be added later if the department wants it, once its DLT sender registration exists. It is not needed for the pilot.

## The daily report (operator): two taps, nothing to type

1. **One question, three big colour buttons:** *Did water come today?* Green "water came" saves instantly. Amber "came less" or red "water did not come" go to one more screen.
2. **Six picture tiles:** no electricity · motor broken · pipe broken · no water in source · tank not filled · don't know. Tap one and the report is saved.
3. **Done screen** with a big tick and, for a problem, one mic button to leave a 20-second voice note in Tamil instead of typing.
4. **Several tanks, one tap.** An operator like Kantharaj (Kurumudi 2 GLRs + Nerikambai 1) sees *All tanks (3)* and reports all with one tap, or picks a single tank to report it differently.

The detailed questions the officer asked for (source sufficient? pump ran? GLR filled? action taken) are answered by the **panchayat officer at review time**, who can judge them and can call the operator. The reviewer can also record the day on behalf of an operator who has no phone.

Tamil is the default language. Reports queue offline and send when signal returns. One report per tank per day; a same-day correction resets the review to pending.

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
5. Load districts, blocks, panchayats, habitations, operators (name + real mobile number from the block's sheet) and GLRs (CSV import; the Kookal pilot rows are already in `schema.sql` with placeholder numbers). The panchayat officer then sets each operator's PIN from the review page and sends the app link on WhatsApp.
6. Add staff: create the user by email in Supabase Auth, then insert a row in `officers` with role (`panchayat`, `block`, `district`, `state`) and the matching id.

Without `CONFIG` filled in, the site runs in demo mode with Nilgiris sample data stored on the phone, which is what the public links show.
