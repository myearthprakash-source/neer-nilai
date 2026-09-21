-- Neer Nilai: GLR-level water supply monitoring
-- Hierarchy: district → block → panchayat → habitation → GLR (one habitation can have several GLRs).
-- Data entry at GLR level; panchayat officer reviews; block/district officers watch the dashboard.
-- Run in the Supabase SQL editor. Safe to re-run on an empty project.

create extension if not exists pgcrypto;
create extension if not exists pg_cron;
create extension if not exists pg_net;

-- ---------------------------------------------------------------- master data
create table if not exists districts   (id serial primary key, name text not null, name_ta text);
create table if not exists blocks      (id serial primary key, district_id int not null references districts(id), name text not null, name_ta text);
create table if not exists panchayats  (id serial primary key, block_id int not null references blocks(id), name text not null, name_ta text);
create table if not exists habitations (id serial primary key, panchayat_id int not null references panchayats(id), name text not null, name_ta text);

create table if not exists glrs (
  id             serial primary key,
  habitation_id  int not null references habitations(id),
  code           text not null unique,        -- e.g. NLG-UDH-KKL-01, printed on the operator's card
  name           text not null,
  name_ta        text,
  scheme         text,                        -- "Open well → 7.5 HP pump → 15,000 L GLR → gravity"
  supply_window  text,                        -- "7:30 – 9:30 AM daily"
  pin_hash       text,                        -- bcrypt of the 4-digit PIN
  active         boolean not null default true
);
create index if not exists glrs_hab_idx on glrs(habitation_id);
create index if not exists habitations_p_idx on habitations(panchayat_id);
create index if not exists panchayats_b_idx on panchayats(block_id);

create table if not exists problems (code text primary key, label_en text not null, label_ta text not null, sort int not null);
-- Operators see the six pictorial ones (sort 1–6); reviewers can refine to any.
insert into problems (code, label_en, label_ta, sort) values
  ('power',       'No electricity',                'மின்சாரம் இல்லை',              1),
  ('pump',        'Motor / pump broken',           'மோட்டார் பழுது',                2),
  ('pipe',        'Pipe broken / leak',            'குழாய் உடைப்பு',                3),
  ('source',      'No water in source',            'ஆதாரத்தில் தண்ணீர் இல்லை',       4),
  ('glr',         'Tank not filled',               'தொட்டி நிரம்பவில்லை',           5),
  ('unknown',     'Don''t know / other',           'தெரியவில்லை / மற்றவை',           6),
  ('pipe_source', 'Source-to-GLR pipeline',        'ஆதாரம் → GLR குழாய்',          7),
  ('pipe_dist',   'Distribution pipeline / valve', 'விநியோகக் குழாய் / வால்வு',    8),
  ('other',       'Other',                         'மற்றவை',                       9)
on conflict (code) do nothing;

-- ---------------------------------------------------------------- staff
-- One row per officer, linked to a Supabase Auth user (email magic link).
-- role 'panchayat' = reviewer (panchayat secretary / VAO); 'block' / 'district' / 'state' = dashboard.
create table if not exists officers (
  id             uuid primary key references auth.users(id) on delete cascade,
  name           text not null,
  role           text not null check (role in ('state','district','block','panchayat')),
  district_id    int references districts(id),
  block_id       int references blocks(id),
  panchayat_id   int references panchayats(id),
  email          text not null,
  phone          text,                        -- E.164 for WhatsApp
  alert_email    boolean not null default true,
  alert_whatsapp boolean not null default false,
  alert_digest   boolean not null default true
);

