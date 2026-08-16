-- Distance alone gets US zones wrong.
--
-- Alaska, Hawaii and Puerto Rico are charged as the far zone whatever the
-- great-circle distance says, and territories and APO/FPO addresses run at a
-- flat 7 days. mailclock decides all of that from `region` and `isTerritory`,
-- so a profile that carries only lat/lng/tz/country cannot be scheduled
-- correctly. Both fields have to reach the engine, and both have to be
-- snapshotted onto the letter at collection like every other input.

alter table public.profiles
  add column if not exists region text;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'profiles_region_check') then
    alter table public.profiles
      add constraint profiles_region_check check (region is null or region ~ '^[A-Z]{2}$');
  end if;
end;
$$;

comment on column public.profiles.region is
  'US state or commonwealth code (ISO 3166-2 subdivision, no prefix), e.g. "AK". Only consulted for US parties.';

-- is_territory shipped unwritable, which left anyone in Guam or Puerto Rico
-- unable to describe where they actually live. Both fields are part of a user''s
-- own address, so both belong on the same client-writable surface as the city
-- label: getting them wrong only slows down that user''s own mail, and neither
-- is a schedule column.
grant insert (region, is_territory) on public.profiles to authenticated;
grant update (region, is_territory) on public.profiles to authenticated;

-- Snapshot targets. Nullable and defaulted so existing in-transit letters keep
-- the inputs they were actually scheduled with rather than inheriting today's.
alter table public.letters
  add column if not exists sender_region text,
  add column if not exists recipient_region text,
  add column if not exists recipient_is_territory boolean;

comment on column public.letters.sender_region is
  'Sender region as it stood at collection. Never re-read from the profile: a sender who moves must not retime mail already in the stream.';
comment on column public.letters.recipient_region is
  'Recipient region as it stood at collection.';
comment on column public.letters.recipient_is_territory is
  'Recipient territory flag as it stood at collection.';

-- The claim function's OUT parameters change, so it has to be dropped rather
-- than replaced.
drop function if exists public.claim_collection_batch(integer);

