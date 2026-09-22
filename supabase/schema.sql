-- Neer Nilai: GLR-level water supply monitoring
-- Hierarchy: district → block → panchayat → habitation → GLR (a habitation can have several GLRs).
-- Identity: each GLR has a registered pump operator (name + mobile number, from the block's list).
--   Operator signs in with mobile number + 4-digit PIN given by the panchayat officer. One phone per operator.
--   Panchayat officer reviews; block/district officers watch the dashboard.
-- Run in the Supabase SQL editor. Safe to re-run on an empty project.

create extension if not exists pgcrypto;
create extension if not exists pg_cron;
create extension if not exists pg_net;

-- ---------------------------------------------------------------- master data
create table if not exists districts   (id serial primary key, name text not null, name_ta text);
create table if not exists blocks      (id serial primary key, district_id int not null references districts(id), name text not null, name_ta text);
create table if not exists panchayats  (id serial primary key, block_id int not null references blocks(id), name text not null, name_ta text);
create table if not exists habitations (id serial primary key, panchayat_id int not null references panchayats(id), name text not null, name_ta text);

-- Pump operators: the people who use the app. Phone number is the identity.
create table if not exists operators (
  id             serial primary key,
  panchayat_id   int not null references panchayats(id),
  name           text not null,
  name_ta        text,
  phone          text not null unique check (phone ~ '^[6-9][0-9]{9}$'),   -- 10-digit Indian mobile
  pin_hash       text,                                                      -- bcrypt of the 4-digit PIN, set by panchayat officer
  device_id      text,                                                      -- bound on first sign-in; reset by panchayat officer
  device_bound_at timestamptz,
  active         boolean not null default true
);

create table if not exists glrs (
  id             serial primary key,
  habitation_id  int not null references habitations(id),
  operator_id    int references operators(id),
  code           text not null unique,        -- e.g. NLG-UDH-KKL-01
  name           text not null,
  name_ta        text,
  location       text,                        -- "Near Hethaiyamman temple"
  capacity_l     int,                         -- litres
  scheme         text,
  supply_window  text,
  active         boolean not null default true
);
create index if not exists glrs_hab_idx on glrs(habitation_id);
create index if not exists glrs_op_idx on glrs(operator_id);
create index if not exists habitations_p_idx on habitations(panchayat_id);
create index if not exists panchayats_b_idx on panchayats(block_id);

create table if not exists problems (code text primary key, label_en text not null, label_ta text not null, sort int not null);
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
create table if not exists officers (
  id             uuid primary key references auth.users(id) on delete cascade,
  name           text not null,
  role           text not null check (role in ('state','district','block','panchayat')),
  district_id    int references districts(id),
  block_id       int references blocks(id),
  panchayat_id   int references panchayats(id),
  email          text not null,
  phone          text,
  alert_email    boolean not null default true,
  alert_whatsapp boolean not null default false,
  alert_digest   boolean not null default true
);

-- ---------------------------------------------------------------- reports
create table if not exists reports (
  id             bigserial primary key,
  glr_id         int not null references glrs(id),
  report_date    date not null,
  status         text not null check (status in ('yes','partial','no')),
  problem        text references problems(code),
  source_ok      text check (source_ok  in ('yes','no','unknown')),
  pump_ok        text check (pump_ok    in ('yes','no','unknown')),
  glr_filled     text check (glr_filled in ('yes','no','unknown')),
  remarks        text,
  voice_path     text,
  entered_by     text not null default 'operator' check (entered_by in ('operator','reviewer')),
  operator_id    int references operators(id),
  device_id      text,
  reported_at    timestamptz not null default now(),
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
  kind        text not null,
  status      text not null default 'queued',
  detail      text,
  created_at  timestamptz not null default now()
);

-- ---------------------------------------------------------------- helpers
create or replace function ist_today() returns date
language sql stable as $$ select (now() at time zone 'Asia/Kolkata')::date $$;

create or replace view v_glr as
select g.id as glr_id, g.code, g.name as glr, g.name_ta as glr_ta, g.location, g.capacity_l as capacity, g.scheme, g.supply_window, g.active,
       h.id as habitation_id, h.name as habitation, h.name_ta as habitation_ta,
       p.id as panchayat_id, p.name as panchayat, p.name_ta as panchayat_ta,
       b.id as block_id, b.name as block, b.name_ta as block_ta,
       d.id as district_id, d.name as district, d.name_ta as district_ta,
       o.id as operator_id, o.name as operator_name, o.name_ta as operator_name_ta, o.phone as operator_phone
from glrs g
join habitations h on h.id = g.habitation_id
join panchayats p on p.id = h.panchayat_id
join blocks b on b.id = p.block_id
join districts d on d.id = b.district_id
left join operators o on o.id = g.operator_id;

-- Verify operator (phone + PIN + device). Binds the device on first use; refuses a different device.
create or replace function operator_check(p_phone text, p_pin text, p_device text) returns int
language plpgsql security definer as $$
declare v operators;
begin
  select * into v from operators where phone = p_phone and active and pin_hash is not null and pin_hash = crypt(p_pin, pin_hash);
  if v.id is null then raise exception 'invalid phone or pin' using errcode = '28000'; end if;
  if v.device_id is null then
    update operators set device_id = p_device, device_bound_at = now() where id = v.id;
  elsif v.device_id <> p_device then
    raise exception 'device not allowed for this number' using errcode = '28000';
  end if;
  return v.id;
end $$;

-- Sign-in: returns one row per GLR the operator looks after.
create or replace function operator_login(p_phone text, p_pin text, p_device text)
returns table (operator_id int, operator_name text, operator_name_ta text,
               glr_id int, code text, glr text, glr_ta text, location text, capacity int,
               habitation text, habitation_ta text, panchayat_id int, panchayat text, panchayat_ta text,
               block text, block_ta text, district text, district_ta text)
language plpgsql security definer as $$
declare v_oid int;
begin
  v_oid := operator_check(p_phone, p_pin, p_device);
  return query
    select v.operator_id, v.operator_name, v.operator_name_ta, v.glr_id, v.code, v.glr, v.glr_ta, v.location, v.capacity,
           v.habitation, v.habitation_ta, v.panchayat_id, v.panchayat, v.panchayat_ta, v.block, v.block_ta, v.district, v.district_ta
    from v_glr v where v.operator_id = v_oid and v.active order by v.code;
end $$;

-- Daily report: status + one pictorial problem. Same-day resubmit overwrites and resets the review.
create or replace function submit_report(p_phone text, p_pin text, p_device text, p_glr_id int, p_status text, p_problem text default null)
returns reports
language plpgsql security definer as $$
declare v_oid int; v_row reports;
begin
  v_oid := operator_check(p_phone, p_pin, p_device);
  if not exists (select 1 from glrs where id = p_glr_id and operator_id = v_oid and active) then
    raise exception 'glr not assigned to this operator' using errcode = '42501';
  end if;
  if p_status not in ('yes','partial','no') then raise exception 'bad status' using errcode = '23514'; end if;
  if p_status = 'yes' then p_problem := null; elsif p_problem is null then raise exception 'problem required' using errcode = '23514'; end if;

  insert into reports (glr_id, report_date, status, problem, operator_id, device_id, entered_by)
  values (p_glr_id, ist_today(), p_status, p_problem, v_oid, p_device, 'operator')
  on conflict (glr_id, report_date) do update
    set status = excluded.status, problem = excluded.problem, source_ok = null, pump_ok = null, glr_filled = null,
        operator_id = excluded.operator_id, device_id = excluded.device_id, entered_by = 'operator', reported_at = now(),
        review_status = 'pending', review_note = null, reviewed_by = null, reviewed_at = null
  returning * into v_row;
  return v_row;
end $$;

create or replace function attach_voice(p_phone text, p_pin text, p_glr_id int, p_path text) returns void
language plpgsql security definer as $$
declare v_oid int;
begin
  v_oid := operator_check(p_phone, p_pin, (select device_id from operators where phone = p_phone));
  update reports set voice_path = p_path where glr_id = p_glr_id and report_date = ist_today() and operator_id = v_oid;
end $$;

create or replace function operator_history(p_phone text, p_pin text, p_glr_id int)
returns table (report_date date, status text, problem text, remarks text, voice_path text, reported_at timestamptz)
language plpgsql security definer stable as $$
declare v_oid int;
begin
  v_oid := operator_check(p_phone, p_pin, (select device_id from operators where phone = p_phone));
  return query select r.report_date, r.status, r.problem, r.remarks, r.voice_path, r.reported_at
    from reports r join glrs g on g.id = r.glr_id
    where g.id = p_glr_id and g.operator_id = v_oid and r.report_date >= ist_today() - 13 order by r.report_date;
end $$;

grant execute on function operator_login(text, text, text) to anon;
grant execute on function submit_report(text, text, text, int, text, text) to anon;
grant execute on function attach_voice(text, text, int, text) to anon;
grant execute on function operator_history(text, text, int) to anon;

-- Voice notes bucket
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('voice', 'voice', false, 2097152, array['audio/webm','audio/mp4','audio/ogg','audio/mpeg','audio/wav'])
on conflict (id) do nothing;
drop policy if exists voice_upload on storage.objects;  create policy voice_upload on storage.objects for insert to anon with check (bucket_id = 'voice');
drop policy if exists voice_replace on storage.objects; create policy voice_replace on storage.objects for update to anon using (bucket_id = 'voice');
drop policy if exists voice_read on storage.objects;    create policy voice_read on storage.objects for select to authenticated using (bucket_id = 'voice');

-- ---------------------------------------------------------------- officer scope
create or replace function officer_scope() returns table (role text, district_id int, block_id int, panchayat_id int)
language sql stable security definer as $$ select role, district_id, block_id, panchayat_id from officers where id = auth.uid() $$;

create or replace function can_see_panchayat(p_panchayat_id int) returns boolean
language sql stable security definer as $$
  select exists (
    select 1 from officer_scope() s join panchayats p on p.id = p_panchayat_id join blocks b on b.id = p.block_id
    where s.role = 'state' or (s.role = 'district' and b.district_id = s.district_id)
       or (s.role = 'block' and p.block_id = s.block_id) or (s.role = 'panchayat' and p.id = s.panchayat_id))
$$;
create or replace function can_see_glr(p_glr_id int) returns boolean
language sql stable security definer as $$ select can_see_panchayat((select panchayat_id from v_glr where glr_id = p_glr_id)) $$;

-- Operators visible to the signed-in officer (no pin_hash).
create or replace view v_operators as
select o.id, o.panchayat_id, o.name, o.name_ta, o.phone, o.device_id, o.device_bound_at, o.active,
       (select count(*) from glrs g where g.operator_id = o.id and g.active) as glr_count
from operators o where o.active and can_see_panchayat(o.panchayat_id);

-- Panchayat officer sets / resets an operator's PIN and phone binding.
create or replace function set_operator_pin(p_operator_id int, p_pin text) returns void
language plpgsql security definer as $$
begin
  if not can_see_panchayat((select panchayat_id from operators where id = p_operator_id)) then raise exception 'not allowed' using errcode = '42501'; end if;
  if p_pin !~ '^[0-9]{4}$' then raise exception 'pin must be 4 digits' using errcode = '23514'; end if;
  update operators set pin_hash = crypt(p_pin, gen_salt('bf')) where id = p_operator_id;
end $$;
create or replace function reset_operator_device(p_operator_id int) returns void
language plpgsql security definer as $$
begin
  if not can_see_panchayat((select panchayat_id from operators where id = p_operator_id)) then raise exception 'not allowed' using errcode = '42501'; end if;
  update operators set device_id = null, device_bound_at = null where id = p_operator_id;
end $$;
grant execute on function set_operator_pin(int, text) to authenticated;
grant execute on function reset_operator_device(int) to authenticated;

-- Review: confirm/flag + diagnostics + refined problem + action taken.
create or replace function review_report(
  p_report_id bigint, p_status text, p_note text default null,
  p_source_ok text default null, p_pump_ok text default null, p_glr_filled text default null, p_problem text default null
) returns reports
language plpgsql security definer as $$
declare v_row reports;
begin
  if p_status not in ('confirmed','flagged') then raise exception 'bad review status' using errcode = '23514'; end if;
  select * into v_row from reports where id = p_report_id;
  if v_row.id is null or not can_see_glr(v_row.glr_id) then raise exception 'not allowed' using errcode = '42501'; end if;
  update reports set review_status = p_status, remarks = nullif(trim(p_note), ''),
      source_ok = p_source_ok, pump_ok = p_pump_ok, glr_filled = p_glr_filled, problem = coalesce(p_problem, problem),
      reviewed_by = auth.uid(), reviewed_at = now()
  where id = p_report_id returning * into v_row;
  return v_row;
end $$;
grant execute on function review_report(bigint, text, text, text, text, text, text) to authenticated;

-- Reviewer records a day on behalf of an operator (after a phone call). Counts as confirmed.
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

-- Today's status for every GLR in scope, including silent ones.
create or replace view v_today as
select v.*,
  r.id as report_id, coalesce(r.status, 'not_reported') as status,
  r.problem, r.source_ok, r.pump_ok, r.glr_filled, r.remarks, r.voice_path, r.entered_by, r.reported_at,
  r.review_status, r.review_note, r.reviewed_at
from v_glr v
left join reports r on r.glr_id = v.glr_id and r.report_date = ist_today()
where v.active and can_see_panchayat(v.panchayat_id);

-- ---------------------------------------------------------------- row-level security
alter table reports enable row level security;
alter table glrs enable row level security;
alter table operators enable row level security;
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
-- operators: no direct read for anon; staff read through v_operators (security definer functions handle sign-in)
drop policy if exists officer_read_operators on operators;
create policy officer_read_operators on operators for select to authenticated using (can_see_panchayat(panchayat_id));
revoke select (pin_hash) on operators from anon, authenticated;
drop policy if exists officer_read_reports on reports;
create policy officer_read_reports on reports for select to authenticated using (can_see_glr(glr_id));
drop policy if exists officer_read_self on officers;
create policy officer_read_self on officers for select to authenticated using (id = auth.uid());
drop policy if exists officer_update_self on officers;
create policy officer_update_self on officers for update to authenticated using (id = auth.uid()) with check (id = auth.uid());
drop policy if exists officer_read_notifications on notifications;
create policy officer_read_notifications on notifications for select to authenticated using (officer_id = auth.uid());

-- ---------------------------------------------------------------- alerts
-- Database → Webhooks: table reports, INSERT + UPDATE → notify edge function.
-- Noon digest (12:00 IST = 06:30 UTC). Replace <PROJECT_REF> and <SERVICE_ROLE_KEY>:
-- select cron.schedule('neer-nilai-digest', '30 6 * * *', $$
--   select net.http_post(url := 'https://<PROJECT_REF>.supabase.co/functions/v1/notify',
--     headers := '{"Content-Type":"application/json","Authorization":"Bearer <SERVICE_ROLE_KEY>"}'::jsonb,
--     body := '{"type":"digest"}'::jsonb);
-- $$);

-- ---------------------------------------------------------------- pilot data: Kookal village panchayat (from the block's GLR sheet)
-- Replace the 90000000xx phone numbers with the real ones from the sheet before running in the live project.
insert into districts (id, name, name_ta) values (1, 'The Nilgiris', 'நீலகிரி') on conflict do nothing;
insert into blocks (id, district_id, name, name_ta) values (1, 1, 'Udhagai', 'உதகை') on conflict do nothing;
insert into panchayats (id, block_id, name, name_ta) values (1, 1, 'Kookal', 'கூக்கல்') on conflict do nothing;
insert into habitations (id, panchayat_id, name, name_ta) values
  (1, 1, 'Kookal', 'கூக்கல்'), (2, 1, 'Uyilatty', 'உயிலட்டி'), (3, 1, 'Degili', 'தெகிலி'), (4, 1, 'Kurumudi', 'குறுமுடி'), (5, 1, 'Nerikambai', 'நெரிகம்பை')
on conflict do nothing;
insert into operators (id, panchayat_id, name, name_ta, phone) values
  (1, 1, 'Sivakumar', 'சிவகுமார்', '9000000001'),
  (2, 1, 'Gopal',     'கோபால்',    '9000000002'),
  (3, 1, 'Suresh',    'சுரேஷ்',    '9000000003'),
  (4, 1, 'Kantharaj', 'காந்தராஜ்',  '9000000004')
on conflict do nothing;
insert into glrs (habitation_id, operator_id, code, name, name_ta, location, capacity_l) values
  (1, 1, 'NLG-UDH-KKL-01', 'Kookal GLR 1',   'கூக்கல் தொட்டி 1',   'Near Hethaiyamman temple', 30000),
  (1, 1, 'NLG-UDH-KKL-02', 'Kookal GLR 2',   'கூக்கல் தொட்டி 2',   'Near Hethaiyamman temple', 30000),
  (2, 2, 'NLG-UDH-KKL-03', 'Uyilatty GLR 1', 'உயிலட்டி தொட்டி 1', 'Near main road', 30000),
  (2, 2, 'NLG-UDH-KKL-04', 'Uyilatty GLR 2', 'உயிலட்டி தொட்டி 2', 'Near main road', 30000),
  (2, 2, 'NLG-UDH-KKL-05', 'Uyilatty GLR 3', 'உயிலட்டி தொட்டி 3', 'Near main road', 30000),
  (3, 3, 'NLG-UDH-KKL-06', 'Degili GLR 1',   'தெகிலி தொட்டி 1',   'Near community hall', 30000),
  (3, 3, 'NLG-UDH-KKL-07', 'Degili GLR 2',   'தெகிலி தொட்டி 2',   'Near community hall', 30000),
  (3, 3, 'NLG-UDH-KKL-08', 'Degili GLR 3',   'தெகிலி தொட்டி 3',   'Near community hall', 30000),
  (4, 4, 'NLG-UDH-KKL-09', 'Kurumudi GLR 1', 'குறுமுடி தொட்டி 1', 'Near community hall', 30000),
  (4, 4, 'NLG-UDH-KKL-10', 'Kurumudi GLR 2', 'குறுமுடி தொட்டி 2', 'Near community hall', 30000),
  (5, 4, 'NLG-UDH-KKL-11', 'Nerikambai GLR', 'நெரிகம்பை தொட்டி',  'Near Mahendran house', 15000)
on conflict (code) do nothing;
select setval('districts_id_seq', (select max(id) from districts));
select setval('blocks_id_seq', (select max(id) from blocks));
select setval('panchayats_id_seq', (select max(id) from panchayats));
select setval('habitations_id_seq', (select max(id) from habitations));
select setval('operators_id_seq', (select max(id) from operators));
-- PINs are set by the panchayat officer from the review page (set_operator_pin). For a quick test:
-- select set_operator_pin(id, '1234') from operators;   -- run as a signed-in officer, or temporarily as postgres
