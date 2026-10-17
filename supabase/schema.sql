-- Neer Nilai: tank-level water supply monitoring
-- Hierarchy: district → block → panchayat → habitation → tank (a habitation can have several tanks).
-- A tank is a GLR (ground level reservoir) or an OHT (overhead tank); both live in table glrs, told apart by `kind`.
-- A habitation supplied by another body (e.g. Singara by TNEB) has no tanks and carries a supply_note instead.
-- Identity: each tank has a registered pump operator (name + mobile number, from the block's list).
--   Operator signs in with mobile number + 4-digit PIN given by the panchayat officer. One phone per operator.
--   Panchayat officer reviews; block/district officers watch the dashboard. Staff are registered by email in officer_invites.
-- Run in the Supabase SQL editor. Safe to re-run. Then run supabase/private/*.sql (real phone numbers, staff emails).

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------- master data
create table if not exists districts   (id serial primary key, name text not null, name_ta text);
create table if not exists blocks      (id serial primary key, district_id int not null references districts(id), name text not null, name_ta text);
create table if not exists panchayats  (id serial primary key, block_id int not null references blocks(id), name text not null, name_ta text);
create table if not exists habitations (id serial primary key, panchayat_id int not null references panchayats(id), name text not null, name_ta text,
                                        supply_note text);   -- e.g. 'TNEB': water from another body, nothing to report
alter table habitations add column if not exists supply_note text;

-- Pump operators: the people who use the app. Phone number is the identity.
create table if not exists operators (
  id               serial primary key,
  panchayat_id     int not null references panchayats(id),
  name             text not null,
  name_ta          text,
  phone            text not null unique check (phone ~ '^[6-9][0-9]{9}$'),   -- 10-digit Indian mobile
  pin_hash         text,                                                      -- bcrypt of the 4-digit PIN, set by panchayat officer
  pin_fails        int not null default 0,                                    -- wrong PINs since the last good one
  pin_locked_until timestamptz,                                               -- set after 5 wrong PINs
  device_id        text,                                                      -- (older versions: plain device id; no longer used)
  device_hash      text,                                                      -- sha256 of the bound phone's secret; reset by panchayat officer
  device_bound_at  timestamptz,
  active           boolean not null default true
);
alter table operators add column if not exists pin_fails int not null default 0;
alter table operators add column if not exists pin_locked_until timestamptz;
alter table operators add column if not exists device_hash text;

create table if not exists glrs (
  id             serial primary key,
  habitation_id  int not null references habitations(id),
  operator_id    int references operators(id),
  kind           text not null default 'GLR' check (kind in ('GLR','OHT')),
  code           text not null unique,        -- e.g. NLG-UDH-KKL-01
  name           text not null,
  name_ta        text,
  location       text,                        -- "Near Hethaiyamman temple"
  capacity_l     int,                         -- litres
  scheme         text,
  supply_window  text,
  active         boolean not null default true
);
alter table glrs add column if not exists kind text not null default 'GLR' check (kind in ('GLR','OHT'));
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
  ('pipe_source', 'Source-to-tank pipeline',       'ஆதாரம் → தொட்டி குழாய்',       7),
  ('pipe_dist',   'Distribution pipeline / valve', 'விநியோகக் குழாய் / வால்வு',    8),
  ('other',       'Other',                         'மற்றவை',                       9)
on conflict (code) do update set label_en = excluded.label_en, label_ta = excluded.label_ta, sort = excluded.sort;

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

-- Register staff by email. Their first magic-link sign-in creates the officers row (trigger below);
-- apply_officer_invites() does the same for people who signed in before they were registered.
create table if not exists officer_invites (
  email          text primary key,
  name           text not null,
  role           text not null check (role in ('state','district','block','panchayat')),
  district_id    int references districts(id),
  block_id       int references blocks(id),
  panchayat_id   int references panchayats(id)
);

-- One-time WhatsApp links: the panchayat officer sends one to the operator's registered number; opening it signs the
-- operator in on that phone with no typing. Only a hash of the code is stored; a code works once, for 7 days.
create table if not exists operator_links (
  code_hash      text primary key,
  operator_id    int not null references operators(id) on delete cascade,
  created_by     uuid references officers(id),
  created_at     timestamptz not null default now(),
  expires_at     timestamptz not null default now() + interval '7 days',
  used_at        timestamptz
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
  lat            double precision,             -- where the phone was when the operator reported (null: no permission / no fix)
  lng            double precision,
  loc_accuracy   real,                         -- metres
  unique (glr_id, report_date)
);
alter table reports add column if not exists lat double precision;
alter table reports add column if not exists lng double precision;
alter table reports add column if not exists loc_accuracy real;
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

-- Dropped first so a re-run can add columns (kind) without "cannot change name of view column".
drop view if exists v_today;
drop view if exists v_glr;
create view v_glr as
select g.id as glr_id, g.kind, g.code, g.name as glr, g.name_ta as glr_ta, g.location, g.capacity_l as capacity, g.scheme, g.supply_window, g.active,
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

-- ---------------------------------------------------------------- operator functions (called with the public anon key)
-- Earlier versions raised on a wrong PIN; these return a code instead so the failure count is saved.
drop function if exists operator_check(text, text, text);
drop function if exists operator_login(text, text, text);
drop function if exists submit_report(text, text, text, int, text, text);
drop function if exists attach_voice(text, text, int, text);
drop function if exists operator_history(text, text, int);
drop function if exists submit_reports(text, text, text, int[], text, text);   -- gained location parameters

-- The operator's phone is the key. Each install makes a long random secret (p_device); the server keeps only its hash.
-- Returns the operator id, or 0 = not recognised / wrong PIN, -1 = locked, -2 = number bound to another phone.
--   1. The bound phone is recognised by its secret alone: no PIN, nothing to type, ever.
--   2. Otherwise a PIN is needed (fallback for an operator without WhatsApp); a correct PIN binds this phone if none is bound.
--   5 wrong PINs lock the number for 15 minutes, then one try per 15 minutes until a correct PIN or a new PIN.
--   A lock never blocks the already-bound phone, so guessing cannot shut the real operator out.
create or replace function operator_auth(p_phone text, p_pin text, p_device text) returns int
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare v operators; h text;
begin
  select * into v from operators where phone = p_phone and active;
  if v.id is null or coalesce(length(p_device), 0) < 20 then return 0; end if;
  h := encode(digest(p_device, 'sha256'), 'hex');
  if v.device_hash = h then
    if v.pin_fails > 0 then update operators set pin_fails = 0, pin_locked_until = null where id = v.id; end if;
    return v.id;
  end if;
  if v.pin_locked_until > now() then return -1; end if;
  if v.pin_hash is null or p_pin is null or v.pin_hash <> crypt(p_pin, v.pin_hash) then
    if p_pin is not null then
      update operators set pin_fails = pin_fails + 1,
          pin_locked_until = case when pin_fails + 1 >= 5 then now() + interval '15 minutes' end
      where id = v.id;
    end if;
    return 0;
  end if;
  if v.device_hash is not null then return -2; end if;
  update operators set pin_fails = 0, pin_locked_until = null, device_hash = h, device_bound_at = now() where id = v.id;
  return v.id;
end $$;

-- Opening a WhatsApp link: a new link binds this phone (replacing any earlier one) and returns the operator's tanks.
-- A used or expired link still opens the app on the phone it bound (operators tap the same message every day),
-- and nowhere else. err = 'link' otherwise.
create or replace function operator_join(p_code text, p_device text)
returns table (err text, operator_phone text, operator_id int, operator_name text, operator_name_ta text,
               glr_id int, kind text, code text, glr text, glr_ta text, location text, capacity int,
               habitation text, habitation_ta text, panchayat_id int, panchayat text, panchayat_ta text,
               block text, block_ta text, district text, district_ta text)
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare v_link operator_links; v_phone text; h text;
begin
  if coalesce(length(p_device), 0) < 20 then err := 'link'; return next; return; end if;
  h := encode(digest(p_device, 'sha256'), 'hex');
  select * into v_link from operator_links l where l.code_hash = encode(digest(coalesce(p_code, ''), 'sha256'), 'hex');
  if v_link.operator_id is null then err := 'link'; return next; return; end if;
  if v_link.used_at is null and v_link.expires_at > now() then
    update operator_links set used_at = now() where code_hash = v_link.code_hash;
    update operators o set device_hash = h, device_bound_at = now(), pin_fails = 0, pin_locked_until = null
    where o.id = v_link.operator_id and o.active returning o.phone into v_phone;
  else
    select o.phone into v_phone from operators o where o.id = v_link.operator_id and o.active and o.device_hash = h;
  end if;
  if v_phone is null then err := 'link'; return next; return; end if;
  return query
    select null::text, v_phone, v.operator_id, v.operator_name, v.operator_name_ta, v.glr_id, v.kind, v.code, v.glr, v.glr_ta, v.location, v.capacity,
           v.habitation, v.habitation_ta, v.panchayat_id, v.panchayat, v.panchayat_ta, v.block, v.block_ta, v.district, v.district_ta
    from v_glr v where v.operator_id = v_link.operator_id and v.active order by v.code;
end $$;

create or replace function auth_code(p int) returns text
language sql immutable as $$ select case p when -1 then 'locked' when -2 then 'device' else 'bad' end $$;

-- Sign-in: one row per tank (GLR or OHT) the operator looks after; on failure a single row with err set.
create function operator_login(p_phone text, p_pin text, p_device text)
returns table (err text, operator_id int, operator_name text, operator_name_ta text,
               glr_id int, kind text, code text, glr text, glr_ta text, location text, capacity int,
               habitation text, habitation_ta text, panchayat_id int, panchayat text, panchayat_ta text,
               block text, block_ta text, district text, district_ta text)
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare v_oid int;
begin
  v_oid := operator_auth(p_phone, p_pin, p_device);
  if v_oid <= 0 then err := auth_code(v_oid); return next; return; end if;
  return query
    select null::text, v.operator_id, v.operator_name, v.operator_name_ta, v.glr_id, v.kind, v.code, v.glr, v.glr_ta, v.location, v.capacity,
           v.habitation, v.habitation_ta, v.panchayat_id, v.panchayat, v.panchayat_ta, v.block, v.block_ta, v.district, v.district_ta
    from v_glr v where v.operator_id = v_oid and v.active order by v.code;
end $$;

-- Daily report: one status (+ one pictorial problem) for one or more tanks, in a single call, so an operator with
-- 12 tanks on a slow village network waits for one round trip. Same-day resubmit overwrites and resets the review.
-- Returns 'ok', or 'bad' / 'locked' / 'device'; raises only for a malformed request.
-- p_lat / p_lng / p_acc: where the phone was (null when the operator denied location or there was no fix).
create or replace function submit_reports(p_phone text, p_pin text, p_device text, p_glr_ids int[], p_status text, p_problem text default null,
                               p_lat double precision default null, p_lng double precision default null, p_acc real default null)
returns text
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare v_oid int;
begin
  v_oid := operator_auth(p_phone, p_pin, p_device);
  if v_oid <= 0 then return auth_code(v_oid); end if;
  if coalesce(cardinality(p_glr_ids), 0) = 0 then raise exception 'no tanks' using errcode = '23514'; end if;
  if exists (select 1 from unnest(p_glr_ids) t(id) where not exists (select 1 from glrs g where g.id = t.id and g.operator_id = v_oid and g.active)) then
    raise exception 'tank not assigned to this operator' using errcode = '42501';
  end if;
  if p_status not in ('yes','partial','no') then raise exception 'bad status' using errcode = '23514'; end if;
  if p_status = 'yes' then p_problem := null; elsif p_problem is null then raise exception 'problem required' using errcode = '23514'; end if;

  if p_lat is not null and (p_lat not between -90 and 90 or p_lng not between -180 and 180) then p_lat := null; p_lng := null; p_acc := null; end if;
  insert into reports (glr_id, report_date, status, problem, operator_id, device_id, entered_by, lat, lng, loc_accuracy)
  select distinct t.id, ist_today(), p_status, p_problem, v_oid, left(encode(digest(p_device, 'sha256'), 'hex'), 12), 'operator', p_lat, p_lng, p_acc
  from unnest(p_glr_ids) t(id)
  on conflict (glr_id, report_date) do update
    set status = excluded.status, problem = excluded.problem, source_ok = null, pump_ok = null, glr_filled = null,
        operator_id = excluded.operator_id, device_id = excluded.device_id, entered_by = 'operator', reported_at = now(),
        lat = excluded.lat, lng = excluded.lng, loc_accuracy = excluded.loc_accuracy,
        review_status = 'pending', review_note = null, reviewed_by = null, reviewed_at = null;
  return 'ok';
end $$;

-- Single tank (kept for reports queued offline by an older version of the app).
create function submit_report(p_phone text, p_pin text, p_device text, p_glr_id int, p_status text, p_problem text default null)
returns text
language sql security definer set search_path = public, extensions, pg_temp as $$
  select submit_reports(p_phone, p_pin, p_device, array[p_glr_id], p_status, p_problem) $$;

-- Panchayat officer: a fresh one-time link for an operator (earlier unused links stop working).
create or replace function create_operator_link(p_operator_id int) returns text
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare v_code text;
begin
  if not can_see_panchayat((select panchayat_id from operators where id = p_operator_id)) then raise exception 'not allowed' using errcode = '42501'; end if;
  v_code := translate(encode(gen_random_bytes(12), 'base64'), '+/=', '-_');   -- 96 bits, URL-safe
  delete from operator_links where operator_id = p_operator_id and used_at is null;
  insert into operator_links (code_hash, operator_id, created_by) values (encode(digest(v_code, 'sha256'), 'hex'), p_operator_id, auth.uid());
  return v_code;
end $$;

create or replace function attach_voice(p_phone text, p_pin text, p_device text, p_glr_id int, p_path text) returns text
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare v_oid int;
begin
  v_oid := operator_auth(p_phone, p_pin, p_device);
  if v_oid <= 0 then return auth_code(v_oid); end if;
  update reports set voice_path = p_path where glr_id = p_glr_id and report_date = ist_today() and operator_id = v_oid;
  return 'ok';
end $$;

-- Last 14 days for every tank of the operator, in one call.
create or replace function operator_history_all(p_phone text, p_pin text, p_device text)
returns table (glr_id int, report_date date, status text, problem text, remarks text, voice_path text, reported_at timestamptz)
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare v_oid int;
begin
  v_oid := operator_auth(p_phone, p_pin, p_device);
  if v_oid <= 0 then return; end if;
  return query select r.glr_id, r.report_date, r.status, r.problem, r.remarks, r.voice_path, r.reported_at
    from reports r join glrs g on g.id = r.glr_id
    where g.operator_id = v_oid and r.report_date >= ist_today() - 13 order by r.report_date;
end $$;

revoke execute on function operator_auth(text, text, text) from public, anon, authenticated;
grant execute on function operator_login(text, text, text) to anon, authenticated;
grant execute on function submit_reports(text, text, text, int[], text, text, double precision, double precision, real) to anon, authenticated;
grant execute on function operator_join(text, text) to anon, authenticated;
revoke execute on function create_operator_link(int) from public, anon;
grant execute on function create_operator_link(int) to authenticated;
grant execute on function submit_report(text, text, text, int, text, text) to anon, authenticated;
grant execute on function attach_voice(text, text, text, int, text) to anon, authenticated;
grant execute on function operator_history_all(text, text, text) to anon, authenticated;

-- Voice notes bucket
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('voice', 'voice', false, 2097152, array['audio/webm','audio/mp4','audio/ogg','audio/mpeg','audio/wav'])
on conflict (id) do nothing;
drop policy if exists voice_upload on storage.objects;  create policy voice_upload on storage.objects for insert to anon with check (bucket_id = 'voice');
drop policy if exists voice_replace on storage.objects; create policy voice_replace on storage.objects for update to anon using (bucket_id = 'voice');
drop policy if exists voice_read on storage.objects;    create policy voice_read on storage.objects for select to authenticated using (bucket_id = 'voice');

-- ---------------------------------------------------------------- officer scope
create or replace function officer_scope() returns table (role text, district_id int, block_id int, panchayat_id int)
language sql stable security definer set search_path = public, pg_temp as $$
  select o.role, o.district_id, o.block_id, o.panchayat_id from officers o where o.id = auth.uid() $$;

create or replace function can_see_panchayat(p_panchayat_id int) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (
    select 1 from officer_scope() s join panchayats p on p.id = p_panchayat_id join blocks b on b.id = p.block_id
    where s.role = 'state' or (s.role = 'district' and b.district_id = s.district_id)
       or (s.role = 'block' and p.block_id = s.block_id) or (s.role = 'panchayat' and p.id = s.panchayat_id))
$$;
create or replace function can_see_glr(p_glr_id int) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$ select can_see_panchayat((select panchayat_id from v_glr where glr_id = p_glr_id)) $$;

-- Operators visible to the signed-in officer (no PIN or phone secret, only whether a phone is linked).
drop view if exists v_operators;
create view v_operators as
select o.id, o.panchayat_id, o.name, o.name_ta, o.phone, (o.device_hash is not null) as bound, o.device_bound_at, o.active,
       (select count(*) from glrs g where g.operator_id = o.id and g.active) as glr_count,
       (select max(l.created_at) from operator_links l where l.operator_id = o.id) as last_link_at
from operators o where o.active and can_see_panchayat(o.panchayat_id);

-- Panchayat officer sets / resets an operator's PIN (also clears a lockout) and phone binding.
create or replace function set_operator_pin(p_operator_id int, p_pin text) returns void
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
begin
  if not can_see_panchayat((select panchayat_id from operators where id = p_operator_id)) then raise exception 'not allowed' using errcode = '42501'; end if;
  if p_pin !~ '^[0-9]{4}$' then raise exception 'pin must be 4 digits' using errcode = '23514'; end if;
  update operators set pin_hash = crypt(p_pin, gen_salt('bf')), pin_fails = 0, pin_locked_until = null where id = p_operator_id;
end $$;
create or replace function reset_operator_device(p_operator_id int) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not can_see_panchayat((select panchayat_id from operators where id = p_operator_id)) then raise exception 'not allowed' using errcode = '42501'; end if;
  update operators set device_id = null, device_hash = null, device_bound_at = null where id = p_operator_id;
end $$;
grant execute on function set_operator_pin(int, text) to authenticated;
grant execute on function reset_operator_device(int) to authenticated;

-- Review: confirm/flag + diagnostics + refined problem + action taken.
create or replace function review_report(
  p_report_id bigint, p_status text, p_note text default null,
  p_source_ok text default null, p_pump_ok text default null, p_glr_filled text default null, p_problem text default null
) returns reports
language plpgsql security definer set search_path = public, pg_temp as $$
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
language plpgsql security definer set search_path = public, pg_temp as $$
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

-- Today's status for every tank in scope, including silent ones.
create view v_today as
select v.*,
  r.id as report_id, coalesce(r.status, 'not_reported') as status,
  r.problem, r.source_ok, r.pump_ok, r.glr_filled, r.remarks, r.voice_path, r.entered_by, r.reported_at,
  r.review_status, r.review_note, r.reviewed_at, r.lat, r.lng, r.loc_accuracy
from v_glr v
left join reports r on r.glr_id = v.glr_id and r.report_date = ist_today()
where v.active and can_see_panchayat(v.panchayat_id);

-- ---------------------------------------------------------------- staff registration
create or replace function apply_officer_invites() returns int
language plpgsql security definer set search_path = public, pg_temp as $$
declare n int;
begin
  insert into officers (id, name, role, district_id, block_id, panchayat_id, email)
  select u.id, i.name, i.role, i.district_id, i.block_id, i.panchayat_id, u.email
  from auth.users u join officer_invites i on lower(i.email) = lower(u.email)
  on conflict (id) do update set name = excluded.name, role = excluded.role, district_id = excluded.district_id,
      block_id = excluded.block_id, panchayat_id = excluded.panchayat_id, email = excluded.email;
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function claim_officer_invite() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  insert into officers (id, name, role, district_id, block_id, panchayat_id, email)
  select new.id, i.name, i.role, i.district_id, i.block_id, i.panchayat_id, new.email
  from officer_invites i where lower(i.email) = lower(new.email)
  on conflict (id) do nothing;
  return new;
end $$;
drop trigger if exists neer_nilai_claim_invite on auth.users;
create trigger neer_nilai_claim_invite after insert on auth.users for each row execute function claim_officer_invite();
revoke execute on function apply_officer_invites() from public, anon, authenticated;
revoke execute on function claim_officer_invite() from public, anon, authenticated;

-- ---------------------------------------------------------------- row-level security and grants
alter table reports enable row level security;
alter table glrs enable row level security;
alter table operators enable row level security;
alter table habitations enable row level security;
alter table panchayats enable row level security;
alter table blocks enable row level security;
alter table districts enable row level security;
alter table officers enable row level security;
alter table officer_invites enable row level security;
alter table operator_links enable row level security;
alter table notifications enable row level security;
alter table problems enable row level security;

drop policy if exists read_districts on districts;     create policy read_districts on districts for select using (true);
drop policy if exists read_blocks on blocks;           create policy read_blocks on blocks for select using (true);
drop policy if exists read_panchayats on panchayats;   create policy read_panchayats on panchayats for select using (true);
drop policy if exists read_habitations on habitations; create policy read_habitations on habitations for select using (true);
drop policy if exists read_glrs on glrs;               create policy read_glrs on glrs for select using (true);
drop policy if exists read_problems on problems;       create policy read_problems on problems for select using (true);
drop policy if exists officer_read_operators on operators;   -- operators are read only through v_operators and the functions above
drop policy if exists officer_read_reports on reports;
create policy officer_read_reports on reports for select to authenticated using (can_see_glr(glr_id));
drop policy if exists officer_read_self on officers;
create policy officer_read_self on officers for select to authenticated using (id = auth.uid());
drop policy if exists officer_update_self on officers;
create policy officer_update_self on officers for update to authenticated using (id = auth.uid()) with check (id = auth.uid());
drop policy if exists officer_read_notifications on notifications;
create policy officer_read_notifications on notifications for select to authenticated using (officer_id = auth.uid());

-- Supabase grants the public anon key (and signed-in staff) everything on new tables and views by default; RLS above
-- covers the tables, these close what RLS does not: views run as their owner, and column-level limits.
revoke all on v_glr from anon, authenticated;                 -- has every operator's phone number
revoke all on v_today, v_operators from anon;                 -- staff only (they filter by the signed-in officer anyway)
revoke all on operators from anon, authenticated;             -- pin_hash, phone numbers
revoke all on officer_invites from anon, authenticated;
revoke all on operator_links from anon, authenticated;             -- code hashes; links are made and used only through the functions
revoke insert, update, delete on officers from authenticated;
grant update (alert_email, alert_whatsapp, alert_digest) on officers to authenticated;   -- only their own alert settings, never role or scope

-- ---------------------------------------------------------------- alerts
-- Database → Webhooks: table reports, INSERT + UPDATE → notify edge function.
-- Noon digest (12:00 IST = 06:30 UTC). Enable pg_cron and pg_net first (Dashboard → Database → Extensions),
-- then replace <PROJECT_REF> and <SERVICE_ROLE_KEY>:
-- select cron.schedule('neer-nilai-digest', '30 6 * * *', $$
--   select net.http_post(url := 'https://<PROJECT_REF>.supabase.co/functions/v1/notify',
--     headers := '{"Content-Type":"application/json","Authorization":"Bearer <SERVICE_ROLE_KEY>"}'::jsonb,
--     body := '{"type":"digest"}'::jsonb);
-- $$);

-- ---------------------------------------------------------------- pilot data: Kookal (Udhagai block) and Masinagudi (Gudalur block), from the block sheets
-- Phone numbers here are 90000000xx placeholders (this file is public). Put the real ones in with
-- supabase/private/live-data.sql (git-ignored, also registers staff) after running this file in the live project.
insert into districts (id, name, name_ta) values (1, 'The Nilgiris', 'நீலகிரி') on conflict do nothing;
insert into blocks (id, district_id, name, name_ta) values (1, 1, 'Udhagai', 'உதகை'), (2, 1, 'Gudalur', 'கூடலூர்') on conflict do nothing;
insert into panchayats (id, block_id, name, name_ta) values (1, 1, 'Kookal', 'கூக்கல்'), (2, 2, 'Masinagudi', 'மசினகுடி') on conflict do nothing;
insert into habitations (id, panchayat_id, name, name_ta, supply_note) values
  (1, 1, 'Kookal', 'கூக்கல்', null), (2, 1, 'Uyilatty', 'உயிலட்டி', null), (3, 1, 'Degili', 'தெகிலி', null), (4, 1, 'Kurumudi', 'குறுமுடி', null), (5, 1, 'Nerikambai', 'நெரிகம்பை', null),
  (6, 2, 'Achakarai', 'அச்சக்கரை', null), (7, 2, 'Masinagudi', 'மசினகுடி', null), (8, 2, 'Boothanatham', 'பூதநத்தம்', null), (9, 2, 'Moyar', 'மாயார்', null),
  (10, 2, 'Singara', 'சிங்காரா', 'TNEB'), (11, 2, 'Theppakadu', 'தெப்பக்காடு', null)
on conflict do nothing;
insert into operators (id, panchayat_id, name, name_ta, phone) values
  (1, 1, 'Sivakumar', 'சிவகுமார்', '9000000001'),
  (2, 1, 'Gopal',     'கோபால்',    '9000000002'),
  (3, 1, 'Suresh',    'சுரேஷ்',    '9000000003'),
  (4, 1, 'Kantharaj', 'காந்தராஜ்',  '9000000004'),
  (5, 2, 'Ramesh',          'ரமேஷ்',            '9000000005'),
  (6, 2, 'Sidick Shameer',  'சித்திக் ஷமீர்',    '9000000006'),
  (7, 2, 'Manigandan',      'மணிகண்டன்',        '9000000007'),
  (8, 2, 'Ragavendran',     'ராகவேந்திரன்',     '9000000008'),
  (9, 2, 'Maran / Badichi', 'மாறன் / பாடிச்சி',  '9000000009')   -- two people, one phone on the sheet: one account
on conflict do nothing;
insert into glrs (habitation_id, operator_id, kind, code, name, name_ta, location, capacity_l) values
  (1, 1, 'GLR', 'NLG-UDH-KKL-01', 'Kookal 1',   'கூக்கல் 1',   'Near Hethaiyamman temple', 30000),
  (1, 1, 'GLR', 'NLG-UDH-KKL-02', 'Kookal 2',   'கூக்கல் 2',   'Near Hethaiyamman temple', 30000),
  (2, 2, 'GLR', 'NLG-UDH-KKL-03', 'Uyilatty 1', 'உயிலட்டி 1', 'Near main road', 30000),
  (2, 2, 'GLR', 'NLG-UDH-KKL-04', 'Uyilatty 2', 'உயிலட்டி 2', 'Near main road', 30000),
  (2, 2, 'GLR', 'NLG-UDH-KKL-05', 'Uyilatty 3', 'உயிலட்டி 3', 'Near main road', 30000),
  (3, 3, 'GLR', 'NLG-UDH-KKL-06', 'Degili 1',   'தெகிலி 1',   'Near community hall', 30000),
  (3, 3, 'GLR', 'NLG-UDH-KKL-07', 'Degili 2',   'தெகிலி 2',   'Near community hall', 30000),
  (3, 3, 'GLR', 'NLG-UDH-KKL-08', 'Degili 3',   'தெகிலி 3',   'Near community hall', 30000),
  (4, 4, 'GLR', 'NLG-UDH-KKL-09', 'Kurumudi 1', 'குறுமுடி 1', 'Near community hall', 30000),
  (4, 4, 'GLR', 'NLG-UDH-KKL-10', 'Kurumudi 2', 'குறுமுடி 2', 'Near community hall', 30000),
  (5, 4, 'GLR', 'NLG-UDH-KKL-11', 'Nerikambai', 'நெரிகம்பை',  'Near Mahendran house', 15000),
  -- Masinagudi: 9 GLR + 12 OHT. Location keeps the sheet's wording; name is the short label operators see.
  (6,  5, 'GLR', 'NLG-GDL-MSG-01', 'Achakarai',          'அச்சக்கரை',           null, 30000),
  (6,  5, 'GLR', 'NLG-GDL-MSG-02', 'ST Colony',          'ST காலனி',             'Achakkarai ST Colony', 20000),
  (7,  6, 'GLR', 'NLG-GDL-MSG-03', 'Water Board',        'குடிநீர் வாரியம்',      'Masinagudi Water Board', 60000),
  (7,  6, 'GLR', 'NLG-GDL-MSG-04', 'Group House',        'தொகுப்பு வீடுகள்',      'Group House Masinagudi', 30000),
  (7,  6, 'GLR', 'NLG-GDL-MSG-05', 'ST Colony',          'ST காலனி',             'ST colony Masinagudi', 30000),
  (7,  6, 'GLR', 'NLG-GDL-MSG-06', 'Vinayagar Kovil St', 'விநாயகர் கோவில் தெரு',  'Masinagudi Vinayagar kovil Street', 30000),
  (7,  6, 'OHT', 'NLG-GDL-MSG-07', 'Water Board',        'குடிநீர் வாரியம்',      'Masinagudi water Board', 40000),
  (7,  6, 'OHT', 'NLG-GDL-MSG-08', 'Sivakumar Colony 1', 'சிவகுமார் காலனி 1',     'Sivakumar Colony', 60000),
  (7,  6, 'OHT', 'NLG-GDL-MSG-09', 'Sivakumar Colony 2', 'சிவகுமார் காலனி 2',     'Masinagudi Sivakumar Colony', 60000),
  (7,  6, 'OHT', 'NLG-GDL-MSG-10', 'Indra Colony',       'இந்திரா காலனி',         'Indra Colony Masinagudi', 60000),
  (7,  6, 'OHT', 'NLG-GDL-MSG-11', 'Moyar Road',         'மாயார் சாலை',          'Moyar Road, Masinagudi', 60000),
  (7,  6, 'OHT', 'NLG-GDL-MSG-12', 'Police Station',     'காவல் நிலையம்',         'Near Police Station', 30000),
  (7,  6, 'OHT', 'NLG-GDL-MSG-13', 'Govt School',        'அரசுப் பள்ளி',          'Government School', 30000),
  (7,  6, 'OHT', 'NLG-GDL-MSG-14', 'PMAY Houses',        'PMAY வீடுகள்',          'PMAY House', 60000),
  (8,  7, 'GLR', 'NLG-GDL-MSG-15', 'Sivan Temple',       'சிவன் கோவில்',          null, 30000),
  (8,  7, 'GLR', 'NLG-GDL-MSG-16', 'Keel Boothanatham',  'கீழ் பூதநத்தம்',         null, 30000),
  (8,  7, 'OHT', 'NLG-GDL-MSG-17', 'Mel Boothanatham',   'மேல் பூதநத்தம்',         null, 30000),
  (8,  7, 'OHT', 'NLG-GDL-MSG-18', 'Kel Boothanatham',   'கீழ் பூதநத்தம்',         null, 20000),
  (9,  8, 'OHT', 'NLG-GDL-MSG-19', 'Selvappa Colony',    'செல்வப்பா காலனி',        'Selvappa Colony Moyar', 30000),
  (9,  8, 'OHT', 'NLG-GDL-MSG-20', 'Undi Moyar',         'உண்டி மாயார்',          null, 60000),
  (11, 9, 'GLR', 'NLG-GDL-MSG-21', 'Yanaipadi',          'யானைப்பாடி',            null, 30000)
on conflict (code) do nothing;
select setval('districts_id_seq', (select max(id) from districts));
select setval('blocks_id_seq', (select max(id) from blocks));
select setval('panchayats_id_seq', (select max(id) from panchayats));
select setval('habitations_id_seq', (select max(id) from habitations));
select setval('operators_id_seq', (select max(id) from operators));
-- PINs are set by the panchayat officer from the review page (set_operator_pin).