create function public.claim_collection_batch(p_limit integer default 200)
returns table (
  letter_id uuid,
  written_at timestamptz,
  sender_user_id uuid,
  sender_tz text,
  sender_lat double precision,
  sender_lng double precision,
  sender_country_code text,
  sender_region text,
  sender_is_territory boolean,
  recipient_user_id uuid,
  recipient_tz text,
  recipient_lat double precision,
  recipient_lng double precision,
  recipient_country_code text,
  recipient_region text,
  recipient_is_territory boolean
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  return query
  with due as (
    select l.id
    from public.letters l
    where l.state = 'awaiting_collection'
      and l.collect_at <= now()
      -- A claim older than the job interval means the previous worker died
      -- before applying its result; the letter is fair game again.
      and (l.collection_claimed_at is null or l.collection_claimed_at < now() - interval '15 minutes')
    order by l.collect_at
    limit p_limit
    for update skip locked
  ),
  claimed as (
    update public.letters l
       set collection_claimed_at = now()
      from due
     where l.id = due.id
       and l.state = 'awaiting_collection'
    returning l.*
  )
  select c.id,
         c.written_at,
         c.sender_id,
         sp.timezone,
         sp.home_lat,
         sp.home_lng,
         sp.country_code,
         sp.region,
         sp.is_territory,
         c.recipient_id,
         rp.timezone,
         rp.home_lat,
         rp.home_lng,
         rp.country_code,
         rp.region,
         rp.is_territory
  from claimed c
  join public.profiles sp on sp.id = c.sender_id
  join public.profiles rp on rp.id = c.recipient_id;
end;
$$;

revoke all on function public.claim_collection_batch(integer) from public;

create or replace function public.apply_collection(p_results jsonb)
returns table (applied integer, rescheduled integer)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_applied integer := 0;
  v_rescheduled integer := 0;
begin
  with payload as (
    select
      (r ->> 'letterId')::uuid           as letter_id,
      (r ->> 'collectedAt')::timestamptz as collected_at,
      (r ->> 'postmarkDate')::date       as postmark_date,
      (r ->> 'transitDays')::integer     as transit_days,
      (r ->> 'deliverAt')::timestamptz   as deliver_at,
      nullif(r ->> 'scheduleSource', '') as schedule_source,
      (r -> 'snapshot')                  as snapshot
    from jsonb_array_elements(p_results) as r
  ),
  -- The engine may report a collection instant still in the future, because
  -- the cheap SQL cutoff does not know about Sundays or federal holidays. Those
  -- letters stay in the postbox with the engine's corrected cutoff, which is
  -- how the exact rule reaches collect_at without being reimplemented here.
  future as (
    update public.letters l
       set collect_at = p.collected_at,
           collection_claimed_at = null
      from payload p
     where l.id = p.letter_id
       and l.state = 'awaiting_collection'
       and p.collected_at > now()
    returning l.id
  ),
  ready as (
    update public.letters l
       set state = 'in_transit',
           collected_at = p.collected_at,
           postmark_date = p.postmark_date,
           transit_days = p.transit_days,
           deliver_at = p.deliver_at,
           schedule_source = p.schedule_source,
           collection_claimed_at = null,
           sender_tz = p.snapshot ->> 'senderTz',
           sender_lat = (p.snapshot ->> 'senderLat')::double precision,
           sender_lng = (p.snapshot ->> 'senderLng')::double precision,
           sender_country_code = p.snapshot ->> 'senderCountryCode',
           sender_region = p.snapshot ->> 'senderRegion',
           sender_is_territory = (p.snapshot ->> 'senderIsTerritory')::boolean,
           recipient_tz = p.snapshot ->> 'recipientTz',
           recipient_lat = (p.snapshot ->> 'recipientLat')::double precision,
           recipient_lng = (p.snapshot ->> 'recipientLng')::double precision,
           recipient_country_code = p.snapshot ->> 'recipientCountryCode',
           recipient_region = p.snapshot ->> 'recipientRegion',
           recipient_is_territory = coalesce((p.snapshot ->> 'recipientIsTerritory')::boolean, false)
      from payload p
     where l.id = p.letter_id
       and l.state = 'awaiting_collection'
       and p.collected_at <= now()
    returning l.id
  )
  select (select count(*) from ready), (select count(*) from future)
    into v_applied, v_rescheduled;

  return query select v_applied, v_rescheduled;
end;
$$;

revoke all on function public.apply_collection(jsonb) from public;

-- The freeze list was a hand-written enumeration of every schedule column, and
-- adding sender_region / recipient_region / recipient_is_territory above would
-- have slipped straight past it: a sender who moved could have rewritten the
-- routing inputs of mail already in the stream, which is the exact failure the
-- snapshot exists to prevent. Enumerating what must not change fails open every
-- time the schema grows, so the rule is inverted here. After collection a
-- letter is frozen in full, and only the columns that describe what has since
-- happened to it are allowed to move.
create or replace function slowmail.guard_letter_write()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  -- Everything a letter learns *after* it was collected. Anything not named
  -- here is part of the letter or its schedule and is immutable.
  c_mutable_after_collection constant text[] := array[
    'state', 'delivered_at', 'read_at', 'collection_claimed_at', 'updated_at'
  ];
  v_changed text;
begin
  if tg_op = 'DELETE' then
    if old.collected_at is not null then
      raise exception 'letter % was collected on % and can no longer be deleted', old.id, old.collected_at
        using errcode = 'SM004';
    end if;
    return old;
  end if;

  -- Identity never moves, at any stage.
  if new.id is distinct from old.id
     or new.sender_id is distinct from old.sender_id
     or new.recipient_id is distinct from old.recipient_id then
    raise exception 'letter identity is immutable'
      using errcode = 'SM001';
  end if;

  -- The body is sealed the moment the letter leaves the writer's hands. Before
  -- that only a draft is editable; pulling a posted letter back means revoking
  -- it, not rewriting it.
  if new.body is distinct from old.body and old.state <> 'draft' then
    raise exception 'letter % is posted; its body can no longer be changed', old.id
      using errcode = 'SM003';
  end if;

  if old.collected_at is not null then
    select string_agg(o.key, ', ' order by o.key)
      into v_changed
    from jsonb_each(to_jsonb(old)) o
    join jsonb_each(to_jsonb(new)) n on n.key = o.key
    where o.value is distinct from n.value
      and not (o.key = any (c_mutable_after_collection));

    if v_changed is not null then
      raise exception 'letter % was collected on %; its contents and schedule are frozen (attempted to change: %)',
        old.id, old.collected_at, v_changed
        using errcode = 'SM001';
    end if;
  end if;

  -- Delivery and read receipts are write-once, forward-only.
  if old.delivered_at is not null and new.delivered_at is distinct from old.delivered_at then
    raise exception 'delivered_at is write-once' using errcode = 'SM001';
  end if;
  if old.read_at is not null and new.read_at is distinct from old.read_at then
    raise exception 'read_at is write-once' using errcode = 'SM001';
  end if;

  if old.state is distinct from new.state then
    if not (
      (old.state = 'draft' and new.state in ('awaiting_collection', 'revoked'))
      or (old.state = 'awaiting_collection' and new.state in ('in_transit', 'revoked'))
      or (old.state = 'in_transit' and new.state = 'delivered')
    ) then
      raise exception 'letter % cannot move from % to %', old.id, old.state, new.state
        using errcode = 'SM002';
    end if;
  end if;

  return new;
end;
$$;