-- ---------------------------------------------------------------- reports
create table if not exists reports (
  id             bigserial primary key,
  glr_id         int not null references glrs(id),
  report_date    date not null,
  status         text not null check (status in ('yes','partial','no')),        -- normal / less than normal / none
  source_ok      text check (source_ok  in ('yes','no','unknown')),            -- sufficient water in source?
  pump_ok        text check (pump_ok    in ('yes','no','unknown')),            -- pump operated normally?
  glr_filled     text check (glr_filled in ('yes','no','unknown')),            -- GLR adequately filled?
  problem        text references problems(code),
  remarks        text,                                                          -- action taken / remarks (reviewer)
  voice_path     text,                                                          -- operator's voice note in the 'voice' storage bucket
  entered_by     text not null default 'operator' check (entered_by in ('operator','reviewer')),
  reported_at    timestamptz not null default now(),
  device_id      text,
  review_status  text not null default 'pending' check (review_status in ('pending','confirmed','flagged')),
  review_note    text,
  reviewed_by    uuid references officers(id),
  reviewed_at    timestamptz,
  unique (glr_id, report_date)
);
create index if not exists reports_date_idx on reports(report_date);
create index if not exists reports_issue_idx on reports(report_date) where status <> 'yes';

create table if not exists notifications (
  id          bigserial primary key,
  report_id   bigint references reports(id),
  officer_id  uuid references officers(id),
  channel     text not null check (channel in ('email','whatsapp','sms')),
  kind        text not null,                -- 'issue' | 'digest'
  status      text not null default 'queued',
  detail      text,
  created_at  timestamptz not null default now()
);

-- ---------------------------------------------------------------- helpers
create or replace function ist_today() returns date
language sql stable as $$ select (now() at time zone 'Asia/Kolkata')::date $$;

create or replace function set_glr_pin(p_code text, p_pin text) returns void
language sql security definer as $$
  update glrs set pin_hash = crypt(p_pin, gen_salt('bf')) where code = p_code;
$$;
revoke all on function set_glr_pin(text, text) from public, anon;

-- Full hierarchy for a GLR (used by login and the dashboard view).
create or replace view v_glr as
select g.id as glr_id, g.code, g.name as glr, g.name_ta as glr_ta, g.scheme, g.supply_window, g.active,
       h.id as habitation_id, h.name as habitation, h.name_ta as habitation_ta,
       p.id as panchayat_id, p.name as panchayat, p.name_ta as panchayat_ta,
       b.id as block_id, b.name as block, b.name_ta as block_ta,
       d.id as district_id, d.name as district, d.name_ta as district_ta
from glrs g
join habitations h on h.id = g.habitation_id
join panchayats p on p.id = h.panchayat_id
join blocks b on b.id = p.block_id
join districts d on d.id = b.district_id;

-- Operator login: GLR code + PIN. No auth.users row needed, no SMS.
create or replace function operator_login(p_code text, p_pin text)
returns table (id int, code text, name text, name_ta text, scheme text, supply_window text,
               habitation text, habitation_ta text, panchayat_id int, panchayat text, panchayat_ta text,
               block_id int, block text, block_ta text, district text, district_ta text)
language sql security definer stable as $$
  select v.glr_id, v.code, v.glr, v.glr_ta, v.scheme, v.supply_window,
         v.habitation, v.habitation_ta, v.panchayat_id, v.panchayat, v.panchayat_ta,
         v.block_id, v.block, v.block_ta, v.district, v.district_ta
  from v_glr v join glrs g on g.id = v.glr_id
  where g.code = upper(trim(p_code)) and g.active
    and g.pin_hash is not null and g.pin_hash = crypt(p_pin, g.pin_hash);
$$;

-- Operator submit: status + one pictorial problem. One row per GLR per IST day; same-day resubmits overwrite and reset the review.
create or replace function submit_report(
  p_code text, p_pin text, p_status text, p_problem text default null, p_device text default null
) returns reports
language plpgsql security definer as $$
declare
  v_gid int;
  v_row reports;
