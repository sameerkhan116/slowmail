-- The test the product depends on: a recipient cannot learn a letter exists
-- before it lands.
--
-- Every assertion below runs as the real `authenticated` role with the
-- recipient's own JWT claims. Running these as postgres would prove nothing:
-- that role carries BYPASSRLS, so every policy in the schema is invisible to it
-- and the whole file would pass against a table with no security at all.
--
-- "Advancing the clock" is done by moving the letter's deliver_at across now()
-- rather than moving now() itself, because Postgres has no time travel and the
-- policy predicate is literally `deliver_at <= now()`. Both directions exercise
-- the same comparison. The two boundary letters (one second either side of the
-- present) pin that down.

begin;

create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, pg_catalog;

select plan(17);

-- Fixtures -------------------------------------------------------------------

insert into auth.users (id) values
  ('a0000000-0000-4000-8000-000000000001'),  -- sender
  ('b0000000-0000-4000-8000-000000000002'),  -- recipient
  ('c0000000-0000-4000-8000-000000000003');  -- unrelated third party

insert into public.profiles (id, display_name, home_city_label, home_lat, home_lng, timezone, country_code) values
  ('a0000000-0000-4000-8000-000000000001', 'Ada',  'Brooklyn, NY',   40.6782,  -73.9442, 'America/New_York',    'US'),
  ('b0000000-0000-4000-8000-000000000002', 'Bo',   'Portland, OR',   45.5152, -122.6784, 'America/Los_Angeles', 'US'),
  ('c0000000-0000-4000-8000-000000000003', 'Cyd',  'Chicago, IL',    41.8781,  -87.6298, 'America/Chicago',     'US');

insert into public.correspondents (requester_id, addressee_id, status) values
  ('a0000000-0000-4000-8000-000000000001', 'b0000000-0000-4000-8000-000000000002', 'accepted');

-- In transit, three days out.
insert into public.letters (
  id, sender_id, recipient_id, body, state,
  written_at, collect_at, collected_at, postmark_date, transit_days, deliver_at,
  sender_tz, sender_lat, sender_lng, sender_country_code, sender_is_territory,
  recipient_tz, recipient_lat, recipient_lng, recipient_country_code, schedule_source
) values (
  '11111111-0000-4000-8000-00000000000a',
  'a0000000-0000-4000-8000-000000000001',
  'b0000000-0000-4000-8000-000000000002',
  'The rhododendrons finally took.',
  'in_transit',
  now() - interval '2 days', now() - interval '2 days', now() - interval '2 days',
  (now() - interval '2 days')::date, 3, now() + interval '3 days',
  'America/New_York', 40.6782, -73.9442, 'US', false,
  'America/Los_Angeles', 45.5152, -122.6784, 'US', 'test-fixture'
);

-- A draft and a revoked letter, which must never surface to the recipient.
insert into public.letters (id, sender_id, recipient_id, body, state) values
  ('11111111-0000-4000-8000-00000000000b',
   'a0000000-0000-4000-8000-000000000001',
   'b0000000-0000-4000-8000-000000000002',
   'Unfinished thought.', 'draft');

insert into public.letters (id, sender_id, recipient_id, body, state, written_at, revoked_at) values
  ('11111111-0000-4000-8000-00000000000c',
   'a0000000-0000-4000-8000-000000000001',
   'b0000000-0000-4000-8000-000000000002',
   'Thought better of it.', 'revoked', now() - interval '1 day', now() - interval '1 hour');

-- Before delivery ------------------------------------------------------------

set local request.jwt.claims = '{"sub":"b0000000-0000-4000-8000-000000000002","role":"authenticated"}';
set local role authenticated;

select is_empty(
  $$ select id from public.letters $$,
  'recipient: SELECT returns no rows at all before delivery'
);

select is(
  (select count(*)::int from public.letters),
  0,
  'recipient: count(*) is 0 before delivery, so an aggregate cannot betray the letter'
);

select is_empty(
  $$ select body, sender_id from public.letters where id = '11111111-0000-4000-8000-00000000000a' $$,
  'recipient: naming the letter id directly still returns nothing'
);

select is(
  (select count(*)::int from public.letters where recipient_id = auth.uid()),
  0,
  'recipient: filtering by their own id does not widen what they can see'
);

reset role;
set local request.jwt.claims = '{"sub":"c0000000-0000-4000-8000-000000000003","role":"authenticated"}';
set local role authenticated;

select is(
  (select count(*)::int from public.letters),
  0,
  'third party: sees nothing while the letter is in transit'
);

reset role;
set local request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000001","role":"authenticated"}';
set local role authenticated;

