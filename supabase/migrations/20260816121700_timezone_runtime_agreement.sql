-- One timezone string, two runtimes, two different instants.
--
-- Postgres resolves a timezone string against its abbreviation table before its
-- zone table, so `AT TIME ZONE 'CET'` is a fixed +01:00 the whole year round.
-- Luxon -- and therefore mailclock -- reads the same string as a DST-observing
-- zone. Through European summer the two are an hour apart, and the SQL cutoff
-- lands an hour *later* than the engine's authoritative collection instant.
--
-- Late is the one direction the cutoff may not take. A letter past its real
-- collection instant is still `awaiting_collection`, and `awaiting_collection`
-- is still revocable, so for that hour a sender can reach back into the postbox
-- for a letter the post has already taken. `apply_collection` correcting
-- `collected_at` afterwards does not help: the window has already been open.
--
-- Sweeping all 598 zones the validator accepted found exactly four that
-- disagree -- CET, EET, MET and WET -- and no others. Naming those four would
-- close today's hole and rot the day Postgres adds an abbreviation. Every IANA
-- region zone contains a '/', so requiring one rules out the entire
-- abbreviation namespace in a single predicate that cannot fall behind.
--
-- UTC is admitted alongside, because it is the fallback `post_letter` uses when
-- a profile has no zone at all, and it is a fixed zero offset in both runtimes.

-- Existing rows have to go somewhere. Every slashless name Postgres accepts is
-- either an abbreviation, a legacy country link or a UTC alias, and each has a
-- canonical Region/City equivalent -- so these can be repaired rather than
-- stranded, and the constraint below can then be validated rather than trusted.
--
-- The four broken names map to zones matching Luxon's reading of them, which is
-- what the engine has been using for `collected_at` all along. That makes this a
-- correction of the SQL side to the authoritative side, not a change to anyone's
-- posting schedule. The fixed-offset abbreviations (EST, MST, HST) map to real
-- places that hold the same offset year-round, so their owners' timing is
-- unchanged.
create table if not exists slowmail.timezone_canonicalisation (
  legacy_name text primary key,
  canonical_name text not null
);

comment on table slowmail.timezone_canonicalisation is
  'Legacy and abbreviation zone names, and the Region/City zone each is rewritten to. Retained after the repair so the mapping stays reviewable and testable.';

insert into slowmail.timezone_canonicalisation (legacy_name, canonical_name) values
  -- The four that actually disagreed between the runtimes.
  ('CET', 'Europe/Paris'),
  ('MET', 'Europe/Paris'),
  ('EET', 'Europe/Athens'),
  ('WET', 'Europe/Lisbon'),
  -- Fixed-offset abbreviations, mapped to places that never observe DST.
  ('EST', 'America/Panama'),
  ('MST', 'America/Phoenix'),
  ('HST', 'Pacific/Honolulu'),
  -- Abbreviations that do carry US DST rules.
  ('EST5EDT', 'America/New_York'),
  ('CST6CDT', 'America/Chicago'),
  ('MST7MDT', 'America/Denver'),
  ('PST8PDT', 'America/Los_Angeles'),
  ('Navajo', 'America/Denver'),
  -- Legacy country and region links.
  ('Cuba', 'America/Havana'),
  ('Egypt', 'Africa/Cairo'),
  ('Eire', 'Europe/Dublin'),
  ('GB', 'Europe/London'),
  ('GB-Eire', 'Europe/London'),
  ('Hongkong', 'Asia/Hong_Kong'),
  ('Iceland', 'Atlantic/Reykjavik'),
  ('Iran', 'Asia/Tehran'),
  ('Israel', 'Asia/Jerusalem'),
  ('Jamaica', 'America/Jamaica'),
  ('Japan', 'Asia/Tokyo'),
  ('Kwajalein', 'Pacific/Kwajalein'),
  ('Libya', 'Africa/Tripoli'),
  ('NZ', 'Pacific/Auckland'),
  ('NZ-CHAT', 'Pacific/Chatham'),
  ('Poland', 'Europe/Warsaw'),
  ('Portugal', 'Europe/Lisbon'),
  ('PRC', 'Asia/Shanghai'),
  ('ROC', 'Asia/Taipei'),
  ('ROK', 'Asia/Seoul'),
  ('Singapore', 'Asia/Singapore'),
  ('Turkey', 'Europe/Istanbul'),
  ('W-SU', 'Europe/Moscow'),
  -- UTC aliases. 'Factory' is a placeholder zone with no location at all.
  ('GMT', 'UTC'),
  ('GMT0', 'UTC'),
  ('GMT-0', 'UTC'),
  ('GMT+0', 'UTC'),
  ('Greenwich', 'UTC'),
  ('UCT', 'UTC'),
  ('Universal', 'UTC'),
  ('Zulu', 'UTC'),
  ('Factory', 'UTC')
