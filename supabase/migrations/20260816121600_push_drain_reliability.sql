-- The carrier has to come back for what it could not deliver.

-- Two ways a queued notification could sit in the outbox forever.
--
-- First, nothing ever woke the worker except a *new* delivery. The drain claims
-- 200 rows; deliver to 201 recipients and the 201st waits for the next batch of
-- new deliveries, which on a quiet evening never comes. A row released after a
-- retryable APNs failure had the same problem: it became eligible again and
-- nobody was told.
--
-- Second, a recipient with two devices where one returned 200 and the other 503
-- was marked sent, because any success closed the row. The 503 device never
-- heard about the letter at all.
--
-- Retrying the whole row would fix the second at the cost of knocking twice on
-- the device that already answered, and "the carrier comes once" is the product.
-- So the row remembers which tokens it has already reached, and a retry is
-- offered only the tokens still owed.

alter table slowmail.push_outbox
  add column if not exists delivered_tokens text[] not null default '{}';

comment on column slowmail.push_outbox.delivered_tokens is
  'Tokens already notified for this row. A retry skips them so a partial failure never knocks twice on a device that answered.';

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
  -- Left join so a recipient with no live device -- or none left owed -- still
  -- yields a row the worker can close out, instead of a notification that
  -- retries until it is abandoned.
  left join public.devices d
    on d.user_id = c.recipient_id
   and d.revoked_at is null
   and d.apns_token <> all (c.delivered_tokens);
end;
$$;

revoke all on function public.claim_push_batch(integer) from public;
grant execute on function public.claim_push_batch(integer) to service_role;

create or replace function public.record_push_delivery(p_outbox_id uuid, p_apns_token text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update slowmail.push_outbox
     set delivered_tokens = array(
           select distinct t
           from unnest(delivered_tokens || array[p_apns_token]) as t
         )
   where id = p_outbox_id;
end;
$$;

revoke all on function public.record_push_delivery(uuid, text) from public;
grant execute on function public.record_push_delivery(uuid, text) to service_role;

-- Anything still owed, whoever queued it.
create or replace function slowmail.pending_push_count()
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select count(*)::integer
  from slowmail.push_outbox o
  where o.sent_at is null
    and (o.claimed_at is null or o.claimed_at < now() - interval '15 minutes')
    and o.attempts < 5;
$$;

revoke all on function slowmail.pending_push_count() from public;

create or replace function slowmail.dispatch_push_drain()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if slowmail.pending_push_count() > 0 then
    perform slowmail.invoke_edge_function('deliver-push');
  end if;
end;
$$;

revoke all on function slowmail.dispatch_push_drain() from public;

-- Delivery stops being the only thing that can wake the drain.
select cron.schedule('slowmail-push-drain', '*/5 * * * *', $$select slowmail.dispatch_push_drain();$$);