select is(
  (select count(*)::int from public.letters),
  3,
  'sender: sees their draft, revoked and in-transit letters at every stage'
);

select is(
  (select state::text from public.letters where id = '11111111-0000-4000-8000-00000000000a'),
  'in_transit',
  'sender: can watch a letter while it is in transit'
);

-- Delivery time passes -------------------------------------------------------

reset role;

-- Time cannot actually be advanced, so the letter's delivery instant is moved
-- back across now() instead; the policy compares the two either way. The freeze
-- guard refuses that edit, which is the correct behaviour and worth asserting
-- before it is stood down for the rest of this file.
select throws_ok(
  $$ update public.letters set deliver_at = now() - interval '1 minute'
      where id = '11111111-0000-4000-8000-00000000000a' $$,
  'SM001',
  null,
  'even a bypassrls role cannot move the delivery instant of a collected letter'
);

alter table public.letters disable trigger letters_guard_write;
update public.letters
   set deliver_at = now() - interval '1 minute'
 where id = '11111111-0000-4000-8000-00000000000a';
alter table public.letters enable trigger letters_guard_write;

set local request.jwt.claims = '{"sub":"b0000000-0000-4000-8000-000000000002","role":"authenticated"}';
set local role authenticated;

select is(
  (select count(*)::int from public.letters),
  1,
  'recipient: exactly one letter once its delivery instant has passed'
);

select is(
  (select body from public.letters where id = '11111111-0000-4000-8000-00000000000a'),
  'The rhododendrons finally took.',
  'recipient: can read the body after delivery'
);

select is(
  (select count(*)::int from public.letters where state <> 'delivered'),
  1,
  'recipient: sees the letter as soon as its instant passes, even before the delivery job flips the state, because the mail is physically in the box'
);

reset role;
set local request.jwt.claims = '{"sub":"c0000000-0000-4000-8000-000000000003","role":"authenticated"}';
set local role authenticated;

select is(
  (select count(*)::int from public.letters),
  0,
  'third party: still sees nothing after delivery'
);

-- The boundary ---------------------------------------------------------------

reset role;

insert into public.letters (
  id, sender_id, recipient_id, body, state,
  written_at, collect_at, collected_at, postmark_date, transit_days, deliver_at,
  recipient_tz, schedule_source
) values (
  '22222222-0000-4000-8000-00000000000a',
  'a0000000-0000-4000-8000-000000000001',
  'b0000000-0000-4000-8000-000000000002',
  'One second early.', 'in_transit',
  now() - interval '1 day', now() - interval '1 day', now() - interval '1 day',
  (now() - interval '1 day')::date, 1, now() + interval '1 second',
  'America/Los_Angeles', 'test-fixture'
), (
  '22222222-0000-4000-8000-00000000000b',
  'a0000000-0000-4000-8000-000000000001',
  'b0000000-0000-4000-8000-000000000002',
  'One second late.', 'in_transit',
  now() - interval '1 day', now() - interval '1 day', now() - interval '1 day',
  (now() - interval '1 day')::date, 1, now() - interval '1 second',
  'America/Los_Angeles', 'test-fixture'
);

set local request.jwt.claims = '{"sub":"b0000000-0000-4000-8000-000000000002","role":"authenticated"}';
set local role authenticated;

select is_empty(
  $$ select id from public.letters where id = '22222222-0000-4000-8000-00000000000a' $$,
  'recipient: a letter due one second from now is invisible'
);

select is(
  (select count(*)::int from public.letters where id = '22222222-0000-4000-8000-00000000000b'),
  1,
  'recipient: a letter due one second ago is visible'
);

-- Nothing else opens the door ------------------------------------------------

select is(
  (select count(*)::int from public.letters where id = '11111111-0000-4000-8000-00000000000b'),
  0,
  'recipient: a draft addressed to them does not exist'
);

select is(
  (select count(*)::int from public.letters where id = '11111111-0000-4000-8000-00000000000c'),
  0,
  'recipient: a revoked letter never existed'
);

-- mark_letter_read is SECURITY DEFINER, so it has to re-apply the same
-- predicate itself rather than inherit the policy.
reset role;
set local request.jwt.claims = '{"sub":"b0000000-0000-4000-8000-000000000002","role":"authenticated"}';
set local role authenticated;

select throws_ok(
  $$ select public.mark_letter_read('22222222-0000-4000-8000-00000000000a') $$,
  'SM005',
  null,
  'recipient: cannot mark an undelivered letter read, which would confirm it exists'
);

reset role;
select * from finish();
rollback;
