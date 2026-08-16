-- Profiles and devices.

create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  display_name text not null check (char_length(btrim(display_name)) between 1 and 80),
  home_city_label text check (char_length(home_city_label) <= 120),
  home_lat double precision check (home_lat between -90 and 90),
  home_lng double precision check (home_lng between -180 and 180),
  -- IANA zone id; validated against pg_timezone_names by a trigger because a
  -- CHECK cannot call a non-immutable catalog lookup.
  timezone text not null default 'UTC',
  country_code text not null default 'US' check (country_code ~ '^[A-Z]{2}$'),
  -- US territories (PR, VI, GU, AS, MP) route as domestic mail but with a
  -- fixed longer transit band, so the routing engine needs it called out.
  is_territory boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  -- Either both coordinates or neither; a half-located profile cannot be routed.
  constraint profiles_coords_paired check (num_nonnulls(home_lat, home_lng) <> 1)
);

comment on table public.profiles is 'One row per auth user. Routing inputs live here, but letters snapshot them at collection.';

create or replace function slowmail.assert_valid_timezone()
returns trigger
language plpgsql
as $$
begin
  if not exists (select 1 from pg_catalog.pg_timezone_names where name = new.timezone) then
    raise exception 'invalid IANA timezone: %', new.timezone
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

create trigger profiles_timezone_valid
  before insert or update of timezone on public.profiles
  for each row execute function slowmail.assert_valid_timezone();

create or replace function slowmail.touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger profiles_touch_updated_at
  before update on public.profiles
  for each row execute function slowmail.touch_updated_at();

-- People carry more than one device, and tokens rotate, so devices are rows.
create table if not exists public.devices (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  apns_token text not null check (apns_token ~ '^[0-9a-fA-F]{64,200}$'),
  environment text not null default 'production' check (environment in ('sandbox', 'production')),
  created_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  revoked_at timestamptz,
  revoked_reason text
);

-- A token identifies one app install. If it reappears under another user the
-- install was handed over, so ownership moves rather than duplicating.
create unique index if not exists devices_apns_token_key on public.devices (apns_token);
create index if not exists devices_active_by_user on public.devices (user_id) where revoked_at is null;

comment on table public.devices is 'APNs tokens per user. Written only through public.register_device so a duplicate token cannot be used to probe for other installs.';

alter table public.profiles enable row level security;
alter table public.devices enable row level security;
alter table public.profiles force row level security;
alter table public.devices force row level security;

revoke all on public.profiles from anon, authenticated;
revoke all on public.devices from anon, authenticated;

grant select on public.profiles to authenticated;
grant insert (id, display_name, home_city_label, home_lat, home_lng, timezone, country_code) on public.profiles to authenticated;
grant update (display_name, home_city_label, home_lat, home_lng, timezone, country_code) on public.profiles to authenticated;

-- Devices are read-only to their owner; all writes go through register_device.
grant select on public.devices to authenticated;

create policy profiles_select_self on public.profiles
  for select to authenticated
  using (id = (select auth.uid()));

-- The correspondent-visibility policy on profiles is added alongside the
-- correspondents table, which does not exist yet at this point.

create policy profiles_insert_self on public.profiles
  for insert to authenticated
  with check (id = (select auth.uid()));

create policy profiles_update_self on public.profiles
  for update to authenticated
  using (id = (select auth.uid()))
  with check (id = (select auth.uid()));

create policy devices_select_self on public.devices
  for select to authenticated
  using (user_id = (select auth.uid()));
