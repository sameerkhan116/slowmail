-- The two postal jobs.
--
-- Both are safe to run twice and safe to run concurrently with themselves.
-- Contention is resolved with FOR UPDATE SKIP LOCKED: a second worker skips
-- rows the first is already holding rather than waiting behind it, and the
-- state predicate is re-checked under the lock, so a row that a committed
-- sibling already moved is dropped instead of processed again.

-- Collection, step one: hand a batch of due letters to the worker along with
-- the routing inputs as they stand right now. This is the moment the schedule
-- is frozen, so the profile values are read here and stored on the letter.
create or replace function public.claim_collection_batch(p_limit integer default 200)
returns table (
  letter_id uuid,
  written_at timestamptz,
  sender_user_id uuid,
  sender_tz text,
  sender_lat double precision,
  sender_lng double precision,
  sender_country_code text,
  sender_is_territory boolean,
  recipient_user_id uuid,
  recipient_tz text,
  recipient_lat double precision,
  recipient_lng double precision,
  recipient_country_code text
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
         sp.is_territory,
         c.recipient_id,
         rp.timezone,
         rp.home_lat,
         rp.home_lng,
         rp.country_code
  from claimed c
  join public.profiles sp on sp.id = c.sender_id
  join public.profiles rp on rp.id = c.recipient_id;
end;
$$;

-- Collection, step two: write back what the mailclock engine computed.
--
-- Idempotent by construction. The state predicate means a replayed payload
-- finds the letter already in transit and changes nothing, and the letter
-- guards would reject a rewrite of a frozen schedule regardless.
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
      (r ->> 'letterId')::uuid          as letter_id,
      (r ->> 'collectedAt')::timestamptz as collected_at,
      (r ->> 'postmarkDate')::date       as postmark_date,
      (r ->> 'transitDays')::integer     as transit_days,
      (r ->> 'deliverAt')::timestamptz   as deliver_at,
      nullif(r ->> 'scheduleSource', '') as schedule_source,
      (r -> 'snapshot')                  as snapshot
    from jsonb_array_elements(p_results) as r
  ),
  -- The engine may report a collection instant still in the future, because
  -- the cheap SQL cutoff does not know about Sundays or federal holidays.
  -- Those letters stay in the postbox with a corrected cutoff.
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
           sender_is_territory = (p.snapshot ->> 'senderIsTerritory')::boolean,
           recipient_tz = p.snapshot ->> 'recipientTz',
           recipient_lat = (p.snapshot ->> 'recipientLat')::double precision,
           recipient_lng = (p.snapshot ->> 'recipientLng')::double precision,
           recipient_country_code = p.snapshot ->> 'recipientCountryCode'
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

-- Delivery. Pure SQL: no engine call is needed once deliver_at is frozen.
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
              (l.deliver_at at time zone l.recipient_tz)::date as local_delivery_date
  ),
  per_recipient as (
    select recipient_id, local_delivery_date, count(*)::integer as n
    from moved
    group by 1, 2
  ),
  queued as (
    insert into slowmail.push_outbox (recipient_id, delivery_date, letter_count)
    select recipient_id, local_delivery_date, n from per_recipient
    -- Already notified for that day: fold the count in, do not knock twice.
    on conflict (recipient_id, delivery_date) do update
      set letter_count = slowmail.push_outbox.letter_count + excluded.letter_count
    returning (xmax = 0) as is_new_notification
  )
  select (select count(*) from moved), (select count(*) from queued where is_new_notification)
    into v_delivered, v_queued;

  return query select v_delivered, v_queued;
end;
$$;

-- Push worker support: claim unsent notifications, then mark them.
create or replace function public.claim_push_batch(p_limit integer default 200)
returns table (
  outbox_id uuid,
  recipient_id uuid,
  delivery_date date,
  apns_token text,
  environment text
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  return query
  with due as (
    select o.id
    from slowmail.push_outbox o
    where o.sent_at is null
      and (o.claimed_at is null or o.claimed_at < now() - interval '15 minutes')
      and o.attempts < 5
    order by o.created_at
    limit p_limit
    for update skip locked
  ),
  claimed as (
    update slowmail.push_outbox o
       set claimed_at = now(), attempts = o.attempts + 1
      from due
     where o.id = due.id
       and o.sent_at is null
    returning o.*
  )
  select c.id, c.recipient_id, c.delivery_date, d.apns_token, d.environment
  from claimed c
  -- Left join so a recipient with no live device still yields a row the worker
  -- can close out, instead of a notification that retries until it is abandoned.
  left join public.devices d on d.user_id = c.recipient_id and d.revoked_at is null;
end;
$$;

create or replace function public.complete_push(p_outbox_id uuid, p_error text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update slowmail.push_outbox
     set sent_at = case when p_error is null then now() else null end,
         claimed_at = null,
         last_error = p_error
   where id = p_outbox_id
     and sent_at is null;
end;
$$;

-- Dead tokens are pruned rather than deleted so a reinstall can revive the row
-- through register_device instead of racing the unique index.
create or replace function public.revoke_apns_token(p_apns_token text, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.devices
     set revoked_at = now(), revoked_reason = p_reason
   where apns_token = p_apns_token
     and revoked_at is null;
end;
$$;

revoke all on function public.claim_collection_batch(integer) from public;
revoke all on function public.apply_collection(jsonb) from public;
revoke all on function slowmail.run_delivery(integer) from public;
revoke all on function public.claim_push_batch(integer) from public;
revoke all on function public.complete_push(uuid, text) from public;
revoke all on function public.revoke_apns_token(text, text) from public;

-- Only the worker identity may drive the postal machinery. `authenticated` is
-- deliberately absent from every grant here.
grant execute on function public.claim_collection_batch(integer) to service_role;
grant execute on function public.apply_collection(jsonb) to service_role;
grant execute on function public.claim_push_batch(integer) to service_role;
grant execute on function public.complete_push(uuid, text) to service_role;
grant execute on function public.revoke_apns_token(text, text) to service_role;
