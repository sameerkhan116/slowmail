-- Freeze the routing inputs when the letter is posted, not when it is collected.
--
-- The schedule was being computed from whatever the profiles said at collection
-- time. That is wrong for a reason that only shows up when a profile moves
-- between the two moments. A sender posts at 10:00 in Los Angeles; the SQL
-- cutoff records a collection instant of 17:00 PDT. Before the sweep runs the
-- sender changes their profile to New York. mailclock is then handed the same
-- written_at with a New York zone, reads it as 13:00 EDT, and returns 17:00 EDT
-- -- three hours *earlier* than the instant already written to collect_at. The
-- letter sits revocable past its own authoritative collection time.
--
-- The "never late" property of slowmail.next_collection_cutoff is real, but it
-- is only meaningful while the inputs it was computed from hold still. So the
-- inputs stop moving at the same moment the estimate is first written: posting.
-- Collection then reads the letter, never the profile.

alter table public.letters
  add column if not exists routing_snapshot_at timestamptz;

comment on column public.letters.routing_snapshot_at is
  'When the routing inputs below were frozen. Set at posting. A profile edit after this instant cannot reach the letter.';

-- Existing letters still in the postbox have no snapshot, because until now the
-- columns were only filled at collection. Fill them from the profiles as they
-- stand right now: that is the same data the sweep would have joined to anyway,
-- so this changes nothing for them except when it is read.
update public.letters l
   set sender_tz = coalesce(l.sender_tz, sp.timezone),
       sender_lat = coalesce(l.sender_lat, sp.home_lat),
       sender_lng = coalesce(l.sender_lng, sp.home_lng),
       sender_country_code = coalesce(l.sender_country_code, sp.country_code),
       sender_region = coalesce(l.sender_region, sp.region),
       sender_is_territory = coalesce(l.sender_is_territory, sp.is_territory, false),
       recipient_tz = coalesce(l.recipient_tz, rp.timezone),
       recipient_lat = coalesce(l.recipient_lat, rp.home_lat),
       recipient_lng = coalesce(l.recipient_lng, rp.home_lng),
       recipient_country_code = coalesce(l.recipient_country_code, rp.country_code),
       recipient_region = coalesce(l.recipient_region, rp.region),
       recipient_is_territory = coalesce(l.recipient_is_territory, rp.is_territory, false),
       routing_snapshot_at = coalesce(l.routing_snapshot_at, l.written_at, now())
  from public.profiles sp, public.profiles rp
 where sp.id = l.sender_id
   and rp.id = l.recipient_id
   and l.state = 'awaiting_collection';

-- Posting is the moment the address is read off the envelope.
create or replace function public.post_letter(p_letter_id uuid)
returns public.letters
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_letter public.letters;
  v_sender public.profiles;
  v_recipient public.profiles;
begin
  -- Ownership belongs in the locking predicate, not in a check after it.
  -- Locking first and testing second makes the wait observable: a stranger's
  -- id blocks behind a live transaction and a nonexistent id returns at once,
  -- which is a difference an attacker can time.
  select * into v_letter
  from public.letters
  where id = p_letter_id
    and sender_id = auth.uid()
  for update;

  if not found then
    raise exception 'letter not found' using errcode = 'SM005';
  end if;

  if v_letter.state <> 'draft' then
    raise exception 'letter % has already been posted', p_letter_id using errcode = 'SM002';
  end if;

  if char_length(btrim(v_letter.body)) = 0 then
    raise exception 'cannot post an empty letter' using errcode = 'SM006';
  end if;

  if not public.is_accepted_correspondent(v_letter.recipient_id) then
    raise exception 'recipient is not an accepted correspondent' using errcode = 'SM007';
  end if;

  select * into v_sender from public.profiles where id = v_letter.sender_id;
  if not found or v_sender.timezone is null then
    raise exception 'sender has no routable address' using errcode = 'SM008';
  end if;

  select * into v_recipient from public.profiles where id = v_letter.recipient_id;
  if not found or v_recipient.timezone is null then
    raise exception 'recipient has no routable address' using errcode = 'SM008';
  end if;

  update public.letters
     set state = 'awaiting_collection',
         written_at = now(),
         collect_at = slowmail.next_collection_cutoff(v_sender.timezone),
         routing_snapshot_at = now(),
         sender_tz = v_sender.timezone,
         sender_lat = v_sender.home_lat,
         sender_lng = v_sender.home_lng,
         sender_country_code = v_sender.country_code,
         sender_region = v_sender.region,
         sender_is_territory = coalesce(v_sender.is_territory, false),
         recipient_tz = v_recipient.timezone,
         recipient_lat = v_recipient.home_lat,
         recipient_lng = v_recipient.home_lng,
         recipient_country_code = v_recipient.country_code,
         recipient_region = v_recipient.region,
         recipient_is_territory = coalesce(v_recipient.is_territory, false)
   where id = p_letter_id
  returning * into v_letter;

  return v_letter;
