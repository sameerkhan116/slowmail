-- One arrival instant per recipient per day.
--
-- mailclock seeds the carrier's minute offset on (userId, localDate), so its
-- docstring promises that "every letter due that day arrives together". Turning
-- that offset into an instant needs a zone, and the zone is a separate argument.
-- Two letters can therefore share a recipient and a delivery date and still land
-- hours apart:
--
--   carrierArrival(u, '2026-11-01', 'America/New_York')    -> 15:16Z
--   carrierArrival(u, '2026-11-01', 'America/Los_Angeles') -> 18:16Z
--   carrierArrival(u, '2026-11-01', 'Pacific/Kiritimati')  -> 2026-10-31T20:16Z
--
-- Each letter freezes the recipient's zone at posting -- correctly, so that a
-- recipient cannot retime mail already addressed to them -- so two letters
-- posted either side of a move carry different zones and split the day's post
-- into two arrivals. The mailbox says the post has come, and then more post
-- comes. Worse, run_delivery folds both into one (recipient_id, delivery_date)
-- outbox row, so the second arrival can happen with no notification at all.
--
-- The engine cannot fix this alone: an arrival between 09:00 and 17:00 *local*
-- needs a zone, so the zone must be an input, and it is the caller's job to hand
-- it the same one for every letter in a bundle. That is what this table does.
--
-- WHICH ZONE DECIDES.
-- Not the per-letter snapshot: two letters can disagree, which is the bug. The
-- recipient's live zone at the moment the bundle is first written, because the
-- two questions are different ones. How long the post takes was settled when it
-- was posted and must never move -- that is transit, and it stays frozen on the
-- envelope. What time the carrier reaches the door is a fact about where the
-- recipient is standing on the day. A recipient who has moved to Los Angeles
-- and is served on New York time gets their post at 06:16, which is not a time
-- any carrier calls, and the snapshot would guarantee exactly that.
--
-- The zone reaches nothing else. Transit days come from coordinates, regions,
-- territory flags and country codes, all still read from the frozen envelope, so
-- a move cannot shorten or lengthen anyone's mail. It can only shift the hour of
-- a day already decided, and only for a bundle that does not exist yet.
--
-- WHAT A RECIPIENT CAN DO WITH THAT.
-- Change zone before the day's first letter is collected and the whole bundle
-- moves with them. The bound is the width of the zone table -- UTC-12 to UTC+14,
-- so at most 26 hours -- and never further than that, because the instant is
-- always 09:00-17:00 on the delivery date in whatever zone is chosen. It cannot
-- reach back before the delivery date the transit rules produced; in the
-- recipient's own frame it is always on that date. And it is blind: a recipient
-- cannot see undelivered mail, so they cannot know whether a bundle exists to
-- move or when to move it. A day already written is out of reach entirely.
--
-- WHAT HAPPENS WHEN THEY MOVE AFTERWARDS.
-- Nothing. The bundle is write-once. Recomputing it would either drag mail
-- forward -- the hold violation this codebase exists to prevent -- or push it
-- back, retracting letters the recipient can already see. A move takes effect on
-- days that have not been written yet, which is also how physical mail behaves.

alter table public.letters
  add column if not exists delivery_date date;

comment on column public.letters.delivery_date is
  'Recipient-local date the letter is due, from the engine. The key it shares with every other letter arriving that day.';

create table if not exists slowmail.arrival_bundles (
  recipient_id uuid not null references public.profiles (id) on delete cascade,
  delivery_date date not null,
  deliver_at timestamptz not null,
  tz text not null,
  created_at timestamptz not null default now(),
  primary key (recipient_id, delivery_date)
);

comment on table slowmail.arrival_bundles is
  'The single instant at which a recipient''s post arrives on a given day. Written once by whichever letter is collected first and never recomputed, so a later move cannot retime a day already scheduled.';
comment on column slowmail.arrival_bundles.tz is
  'The recipient zone the instant was computed in, kept so the choice is auditable after the profile has moved on.';

-- No client reaches this table. It is worth being explicit: one row per
-- recipient per day with undelivered mail is exactly the existence signal the
-- whole design is built to withhold, and a planner row estimate over it would
-- leak the same count that taking `letters` off the Data API closed.
alter table slowmail.arrival_bundles enable row level security;
revoke all on table slowmail.arrival_bundles from public, anon, authenticated, service_role;

-- The collection worker needs the recipient's zone as it stands now, which is
-- the one deliberate live-profile read in the whole collection path. It is named
-- apart from the frozen `recipient_tz` so that the difference is visible at
-- every call site rather than resting on a comment.
drop function if exists public.claim_collection_batch(integer);

create or replace function public.claim_collection_batch(p_limit integer default 200)
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
  recipient_live_tz text,
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
      and l.sender_tz is not null
      and l.recipient_tz is not null
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
         c.sender_tz,
         c.sender_lat,
         c.sender_lng,
         c.sender_country_code,
         c.sender_region,
         c.sender_is_territory,
         c.recipient_id,
         c.recipient_tz,
         -- Falls back to the frozen zone rather than to a default, so a deleted
         -- or half-written profile cannot silently move someone's post to UTC.
         coalesce(rp.timezone, c.recipient_tz),
         c.recipient_lat,
         c.recipient_lng,
         c.recipient_country_code,
         c.recipient_region,
         c.recipient_is_territory
  from claimed c
  left join public.profiles rp on rp.id = c.recipient_id;
end;
$$;