begin
  select g.id into v_gid from glrs g
  where g.code = upper(trim(p_code)) and g.active
    and g.pin_hash is not null and g.pin_hash = crypt(p_pin, g.pin_hash);
  if v_gid is null then
    raise exception 'invalid code or pin' using errcode = '28000';
  end if;
  if p_status not in ('yes','partial','no') then
    raise exception 'status must be yes, partial or no' using errcode = '23514';
  end if;
  if p_status = 'yes' then
    p_problem := null;
  elsif p_problem is null then
    raise exception 'problem required for partial or no supply' using errcode = '23514';
  end if;

  insert into reports (glr_id, report_date, status, problem, device_id, entered_by)
  values (v_gid, ist_today(), p_status, p_problem, p_device, 'operator')
  on conflict (glr_id, report_date) do update
    set status = excluded.status, problem = excluded.problem, source_ok = null, pump_ok = null, glr_filled = null,
        reported_at = now(), device_id = excluded.device_id, entered_by = 'operator',
        review_status = 'pending', review_note = null, reviewed_by = null, reviewed_at = null
  returning * into v_row;
  return v_row;
end $$;

-- Operator attaches a voice note (uploaded to storage bucket 'voice' at <code>/<date>.webm).
create or replace function attach_voice(p_code text, p_pin text, p_path text) returns void
language sql security definer as $$
  update reports r set voice_path = p_path
  from glrs g
  where g.id = r.glr_id and r.report_date = ist_today()
    and g.code = upper(trim(p_code)) and g.pin_hash = crypt(p_pin, g.pin_hash);
$$;

-- Operator's own last 14 days for the strip on the report screen.
create or replace function operator_history(p_code text, p_pin text)
returns table (report_date date, status text, problem text, remarks text, voice_path text, reported_at timestamptz)
language sql security definer stable as $$
  select r.report_date, r.status, r.problem, r.remarks, r.voice_path, r.reported_at
  from reports r join glrs g on g.id = r.glr_id
  where g.code = upper(trim(p_code)) and g.pin_hash = crypt(p_pin, g.pin_hash)
    and r.report_date >= ist_today() - 13
  order by r.report_date;
$$;

grant execute on function operator_login(text, text) to anon;
grant execute on function submit_report(text, text, text, text, text) to anon;
grant execute on function attach_voice(text, text, text) to anon;
grant execute on function operator_history(text, text) to anon;

-- Voice notes bucket: operators (anon) upload, staff (authenticated) listen via signed URLs.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('voice', 'voice', false, 2097152, array['audio/webm','audio/mp4','audio/ogg','audio/mpeg','audio/wav'])
on conflict (id) do nothing;
drop policy if exists voice_upload on storage.objects;
create policy voice_upload on storage.objects for insert to anon with check (bucket_id = 'voice');
drop policy if exists voice_replace on storage.objects;
create policy voice_replace on storage.objects for update to anon using (bucket_id = 'voice');
drop policy if exists voice_read on storage.objects;
create policy voice_read on storage.objects for select to authenticated using (bucket_id = 'voice');

-- ---------------------------------------------------------------- officer scope + review
create or replace function officer_scope() returns table (role text, district_id int, block_id int, panchayat_id int)
language sql stable security definer as $$
  select role, district_id, block_id, panchayat_id from officers where id = auth.uid()
$$;

-- Can the signed-in officer see this GLR?
create or replace function can_see_glr(p_glr_id int) returns boolean
language sql stable security definer as $$
  select exists (
    select 1 from officer_scope() s join v_glr v on v.glr_id = p_glr_id
    where s.role = 'state'
       or (s.role = 'district'  and v.district_id  = s.district_id)
       or (s.role = 'block'     and v.block_id     = s.block_id)
       or (s.role = 'panchayat' and v.panchayat_id = s.panchayat_id)
  )
$$;

-- Panchayat officer (or anyone above) confirms or flags a report and fills in the diagnostics,
-- refined problem and action taken. The operator only gave status + one picture.
create or replace function review_report(
  p_report_id bigint, p_status text, p_note text default null,
  p_source_ok text default null, p_pump_ok text default null, p_glr_filled text default null, p_problem text default null
) returns reports
language plpgsql security definer as $$
declare v_row reports;
begin
  if p_status not in ('confirmed','flagged') then
    raise exception 'review status must be confirmed or flagged' using errcode = '23514';
  end if;
  select * into v_row from reports where id = p_report_id;
  if v_row.id is null or not can_see_glr(v_row.glr_id) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  update reports set review_status = p_status, remarks = nullif(trim(p_note), ''),
      source_ok = p_source_ok, pump_ok = p_pump_ok, glr_filled = p_glr_filled, problem = coalesce(p_problem, problem),
      reviewed_by = auth.uid(), reviewed_at = now()
  where id = p_report_id returning * into v_row;
  return v_row;