on conflict (legacy_name) do update set canonical_name = excluded.canonical_name;

-- Repair before constraining, so the constraint can be validated rather than
-- added NOT VALID and quietly believed.
update public.profiles p
   set timezone = m.canonical_name
  from slowmail.timezone_canonicalisation m
 where p.timezone = m.legacy_name;

-- In-flight letters carry their own frozen copy of the sender's zone, and that
-- copy is what the sweep reads. A letter posted before this migration with
-- sender_tz = 'CET' keeps the late cutoff until it is collected, so it is
-- repaired too -- and its collect_at recomputed, since that is the value the
-- lateness was measured in. Collected letters are left alone: their schedule is
-- already the engine's, the freeze trigger protects it, and rewriting settled
-- mail would be exactly the recomputation this codebase exists to prevent.
update public.letters l
   set sender_tz = m.canonical_name,
       collect_at = slowmail.next_collection_cutoff(m.canonical_name, l.written_at)
  from slowmail.timezone_canonicalisation m
 where l.sender_tz = m.legacy_name
   and l.collected_at is null;

update public.letters l
   set recipient_tz = m.canonical_name
  from slowmail.timezone_canonicalisation m
 where l.recipient_tz = m.legacy_name
   and l.collected_at is null;

create or replace function slowmail.assert_valid_timezone()
returns trigger
language plpgsql
as $$
begin
  if new.timezone is null then
    return new;
  end if;

  if new.timezone like 'posix/%' or new.timezone like 'right/%' then
    raise exception 'timezone % is a Postgres-only alias and is rejected by the scheduling engine; use the plain IANA name', new.timezone
      using errcode = 'check_violation';
  end if;

  -- Rejecting the whole abbreviation namespace rather than the four names known
  -- to disagree today. Postgres reads an abbreviation as a fixed offset and the
  -- engine reads it as a zone, and there is no way to tell from the string which
  -- of those a given abbreviation will do.
  if new.timezone <> 'UTC' and position('/' in new.timezone) = 0 then
    raise exception 'timezone % is an abbreviation or legacy alias; Postgres and the scheduling engine resolve these to different instants. Use the canonical Region/City name (%)',
      new.timezone,
      coalesce((select canonical_name from slowmail.timezone_canonicalisation where legacy_name = new.timezone), 'for example Europe/Paris')
      using errcode = 'check_violation';
  end if;

  if not exists (select 1 from pg_catalog.pg_timezone_names where name = new.timezone) then
    raise exception 'invalid IANA timezone: %', new.timezone
      using errcode = 'check_violation';
  end if;

  return new;
end;
$$;

-- The trigger gives the good error message; the constraint is what makes the
-- rule true of every row rather than of every row that happened to go through a
-- trigger. Validated immediately, which the repair above makes safe.
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'profiles_timezone_is_region_city') then
    alter table public.profiles
      add constraint profiles_timezone_is_region_city
      check (timezone is null or timezone = 'UTC' or position('/' in timezone) > 0);
  end if;
end;
$$;
