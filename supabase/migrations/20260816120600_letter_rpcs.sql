-- The client write surface.
--
-- Everything a client is allowed to change about a letter's lifecycle happens
-- through these functions, so `state`, `collect_at` and the rest never need a
-- column privilege granted to `authenticated`.

-- Earliest instant the carrier could possibly call: the next 17:00 in the
-- sender's own zone. This is deliberately only a lower bound. Postal days,
-- Sundays and US federal holidays are the mailclock engine's business; the
-- collection worker asks it for the authoritative instant and pushes this
-- forward if it turns out to be too early. Duplicating those rules in SQL is
-- exactly how the two would drift apart.
create or replace function slowmail.next_collection_cutoff(p_timezone text, p_from timestamptz default now())
returns timestamptz
language sql
stable
set search_path = ''
as $$
  select case
           when local_now::time < time '17:00'
             then date_trunc('day', local_now) + interval '17 hours'
           else date_trunc('day', local_now) + interval '1 day' + interval '17 hours'
         end at time zone p_timezone
  from (select p_from at time zone p_timezone as local_now) s;
$$;

-- Hand the letter to the postal service.
create or replace function public.post_letter(p_letter_id uuid)
returns public.letters
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_letter public.letters;
  v_timezone text;
begin
  select * into v_letter
  from public.letters
  where id = p_letter_id
  for update;

  if not found or v_letter.sender_id <> auth.uid() then
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

  select p.timezone into v_timezone from public.profiles p where p.id = v_letter.sender_id;

  update public.letters
     set state = 'awaiting_collection',
         written_at = now(),
         collect_at = slowmail.next_collection_cutoff(coalesce(v_timezone, 'UTC'))
   where id = p_letter_id
  returning * into v_letter;

  return v_letter;
end;
$$;

-- Reach back into the postbox. Only possible while the letter is still in it.
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
  for update;

  if not found or v_letter.sender_id <> auth.uid() then
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
  select * into v_letter
  from public.letters
  where id = p_letter_id
    and recipient_id = auth.uid()
    -- Same predicate as the recipient SELECT policy: an undelivered letter is
    -- not merely unreadable, it does not exist as far as the recipient goes.
    and deliver_at is not null
    and deliver_at <= now()
  for update;

  if not found then
    raise exception 'letter not found' using errcode = 'SM005';
  end if;

  if v_letter.read_at is not null or v_letter.delivered_at is null then
    return v_letter;
  end if;

  update public.letters set read_at = now() where id = p_letter_id returning * into v_letter;
  return v_letter;
end;
$$;

-- A token identifies an app install, not a person. If it shows up under a new
-- account the install changed hands, so ownership moves. Routing this through a
-- function keeps the unique index on apns_token from being usable as an oracle
-- for whether some other account holds a given token.
create or replace function public.register_device(p_apns_token text, p_environment text default 'production')
returns public.devices
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_device public.devices;
  v_user uuid := auth.uid();
begin
  if v_user is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  insert into public.devices (user_id, apns_token, environment)
  values (v_user, p_apns_token, p_environment)
  on conflict (apns_token) do update
    set user_id = v_user,
        environment = excluded.environment,
        last_seen_at = now(),
        revoked_at = null,
        revoked_reason = null
  returning * into v_device;

  return v_device;
end;
$$;

create or replace function public.unregister_device(p_apns_token text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.devices
     set revoked_at = now(), revoked_reason = 'unregistered by user'
   where apns_token = p_apns_token
     and user_id = auth.uid();
end;
$$;

revoke all on function slowmail.next_collection_cutoff(text, timestamptz) from public;
revoke all on function public.post_letter(uuid) from public;
revoke all on function public.revoke_letter(uuid) from public;
revoke all on function public.mark_letter_read(uuid) from public;
revoke all on function public.register_device(text, text) from public;
revoke all on function public.unregister_device(text) from public;

grant execute on function public.post_letter(uuid) to authenticated;
grant execute on function public.revoke_letter(uuid) to authenticated;
grant execute on function public.mark_letter_read(uuid) to authenticated;
grant execute on function public.register_device(text, text) to authenticated;
grant execute on function public.unregister_device(text) to authenticated;
