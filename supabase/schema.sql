-- Neer Nilai: panchayat water delivery monitoring
-- Run in the Supabase SQL editor. Safe to re-run.

create extension if not exists pgcrypto;
create extension if not exists pg_cron;
create extension if not exists pg_net;

-- ---------------------------------------------------------------- master data
create table if not exists districts (
  id       serial primary key,
  name     text not null,
  name_ta  text
);

create table if not exists blocks (
  id          serial primary key,
  district_id int not null references districts(id),
  name        text not null,
  name_ta     text
);

create table if not exists panchayats (
  id        serial primary key,
  block_id  int not null references blocks(id),
  code      text not null unique,          -- e.g. VPM-TDV-001, printed on the operator's card
  name      text not null,
  name_ta   text,
  pin_hash  text,                          -- bcrypt of the 4-digit PIN
  active    boolean not null default true
);
create index if not exists panchayats_block_idx on panchayats(block_id);

create table if not exists reasons (
  code      text primary key,
  label_en  text not null,
  label_ta  text not null,
  sort      int not null
);
insert into reasons (code, label_en, label_ta, sort) values
  ('power',    'No power supply',         'மின்சாரம் இல்லை',        1),
  ('motor',    'Motor / pump failure',    'மோட்டார் பழுது',         2),
  ('pipe',     'Pipeline burst / leak',   'குழாய் உடைப்பு',          3),
  ('source',   'Source dry / low water',  'நீர் ஆதாரம் வறண்டது',    4),
  ('pressure', 'Low pressure / short duration', 'அழுத்தம் குறைவு / குறைந்த நேரம்', 5),
  ('tanker',   'Tanker did not arrive',   'டேங்கர் லாரி வரவில்லை',   6),
  ('operator', 'Operator not available',  'ஆபரேட்டர் இல்லை',        7),
  ('other',    'Other',                   'மற்றவை',                 8)
on conflict (code) do nothing;

-- ---------------------------------------------------------------- officers
-- One row per officer, linked to a Supabase Auth user (email magic link).
create table if not exists officers (
  id            uuid primary key references auth.users(id) on delete cascade,
  name          text not null,
  role          text not null check (role in ('state','district','block')),
  district_id   int references districts(id),
  block_id      int references blocks(id),
  email         text not null,
  phone         text,                       -- E.164, e.g. +9198xxxxxxxx, for WhatsApp
  alert_email   boolean not null default true,
  alert_whatsapp boolean not null default false,
  alert_digest  boolean not null default true
);

-- ---------------------------------------------------------------- reports
create table if not exists reports (
  id            bigserial primary key,
  panchayat_id  int not null references panchayats(id),
  report_date   date not null,
  status        text not null check (status in ('yes','partial','no')),   -- yes = normal, partial = limited, no = none
  reason        text references reasons(code),
  comment       text,
  reported_at   timestamptz not null default now(),
  device_id     text,
  unique (panchayat_id, report_date)
);
create index if not exists reports_date_idx on reports(report_date);
create index if not exists reports_issue_idx on reports(report_date) where status <> 'yes';

create table if not exists notifications (
  id          bigserial primary key,
  report_id   bigint references reports(id),
  officer_id  uuid references officers(id),
  channel     text not null check (channel in ('email','whatsapp','sms')),
  kind        text not null,                -- 'no_delivery' | 'digest'
  status      text not null default 'queued',
  detail      text,
  created_at  timestamptz not null default now()
);

-- ---------------------------------------------------------------- helpers
create or replace function ist_today() returns date
language sql stable as $$ select (now() at time zone 'Asia/Kolkata')::date $$;

create or replace function set_panchayat_pin(p_code text, p_pin text) returns void
language sql security definer as $$
  update panchayats set pin_hash = crypt(p_pin, gen_salt('bf')) where code = p_code;
$$;
revoke all on function set_panchayat_pin(text, text) from public, anon;

-- Operator login: returns the panchayat the app should remember. No auth.users row needed.
create or replace function operator_login(p_code text, p_pin text)
returns table (id int, code text, name text, name_ta text, block text, block_ta text, district text, district_ta text)
language sql security definer stable as $$
  select p.id, p.code, p.name, p.name_ta, b.name, b.name_ta, d.name, d.name_ta
  from panchayats p
  join blocks b on b.id = p.block_id
  join districts d on d.id = b.district_id
  where p.code = upper(trim(p_code)) and p.active
    and p.pin_hash is not null and p.pin_hash = crypt(p_pin, p.pin_hash);
$$;

-- Operator submit: one row per panchayat per IST day; same-day resubmits overwrite.
-- p_status: 'yes' (normal supply), 'partial' (limited supply), 'no' (no supply).
create or replace function submit_report(
  p_code text, p_pin text, p_status text,
  p_reason text default null, p_comment text default null, p_device text default null
) returns reports
language plpgsql security definer as $$
declare
  v_pid int;
  v_row reports;
begin
  select p.id into v_pid from panchayats p
  where p.code = upper(trim(p_code)) and p.active
    and p.pin_hash is not null and p.pin_hash = crypt(p_pin, p.pin_hash);
  if v_pid is null then
    raise exception 'invalid code or pin' using errcode = '28000';
  end if;
  if p_status not in ('yes','partial','no') then
    raise exception 'status must be yes, partial or no' using errcode = '23514';
  end if;
  if p_status = 'yes' then
    p_reason := null;
  elsif p_reason is null then
    raise exception 'reason required for partial or no supply' using errcode = '23514';
  end if;

  insert into reports (panchayat_id, report_date, status, reason, comment, device_id)
  values (v_pid, ist_today(), p_status, p_reason, nullif(trim(p_comment), ''), p_device)
  on conflict (panchayat_id, report_date) do update
    set status = excluded.status, reason = excluded.reason,
        comment = excluded.comment, reported_at = now(), device_id = excluded.device_id
  returning * into v_row;
  return v_row;
