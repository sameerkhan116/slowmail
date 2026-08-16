-- Two ways a profile could be shaped so that mail routes wrongly or not at all.

-- 1. A territory flag nothing derives.
--
-- Seven-day routing depends entirely on `is_territory`, and the flag was
-- independent of `region`. A profile could say region = 'AE' -- an APO/FPO
-- military address -- with is_territory left at its default false, and be routed
-- by great-circle distance from whatever coordinates it carried, landing in the
-- one-day band. Both columns are client-writable, so this is a shape the account
-- holder can choose rather than only a data-entry slip.
--
-- The existing constraint runs the other way: it stops the 50 states and PR from
-- claiming to be territories. This one stops the genuine territories from
-- denying it. Together they make the flag a function of the region rather than a
-- second opinion about it.
--
-- PR is deliberately absent. Puerto Rico is a 5-day far-zone destination, not a
-- 7-day territory, and the engine reads isTerritory before it reads the region,
-- so flagging PR would add two days to every letter its owner sends.
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'profiles_territories_are_flagged') then
    alter table public.profiles
      add constraint profiles_territories_are_flagged
      check (
        country_code is distinct from 'US'
        or region is null
        or region not in ('AA', 'AE', 'AP', 'GU', 'VI', 'AS', 'MP')
        or is_territory is true
      ) not valid;
  end if;
end;
$$;

do $$
begin
  begin
    alter table public.profiles validate constraint profiles_territories_are_flagged;
  exception when others then
    raise warning 'profiles_territories_are_flagged could not be validated: %. Existing rows in a territory region without is_territory route as domestic distance; fix them and re-validate.', sqlerrm;
  end;
end;
$$;

-- 2. A letter posted to nowhere.
--
-- `post_letter` checked for a timezone and nothing else, so a profile with no
-- coordinates produced a letter whose frozen envelope had null lat/lng. The
-- collection worker cannot route that and skips it, and no later profile edit
-- can repair it, because the envelope is a snapshot and repairing it would be
-- the recomputation the snapshot exists to prevent. The letter sits in the
-- postbox forever.
--
-- Refusing the post is the only place this can be fixed cleanly: before the
-- envelope is frozen, the profile is still the source of truth and the sender is
-- still there to be told.
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
  if not found or v_sender.timezone is null
     or v_sender.home_lat is null or v_sender.home_lng is null
     or v_sender.country_code is null then
    raise exception 'your profile has no routable address; set a home location before posting'
      using errcode = 'SM008';
  end if;

  select * into v_recipient from public.profiles where id = v_letter.recipient_id;
  if not found or v_recipient.timezone is null
     or v_recipient.home_lat is null or v_recipient.home_lng is null
     or v_recipient.country_code is null then
    -- Says nothing about the recipient beyond the fact that they cannot receive
    -- mail, which the sender already knows by being an accepted correspondent.
    raise exception 'that correspondent has no routable address yet' using errcode = 'SM008';
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

revoke all on function public.post_letter(uuid) from public;
grant execute on function public.post_letter(uuid) to authenticated;