end;
$$;

create or replace function public.revoke_letter(p_letter_id uuid)
returns public.letters
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_letter public.letters;
begin
  select * into v_letter
  from public.letters
  where id = p_letter_id
    and sender_id = auth.uid()
  for update;

  if not found then
    raise exception 'letter not found' using errcode = 'SM005';
  end if;

  if v_letter.collected_at is not null then
    raise exception 'letter % was collected on % and cannot be recalled', p_letter_id, v_letter.collected_at
      using errcode = 'SM001';
  end if;

  update public.letters
     set state = 'revoked',
         revoked_at = now()
   where id = p_letter_id
  returning * into v_letter;

  return v_letter;
end;
$$;

create or replace function public.mark_letter_read(p_letter_id uuid)
returns public.letters
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_letter public.letters;
begin
  -- Reading is a recipient action, and only of mail that has actually landed.
  -- The deliver_at test is repeated here because this function is SECURITY
  -- DEFINER and so runs outside the policy that would otherwise hide the row.
  select * into v_letter
  from public.letters
  where id = p_letter_id
    and recipient_id = auth.uid()
    and state = 'delivered'
    and deliver_at is not null
    and deliver_at <= now()
  for update;

  if not found then
    raise exception 'letter not found' using errcode = 'SM005';
  end if;

  update public.letters
     set read_at = coalesce(v_letter.read_at, now())
   where id = p_letter_id
  returning * into v_letter;

  return v_letter;
end;
$$;

-- The sweep reads the envelope, never the address book.
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
      -- A letter posted before this migration with no frozen address cannot be
      -- scheduled from the envelope. Leaving it unclaimed is the safe failure:
      -- it stays in the postbox and stays revocable, rather than being routed
      -- from data that may have moved.
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
         c.recipient_lat,
         c.recipient_lng,
         c.recipient_country_code,
         c.recipient_region,
         c.recipient_is_territory
  from claimed c;
end;
$$;

revoke all on function public.claim_collection_batch(integer) from public;
-- Dropping and recreating this function in an earlier migration silently took
-- its execute grant with it, and nothing in the pgTAP suite noticed because the
-- suite called it as postgres. Collection was dead on any fresh database while
-- 90 assertions stayed green. The grant is restored here and the worker tests
-- now run as service_role so the next omission fails a test.
grant execute on function public.claim_collection_batch(integer) to service_role;

-- Collection no longer writes the routing snapshot. It was the last path by
-- which a value computed outside the database could land in those columns, and
-- with the freeze now happening at posting there is nothing left for it to say.
-- The engine still decides the schedule; it just no longer restates the address.
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
      nullif(r ->> 'scheduleSource', '') as schedule_source
    from jsonb_array_elements(p_results) as r
  ),
  -- The engine may report a collection instant still in the future, because the
  -- cheap SQL cutoff does not know about federal holidays. Those letters stay in
  -- the postbox with the engine's corrected cutoff, which is how the exact rule
  -- reaches collect_at without being reimplemented here.
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
           collection_claimed_at = null
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
grant execute on function public.apply_collection(jsonb) to service_role;

-- Releasing a claim the worker could not schedule. Without this a letter whose
-- timezone the engine rejects keeps its claim, is skipped by every subsequent
-- sweep once the 15 minute reclaim window is the only thing freeing it, and no
-- one is told. Recording the reason turns a silent wedge into something visible.
alter table public.letters
  add column if not exists collection_error text,
  add column if not exists collection_error_at timestamptz;

comment on column public.letters.collection_error is
  'Why the last collection attempt failed. Present means a human should look; the letter stays in the postbox and stays revocable.';

create or replace function public.release_collection_claim(p_letter_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.letters
     set collection_claimed_at = null,
         collection_error = left(coalesce(p_reason, 'unknown'), 500),
         collection_error_at = now()
   where id = p_letter_id
     and state = 'awaiting_collection';
end;
$$;

revoke all on function public.release_collection_claim(uuid, text) from public;
grant execute on function public.release_collection_claim(uuid, text) to service_role;