revoke all on function public.claim_collection_batch(integer) from public;
grant execute on function public.claim_collection_batch(integer) to service_role;

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
  create temporary table if not exists tmp_collection_payload (
    letter_id uuid primary key,
    recipient_id uuid,
    collected_at timestamptz,
    postmark_date date,
    transit_days integer,
    delivery_date date,
    deliver_at timestamptz,
    tz text,
    schedule_source text
  ) on commit drop;
  delete from tmp_collection_payload;

  insert into tmp_collection_payload
  select
    (r ->> 'letterId')::uuid,
    l.recipient_id,
    (r ->> 'collectedAt')::timestamptz,
    (r ->> 'postmarkDate')::date,
    (r ->> 'transitDays')::integer,
    (r ->> 'deliveryDate')::date,
    (r ->> 'deliverAt')::timestamptz,
    nullif(r ->> 'recipientTz', ''),
    nullif(r ->> 'scheduleSource', '')
  from jsonb_array_elements(p_results) as r
  join public.letters l on l.id = (r ->> 'letterId')::uuid
  on conflict (letter_id) do nothing;

  -- The engine may report a collection instant still in the future, because the
  -- cheap SQL cutoff does not know about federal holidays. Those letters stay in
  -- the postbox with the engine's corrected cutoff, which is how the exact rule
  -- reaches collect_at without being reimplemented here.
  with future as (
    update public.letters l
       set collect_at = p.collected_at,
           collection_claimed_at = null
      from tmp_collection_payload p
     where l.id = p.letter_id
       and l.state = 'awaiting_collection'
       and p.collected_at > now()
    returning l.id
  )
  select count(*) into v_rescheduled from future;

  -- Reserve the day's instant. The first letter collected for a recipient and
  -- date fixes it; every later one joins. `do nothing` makes two workers racing
  -- on the same bundle agree rather than one of them winning, and makes a second
  -- run of the same batch a no-op.
  --
  -- distinct on picks the earliest candidate so the winner does not depend on
  -- the order rows came out of the engine, which would make the same batch
  -- schedule differently on a retry.
  insert into slowmail.arrival_bundles (recipient_id, delivery_date, deliver_at, tz)
  select distinct on (p.recipient_id, p.delivery_date)
         p.recipient_id, p.delivery_date, p.deliver_at, coalesce(p.tz, 'UTC')
  from tmp_collection_payload p
  where p.collected_at <= now()
    and p.delivery_date is not null
  order by p.recipient_id, p.delivery_date, p.deliver_at
  on conflict (recipient_id, delivery_date) do nothing;

  with ready as (
    update public.letters l
       set state = 'in_transit',
           collected_at = p.collected_at,
           postmark_date = p.postmark_date,
           transit_days = p.transit_days,
           delivery_date = p.delivery_date,
           -- Joining the day's bundle, unless that instant is already behind
           -- this letter's own collection -- which a far eastward move can
           -- produce -- in which case the letter keeps the instant the engine
           -- guaranteed comes after collection. Mail that cannot arrive before
           -- it was posted outranks mail that arrives together.
           deliver_at = case
                          when b.deliver_at is not null and b.deliver_at >= p.collected_at
                            then b.deliver_at
                          else p.deliver_at
                        end,
           schedule_source = case
                               when b.deliver_at is not null and b.deliver_at >= p.collected_at
                                 then p.schedule_source
                               else coalesce(p.schedule_source, 'mailclock') || '+unbundled'
                             end,
           collection_claimed_at = null
      from tmp_collection_payload p
      left join slowmail.arrival_bundles b
        on b.recipient_id = p.recipient_id
       and b.delivery_date = p.delivery_date
     where l.id = p.letter_id
       and l.state = 'awaiting_collection'
       and p.collected_at <= now()
    returning l.id
  )
  select count(*) into v_applied from ready;

  return query select v_applied, v_rescheduled;
end;
$$;

revoke all on function public.apply_collection(jsonb) from public;
grant execute on function public.apply_collection(jsonb) to service_role;

-- Delivery now groups on the date the engine decided rather than re-deriving one
-- from deliver_at and the letter's own frozen zone. Those two agreed only while
-- every letter for a day carried the same zone, which is the assumption that
-- just turned out to be false.
create or replace function slowmail.run_delivery(p_limit integer default 500)
returns table (delivered integer, pushes_queued integer)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_delivered integer := 0;
  v_queued integer := 0;
begin
  with due as (
    select l.id
    from public.letters l
    where l.state = 'in_transit'
      and l.deliver_at <= now()
    order by l.deliver_at
    limit p_limit
    for update skip locked
  ),
  moved as (
    update public.letters l
       set state = 'delivered',
           delivered_at = now()
      from due
     where l.id = due.id
       and l.state = 'in_transit'
    returning l.recipient_id,
              coalesce(l.delivery_date, (l.deliver_at at time zone l.recipient_tz)::date) as local_delivery_date
  ),
  per_recipient as (
    select recipient_id, local_delivery_date, count(*)::integer as n
    from moved
    group by 1, 2
  ),
  queued as (
    insert into slowmail.push_outbox (recipient_id, delivery_date, letter_count)
    select recipient_id, local_delivery_date, n from per_recipient
    on conflict (recipient_id, delivery_date) do update
      set letter_count = slowmail.push_outbox.letter_count + excluded.letter_count
    returning (xmax = 0) as is_new_notification
  )
  select (select count(*) from moved), (select count(*) from queued where is_new_notification)
    into v_delivered, v_queued;

  return query select v_delivered, v_queued;
end;
$$;

-- A collected letter now carries the date its bundle is keyed on.
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'letters_collected_has_delivery_date') then
    alter table public.letters
      add constraint letters_collected_has_delivery_date
      check (collected_at is null or delivery_date is not null) not valid;
  end if;
end;
$$;