end $$;
grant execute on function review_report(bigint, text, text, text, text, text, text) to authenticated;

-- Panchayat officer records a day on behalf of an operator (after a phone call). Counts as confirmed.
create or replace function reviewer_submit(p_glr_id int, p_status text, p_problem text default null, p_remarks text default null) returns reports
language plpgsql security definer as $$
declare v_row reports;
begin
  if not can_see_glr(p_glr_id) then raise exception 'not allowed' using errcode = '42501'; end if;
  if p_status not in ('yes','partial','no') then raise exception 'bad status' using errcode = '23514'; end if;
  if p_status = 'yes' then p_problem := null; elsif p_problem is null then raise exception 'problem required' using errcode = '23514'; end if;
  insert into reports (glr_id, report_date, status, problem, remarks, entered_by, review_status, reviewed_by, reviewed_at)
  values (p_glr_id, ist_today(), p_status, p_problem, nullif(trim(p_remarks), ''), 'reviewer', 'confirmed', auth.uid(), now())
  on conflict (glr_id, report_date) do update
    set status = excluded.status, problem = excluded.problem, remarks = excluded.remarks, entered_by = 'reviewer',
        reported_at = now(), review_status = 'confirmed', reviewed_by = auth.uid(), reviewed_at = now()
  returning * into v_row;
  return v_row;
end $$;
grant execute on function reviewer_submit(int, text, text, text) to authenticated;

-- Today's status for every GLR in scope, including the silent ones.
create or replace view v_today as
select v.*,
  r.id as report_id, coalesce(r.status, 'not_reported') as status,
  r.source_ok, r.pump_ok, r.glr_filled, r.problem, r.remarks, r.voice_path, r.entered_by, r.reported_at,
  r.review_status, r.review_note, r.reviewed_at
from v_glr v
left join reports r on r.glr_id = v.glr_id and r.report_date = ist_today()
where v.active and can_see_glr(v.glr_id);

-- ---------------------------------------------------------------- row-level security
alter table reports enable row level security;
alter table glrs enable row level security;
alter table habitations enable row level security;
alter table panchayats enable row level security;
alter table blocks enable row level security;
alter table districts enable row level security;
alter table officers enable row level security;
alter table notifications enable row level security;
alter table problems enable row level security;

drop policy if exists read_districts on districts;     create policy read_districts on districts for select using (true);
drop policy if exists read_blocks on blocks;           create policy read_blocks on blocks for select using (true);
drop policy if exists read_panchayats on panchayats;   create policy read_panchayats on panchayats for select using (true);
drop policy if exists read_habitations on habitations; create policy read_habitations on habitations for select using (true);
drop policy if exists read_glrs on glrs;               create policy read_glrs on glrs for select using (true);
drop policy if exists read_problems on problems;       create policy read_problems on problems for select using (true);
revoke select (pin_hash) on glrs from anon, authenticated;   -- pin_hash never leaves the database

drop policy if exists officer_read_reports on reports;
create policy officer_read_reports on reports for select to authenticated using (can_see_glr(glr_id));
drop policy if exists officer_read_self on officers;
create policy officer_read_self on officers for select to authenticated using (id = auth.uid());
drop policy if exists officer_update_self on officers;
create policy officer_update_self on officers for update to authenticated using (id = auth.uid()) with check (id = auth.uid());
drop policy if exists officer_read_notifications on notifications;
create policy officer_read_notifications on notifications for select to authenticated using (officer_id = auth.uid());

