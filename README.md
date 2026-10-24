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
| Pump operator | https://myearthprakash-source.github.io/neer-nilai/ | Registered mobile number + its last 4 digits, on any phone, or the WhatsApp link (demo: tap a person, type the last 4 digits) | Enters the daily report for each tank they look after |
| Officers: panchayat, block, district | https://myearthprakash-source.github.io/neer-nilai/officer/ (same app at …/review/, opening on the Review tab) | Registered mobile number + its last 4 digits (demo: tap a person) | One app, two tabs. **Dashboard**: counts, a card per panchayat (tap for details), alerts, per-tank table; district/block officers add, change and remove the staff below them. **Review & operators**: one panchayat at a time (block/district officers pick it): confirm or flag each tank report, record for a silent operator after a call, add / change / remove operators |

Each officer sees only their own area: a panchayat officer their panchayat, a block officer their block, a district officer the district. The operator app and the officer app never link to each other. In live mode the database enforces the split: operator functions accept only a registered mobile number + digits (or a phone that already signed in that way), and every officer sees only the tanks inside their panchayat, block or district (row-level security).

## Who can report: registered operators only

The block's tank sheet lists, for every habitation, the pump operator who will use the app and their mobile number. That list is the access control:

- **Everyone signs in the same way: mobile number + its last 4 digits, on any phone or computer.** Operators, panchayat officers and block/district officers. Nothing to remember, hand out, or wait for (no email, no SMS). Signed in once, the device stays signed in. The number may be typed with +91, spaces or dashes, or autofilled; only its last 10 digits count. A wrong number and wrong digits get different messages ("not registered — ask your officer" vs "wrong digits").
- **No device lock.** Earlier versions tied an operator to the first phone that signed in, which shut out a new phone, a second browser or a tester's laptop. Now any device signs in; the last 10 are remembered, the review page shows "Signed in on N phones", and *Sign out all phones* (lost phone) signs them all out and stops the WhatsApp links. Five wrong tries lock the number for 15 minutes for new devices (never for one already signed in).
- **New people**: nobody can sign themselves up (the sign-in screens say "New here? Your panchayat officer / senior officer adds your number"). A panchayat officer adds an operator on the review page with *+ Add operator*: name (Tamil name optional), mobile number, and a tick for each tank they run. A tank has one operator, so ticking a tank that belongs to someone else hands it over (the form shows who has it now). *Change* edits name, number or tanks; a new number signs out the old number's phones. *Remove* frees their tanks ("no operator") and their number can be given to someone else. The operator's app picks up changes the next time it opens. Block and district officers can do the same from the review page for any panchayat in their area.
- **Hardening later, no screen changes**: give anyone a personal PIN (operators: *New PIN* on the review page; staff: `staff.pin_hash`) and it replaces the last-4 rule for that person.
- **Against cheating, at no cost to the operator**: each report carries which phone sent it and where the phone was (asked once, right after sign-in), shown to the panchayat officer as a map link, or "No location recorded"; only today can be reported; the panchayat officer confirms or flags every problem report.
- **WhatsApp**: *Send app link on WhatsApp* opens WhatsApp on the officer's phone, addressed to the operator, with the app link and a one-line instruction. The link signs in any phone for 30 days (a newer link replaces it) and keeps opening the app on phones it signed in. Two people sharing one phone (the sheet's "Maran / Badichi") are one account.
- **Staff accounts**: listed by phone in the `staff` table (role + district / block / panchayat). District officers add, change and remove block and panchayat officers in their district (and other district officers for it); block officers do the same for panchayat officers in their block — from the dashboard's Staff list, no SQL. A removed person can no longer sign in and an open session sees nothing. The `staff-login` edge function checks number + digits and opens a normal Supabase session with an admin one-time token, so row-level security works unchanged.

Real phone numbers and staff emails never go into this public repo: `schema.sql` seeds 90000000xx placeholders, and the real data lives in `supabase/private/live-data.sql`, which is git-ignored and run only against the live database.

The public anon key can only call the operator functions, the staff-login function and read the tank list: phone numbers, PIN and device hashes, staff and reports are closed to it (tested in a local Postgres with Supabase's default grants, and against the live project).

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
docs/                               Published site. Demo: index.html, review/, officer/. Live: live/ (when configured)
supabase/schema.sql                 Tables (5-level hierarchy, tank kind GLR/OHT), functions, review, RLS, grants, views, pilot data
supabase/live.public.json           Live project URL + anon key (public by design); its presence makes build.js emit docs/live/
supabase/functions/notify/index.ts  Edge function: alerts on Partial / No, noon digest
supabase/private/                   Git-ignored: live-data.sql (real operator phone numbers, staff emails)
```

## Go-live steps

1. Create a free Supabase project (Mumbai region). Run `supabase/schema.sql` in the SQL editor, then `supabase/private/live-data.sql` (real operator and staff numbers).
2. Edge Functions → deploy `supabase/functions/staff-login/index.ts` as `staff-login` (dashboard editor or `supabase functions deploy staff-login`).
3. Put the project URL and anon key in `supabase/live.public.json`, run `node build.js`, push. The live pages appear at `/neer-nilai/live/`, `/live/review/` and `/live/officer/`; the demo stays where it is.
4. Everyone signs in with their number + its last 4 digits. The panchayat officer can send each operator the app link on WhatsApp.
5. Alerts (optional for the pilot): deploy the notify function (`supabase functions deploy notify`, secrets `RESEND_API_KEY`, `FROM_EMAIL`, optionally `WA_TOKEN`, `WA_PHONE_ID`, `APP_URL`), add a Database Webhook on `reports` (INSERT, UPDATE) to it, and schedule the noon digest with the pg_cron snippet in `schema.sql`.
6. More panchayats: load districts, blocks, panchayats, habitations (with `supply_note` where another body supplies water), operators and tanks (`glrs`, `kind` = `GLR` or `OHT`) by CSV import, and add their officers to `officer_invites`.

The demo pages run without a database, with Nilgiris sample data (Kookal, Udhagai block; Masinagudi, Gudalur block) kept on each phone.
