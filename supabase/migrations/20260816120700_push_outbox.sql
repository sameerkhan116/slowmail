-- The push outbox.
--
-- The carrier comes once. One row per recipient per delivery day is the whole
-- guarantee: the unique index below is what makes a job that runs twice, or two
-- jobs that overlap, produce exactly one push.

create table if not exists slowmail.push_outbox (
  id uuid primary key default gen_random_uuid(),
  recipient_id uuid not null references public.profiles (id) on delete cascade,
  -- The recipient's own calendar date, taken from the timezone snapshotted on
  -- the letter, so a recipient who has since moved still gets one drop per day
  -- as they experienced it.
  delivery_date date not null,
  letter_count integer not null default 0,
  created_at timestamptz not null default now(),
  claimed_at timestamptz,
  sent_at timestamptz,
  attempts integer not null default 0,
  last_error text
);

create unique index if not exists push_outbox_one_per_recipient_per_day
  on slowmail.push_outbox (recipient_id, delivery_date);

create index if not exists push_outbox_pending
  on slowmail.push_outbox (created_at)
  where sent_at is null;

alter table slowmail.push_outbox enable row level security;
revoke all on slowmail.push_outbox from anon, authenticated;

comment on table slowmail.push_outbox is
  'One pending notification per recipient per delivery day. Never contains letter content.';
