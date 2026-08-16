-- Letters: the table the whole product rests on.
--
-- A letter carries its own schedule. Once collected, the schedule columns are a
-- snapshot of the routing inputs as they were at collection, never a live read
-- of the profiles, so a sender who moves city does not teleport mail that is
-- already in transit.

do $$
begin
  if not exists (select 1 from pg_type where typname = 'letter_state') then
    create type public.letter_state as enum (
      'draft',
      'awaiting_collection',
      'in_transit',
      'delivered',
      'revoked'
    );
  end if;
end;
$$;

create table if not exists public.letters (
  id uuid primary key default gen_random_uuid(),
  sender_id uuid not null default auth.uid() references public.profiles (id) on delete restrict,
  recipient_id uuid not null references public.profiles (id) on delete restrict,
  body text not null default '' check (char_length(body) <= 8000),
  state public.letter_state not null default 'draft',

  -- Schedule
  written_at timestamptz,
  collect_at timestamptz,
  collected_at timestamptz,
  postmark_date date,
  transit_days integer check (transit_days between 0 and 60),
  deliver_at timestamptz,
  delivered_at timestamptz,
  read_at timestamptz,
  revoked_at timestamptz,

  -- Routing inputs frozen at collection.
  sender_tz text,
  sender_lat double precision,
  sender_lng double precision,
  sender_country_code text,
  sender_is_territory boolean,
  recipient_tz text,
  recipient_lat double precision,
  recipient_lng double precision,
  recipient_country_code text,
  schedule_source text,

  -- Held by the collection worker while it is computing a schedule.
  collection_claimed_at timestamptz,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint letters_not_self check (sender_id <> recipient_id),

  -- A collected letter is fully routed or it is not collected.
  constraint letters_collected_is_routed check (
    collected_at is null
    or (
      deliver_at is not null
      and postmark_date is not null
      and transit_days is not null
      and recipient_tz is not null
      and deliver_at >= collected_at
    )
  ),
  constraint letters_state_consistent check (
    case state
      when 'draft' then collected_at is null and deliver_at is null and revoked_at is null
                        and written_at is null
      when 'awaiting_collection' then collect_at is not null and written_at is not null
                                     and collected_at is null and revoked_at is null
      when 'in_transit' then collected_at is not null and delivered_at is null and revoked_at is null
      when 'delivered' then collected_at is not null and delivered_at is not null and revoked_at is null
      -- A letter can only be pulled back out of the box before it is collected.
      when 'revoked' then collected_at is null and revoked_at is not null
      else false
    end
  ),
  constraint letters_read_after_delivery check (read_at is null or delivered_at is not null)
);

comment on table public.letters is
  'A letter and its schedule. Recipient visibility is gated on deliver_at <= now() by RLS, not by the client.';
comment on column public.letters.collect_at is
  'Earliest candidate collection instant, computed cheaply in SQL at posting time. The mailclock engine is authoritative and may push this forward for Sundays and holidays.';
comment on column public.letters.collected_at is
  'Set once, by the collection worker. Its presence freezes the letter.';

-- The recipient index is the hot path for the delivery job and for a
-- recipient's own mailbox read.
create index if not exists letters_delivery_due on public.letters (deliver_at)
  where state = 'in_transit';
create index if not exists letters_collection_due on public.letters (collect_at)
  where state = 'awaiting_collection';
create index if not exists letters_recipient_mailbox on public.letters (recipient_id, deliver_at desc)
  where state = 'delivered';
create index if not exists letters_sender_outbox on public.letters (sender_id, created_at desc);

create trigger letters_touch_updated_at
  before update on public.letters
  for each row execute function slowmail.touch_updated_at();

-- Realtime would otherwise be a hole straight through RLS: postgres_changes
-- ships an old-row image on UPDATE/DELETE that is not policy-filtered, and even
-- a filtered INSERT event proves a row appeared. Letters are never published,
-- and REPLICA IDENTITY NOTHING makes a later attempt to publish them fail loudly
-- instead of silently leaking.
alter table public.letters replica identity nothing;