end $$;

-- Operator's own recent history (last 14 days) for the strip on the report screen.
create or replace function operator_history(p_code text, p_pin text)
returns table (report_date date, status text, reason text)
language sql security definer stable as $$
  select r.report_date, r.status, r.reason
  from reports r
  join panchayats p on p.id = r.panchayat_id
  where p.code = upper(trim(p_code)) and p.pin_hash = crypt(p_pin, p.pin_hash)
    and r.report_date >= ist_today() - 13
  order by r.report_date;
$$;

grant execute on function operator_login(text, text) to anon;
grant execute on function submit_report(text, text, text, text, text, text) to anon;
grant execute on function operator_history(text, text) to anon;

-- ---------------------------------------------------------------- officer views
-- Today's status for every panchayat, including the silent ones.
create or replace view v_today as
select
  d.id as district_id, d.name as district, d.name_ta as district_ta,
  b.id as block_id, b.name as block, b.name_ta as block_ta,
  p.id as panchayat_id, p.code, p.name as panchayat, p.name_ta as panchayat_ta,
  r.id as report_id, r.reason, r.comment, r.reported_at,
  coalesce(r.status, 'not_reported') as status
from panchayats p
join blocks b on b.id = p.block_id
join districts d on d.id = b.district_id
left join reports r on r.panchayat_id = p.id and r.report_date = ist_today()
where p.active;

-- ---------------------------------------------------------------- row-level security
alter table reports        enable row level security;
alter table panchayats     enable row level security;
alter table blocks         enable row level security;
alter table districts      enable row level security;
alter table officers       enable row level security;
alter table notifications  enable row level security;
alter table reasons        enable row level security;

-- Master data is readable by everyone (the operator app needs it for setup lists).
drop policy if exists read_districts on districts;
create policy read_districts on districts for select using (true);
drop policy if exists read_blocks on blocks;
create policy read_blocks on blocks for select using (true);
drop policy if exists read_reasons on reasons;
create policy read_reasons on reasons for select using (true);
drop policy if exists read_panchayats on panchayats;
create policy read_panchayats on panchayats for select using (true);
-- pin_hash must never leave the database:
revoke select (pin_hash) on panchayats from anon, authenticated;

-- Officers see reports inside their jurisdiction.
create or replace function officer_scope() returns table (role text, district_id int, block_id int)
language sql stable security definer as $$
  select role, district_id, block_id from officers where id = auth.uid()
$$;

drop policy if exists officer_read_reports on reports;
create policy officer_read_reports on reports for select to authenticated using (
  exists (
    select 1 from officer_scope() s
    join panchayats p on p.id = reports.panchayat_id
    join blocks b on b.id = p.block_id
    where s.role = 'state'
       or (s.role = 'district' and b.district_id = s.district_id)
       or (s.role = 'block' and p.block_id = s.block_id)
  )
);

drop policy if exists officer_read_self on officers;
create policy officer_read_self on officers for select to authenticated using (id = auth.uid());
drop policy if exists officer_update_self on officers;
create policy officer_update_self on officers for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

drop policy if exists officer_read_notifications on notifications;
create policy officer_read_notifications on notifications for select to authenticated
  using (officer_id = auth.uid());

-- ---------------------------------------------------------------- alerts
-- Option A (recommended, no code): Supabase Dashboard → Database → Webhooks →
--   table reports, INSERT + UPDATE → HTTP POST to the notify edge function.
-- Option B: pg_cron noon digest. Replace <PROJECT_REF> and <SERVICE_ROLE_KEY>.
-- 12:00 IST = 06:30 UTC.
-- select cron.schedule('neer-nilai-digest', '30 6 * * *', $$
--   select net.http_post(
--     url := 'https://<PROJECT_REF>.supabase.co/functions/v1/notify',
--     headers := '{"Content-Type":"application/json","Authorization":"Bearer <SERVICE_ROLE_KEY>"}'::jsonb,
--     body := '{"type":"digest"}'::jsonb
--   );
-- $$);

-- ---------------------------------------------------------------- sample data (pilot)
insert into districts (id, name, name_ta) values (1, 'Villupuram', 'விழுப்புரம்') on conflict do nothing;
insert into blocks (id, district_id, name, name_ta) values
  (1, 1, 'Tindivanam', 'திண்டிவனம்'), (2, 1, 'Gingee', 'செஞ்சி') on conflict do nothing;
insert into panchayats (block_id, code, name, name_ta) values
  (1, 'VPM-TDV-001', 'Nallur',        'நல்லூர்'),
  (1, 'VPM-TDV-002', 'Perumbakkam',   'பெரும்பாக்கம்'),
  (1, 'VPM-TDV-003', 'Kiliyanur',     'கிளியனூர்'),
  (1, 'VPM-TDV-004', 'Sithamur',      'சித்தாமூர்'),
  (2, 'VPM-GNG-001', 'Melmalayanur',  'மேல்மலையனூர்'),
  (2, 'VPM-GNG-002', 'Anandapuram',   'ஆனந்தபுரம்'),
  (2, 'VPM-GNG-003', 'Sathyamangalam','சத்தியமங்கலம்'),
  (2, 'VPM-GNG-004', 'Thenpalapattu', 'தென்பாலப்பட்டு')
on conflict (code) do nothing;
select set_panchayat_pin(code, '1234') from panchayats where pin_hash is null;
select setval('districts_id_seq', (select max(id) from districts));
select setval('blocks_id_seq', (select max(id) from blocks));