-- ---------------------------------------------------------------- alerts
-- Option A (recommended, no code): Supabase Dashboard → Database → Webhooks →
--   table reports, INSERT + UPDATE → HTTP POST to the notify edge function.
-- Option B: pg_cron noon digest. Replace <PROJECT_REF> and <SERVICE_ROLE_KEY>. 12:00 IST = 06:30 UTC.
-- select cron.schedule('neer-nilai-digest', '30 6 * * *', $$
--   select net.http_post(
--     url := 'https://<PROJECT_REF>.supabase.co/functions/v1/notify',
--     headers := '{"Content-Type":"application/json","Authorization":"Bearer <SERVICE_ROLE_KEY>"}'::jsonb,
--     body := '{"type":"digest"}'::jsonb
--   );
-- $$);

-- ---------------------------------------------------------------- sample data (pilot: The Nilgiris)
insert into districts (id, name, name_ta) values (1, 'The Nilgiris', 'நீலகிரி') on conflict do nothing;
insert into blocks (id, district_id, name, name_ta) values (1, 1, 'Udhagamandalam', 'உதகமண்டலம்'), (2, 1, 'Coonoor', 'குன்னூர்') on conflict do nothing;
insert into panchayats (id, block_id, name, name_ta) values (1, 1, 'Kookal', 'கூக்கல்'), (2, 1, 'Emerald', 'எமரால்டு'), (3, 2, 'Hubbathalai', 'ஹுப்பத்தாலை') on conflict do nothing;
insert into habitations (id, panchayat_id, name, name_ta) values
  (1, 1, 'Jeevanagar', 'ஜீவநகர்'), (2, 1, 'Kookal Main', 'கூக்கல் மெயின்'),
  (3, 2, 'Emerald Village', 'எமரால்டு கிராமம்'), (4, 2, 'Emerald Estate', 'எமரால்டு எஸ்டேட்'),
  (5, 3, 'Hubbathalai', 'ஹுப்பத்தாலை'), (6, 3, 'Ketti Palada', 'கெட்டி பாலாடா')
on conflict do nothing;
insert into glrs (habitation_id, code, name, name_ta, scheme, supply_window) values
  (1, 'NLG-UDH-KKL-01', 'Jeevanagar GLR',      'ஜீவநகர் GLR',           'Open well → 7.5 HP pump → 15,000 L GLR → gravity through GI pipes', '7:30 – 9:30 AM daily'),
  (2, 'NLG-UDH-KKL-02', 'Kookal Main OHT',     'கூக்கல் மெயின் OHT',     'Bore well → 5 HP pump → 30,000 L OHT → gravity',                    '6:30 – 8:30 AM daily'),
  (2, 'NLG-UDH-KKL-03', 'Kookal Colony GLR',   'கூக்கல் காலனி GLR',      'Spring → 10,000 L GLR → gravity',                                   '7:00 – 8:00 AM daily'),
  (3, 'NLG-UDH-EMR-01', 'Emerald Village GLR', 'எமரால்டு கிராம GLR',     'Open well → 5 HP pump → 20,000 L GLR',                              '7:00 – 9:00 AM daily'),
  (4, 'NLG-UDH-EMR-02', 'Emerald Estate GLR',  'எமரால்டு எஸ்டேட் GLR',   'Stream intake → 10,000 L GLR → gravity',                            '8:00 – 9:00 AM daily'),
  (5, 'NLG-CNR-HBT-01', 'Hubbathalai OHT',     'ஹுப்பத்தாலை OHT',        'Bore well → 7.5 HP pump → 40,000 L OHT',                            '6:00 – 8:00 AM daily'),
  (6, 'NLG-CNR-HBT-02', 'Ketti Palada GLR',    'கெட்டி பாலாடா GLR',      'Open well → 3 HP pump → 10,000 L GLR',                              '7:30 – 8:30 AM daily')
on conflict (code) do nothing;
select set_glr_pin(code, '1234') from glrs where pin_hash is null;
select setval('districts_id_seq', (select max(id) from districts));
select setval('blocks_id_seq', (select max(id) from blocks));
select setval('panchayats_id_seq', (select max(id) from panchayats));
select setval('habitations_id_seq', (select max(id) from habitations));
